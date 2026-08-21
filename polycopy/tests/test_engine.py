"""Engine tests using a fake data source and a recording executor."""

from __future__ import annotations

import time

import pytest

from polycopy.config import BotConfig, ExecutionConfig, RiskConfig, Secrets, SizingConfig
from polycopy.engine import CopyEngine, reconcile_positions
from polycopy.execution import DryRunExecutor
from polycopy.models import Decision, OrderResult
from polycopy.store import Store

from .conftest import ASSET_ID, CONDITION_ID, make_trade


class FakeSource:
    """Stands in for DataSource without any HTTP."""

    def __init__(self, trades=None, market=None, positions=None):
        self.trades = list(trades or [])
        self.market = market
        self.positions = positions or {}
        self.fetch_calls = 0
        self.raise_on_fetch: Exception | None = None

    def fetch_trades(self, address, limit=50, offset=0):
        self.fetch_calls += 1
        if self.raise_on_fetch:
            raise self.raise_on_fetch
        return [t for t in self.trades if t.leader == address.lower()]

    def fetch_market(self, condition_id, use_cache=True):
        return self.market

    def leader_position_size(self, address, asset_id):
        return self.positions.get(asset_id)

    def close(self):
        pass


class RecordingExecutor(DryRunExecutor):
    """A paper executor that remembers what it was asked to do."""

    def __init__(self, fill_ratio: float = 1.0, succeed: bool = True):
        super().__init__()
        self.placed: list[Decision] = []
        self.fill_ratio = fill_ratio
        self.succeed = succeed

    def place(self, decision, meta):
        self.placed.append(decision)
        if not self.succeed:
            return OrderResult(success=False, error="insufficient balance", dry_run=True)
        return OrderResult(
            success=True,
            order_id=f"o{len(self.placed)}",
            status="matched",
            filled_shares=decision.shares * self.fill_ratio,
            dry_run=True,
        )


def build_config(leader, **overrides):
    base = dict(
        leaders=[leader],
        sizing=SizingConfig(mode="fixed", fixed_usdc=20.0, min_order_usdc=1.0, max_order_usdc=50.0),
        risk=RiskConfig(min_leader_notional_usdc=50.0),
        execution=ExecutionConfig(order_type="FAK", slippage_bps=100),
        poll_interval_seconds=1,
        db_path=":memory:",
        live=False,
        secrets=Secrets(),
    )
    base.update(overrides)
    return BotConfig(**base)


def build_engine(leader, market, store, trades, **cfg_overrides):
    source = FakeSource(trades=trades, market=market)
    executor = RecordingExecutor()
    engine = CopyEngine(build_config(leader, **cfg_overrides), store, source, executor)
    return engine, source, executor


# --------------------------------------------------------------------- basics

def test_a_qualifying_trade_is_copied_and_recorded(leader, market, store):
    engine, _, executor = build_engine(leader, market, store, [make_trade()])
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.copied == 1
    assert len(executor.placed) == 1
    assert store.get_position(ASSET_ID).shares > 0
    assert store.daily_spend() > 0
    assert len(store.recent_orders()) == 1


def test_a_trade_is_never_copied_twice(leader, market, store):
    engine, _, executor = build_engine(leader, market, store, [make_trade()])
    store.mark_initialised()

    engine.poll_once()
    second = engine.poll_once()
    assert second.new_trades == 0
    assert len(executor.placed) == 1


def test_idempotency_survives_a_restart(leader, market, tmp_path):
    trade = make_trade()
    db = str(tmp_path / "state.db")

    with Store(db) as store:
        engine, _, executor = build_engine(leader, market, store, [trade], db_path=db)
        store.mark_initialised()
        engine.poll_once()
        assert len(executor.placed) == 1

    with Store(db) as store:
        engine, _, executor = build_engine(leader, market, store, [trade], db_path=db)
        engine.poll_once()
        assert executor.placed == []


def test_skipped_trades_are_marked_seen_so_they_cannot_be_copied_late(leader, market, store):
    """A veto must be final; otherwise a filter that clears later would fire a
    stale order."""
    stale = make_trade(age_seconds=10_000)
    engine, _, executor = build_engine(leader, market, store, [stale])
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.skipped == 1
    assert store.has_seen(stale.key)
    assert engine.poll_once().new_trades == 0
    assert executor.placed == []


def test_trades_are_processed_oldest_first(leader, market, store):
    """An entry must be recorded before the exit that closes it."""
    entry = make_trade("BUY", age_seconds=120, tx_hash="0x1")
    exit_ = make_trade("SELL", age_seconds=10, tx_hash="0x2", size=500)
    engine, source, executor = build_engine(leader, market, store, [exit_, entry])
    source.positions = {ASSET_ID: 500.0}
    store.mark_initialised()

    engine.poll_once()
    assert [d.trade.side for d in executor.placed] == ["BUY", "SELL"]
    assert store.get_position(ASSET_ID) is not None  # only half sold


def test_an_exit_closes_the_position(leader, market, store):
    entry = make_trade("BUY", age_seconds=120, tx_hash="0x1")
    exit_ = make_trade("SELL", age_seconds=10, tx_hash="0x2", size=1000)
    engine, source, _ = build_engine(leader, market, store, [entry, exit_])
    source.positions = {ASSET_ID: 0.0}  # leader went flat
    store.mark_initialised()

    engine.poll_once()
    assert store.get_position(ASSET_ID) is None


# ------------------------------------------------------------------ cold start

def test_cold_start_ignores_history_on_a_fresh_database(leader, market, store):
    history = [make_trade(age_seconds=3600 * i, tx_hash=f"0x{i}") for i in range(1, 6)]
    engine, _, executor = build_engine(leader, market, store, history)

    marked = engine.cold_start()
    assert marked == 5
    assert engine.poll_once().new_trades == 0
    assert executor.placed == []


def test_cold_start_lookback_keeps_recent_trades_eligible(leader, market, store):
    recent = make_trade(age_seconds=60, tx_hash="0xrecent")
    old = make_trade(age_seconds=7200, tx_hash="0xold")
    engine, _, executor = build_engine(
        leader, market, store, [recent, old], cold_start_lookback_seconds=600
    )

    engine.cold_start()
    engine.poll_once()
    assert [d.trade.tx_hash for d in executor.placed] == ["0xrecent"]


def test_cold_start_only_runs_once(leader, market, store):
    engine, _, _ = build_engine(leader, market, store, [make_trade(age_seconds=9999)])
    assert engine.cold_start() == 1
    assert engine.cold_start() == 0


# ------------------------------------------------------------------ resilience

def test_a_failing_leader_fetch_is_reported_not_fatal(leader, market, store):
    engine, source, _ = build_engine(leader, market, store, [make_trade()])
    source.raise_on_fetch = RuntimeError("connection reset")
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.errors and "connection reset" in summary.errors[0]
    assert summary.copied == 0


def test_one_bad_leader_does_not_stop_the_others(market, store):
    from polycopy.config import Leader

    good = Leader(address="0x1111111111111111111111111111111111111111", label="good")
    bad = Leader(address="0x2222222222222222222222222222222222222222", label="bad")

    class HalfBrokenSource(FakeSource):
        def fetch_trades(self, address, limit=50, offset=0):
            if address == bad.address:
                raise RuntimeError("boom")
            return super().fetch_trades(address, limit, offset)

    source = HalfBrokenSource(trades=[make_trade(leader=good.address)], market=market)
    executor = RecordingExecutor()
    config = build_config(good)
    config.leaders = [bad, good]
    engine = CopyEngine(config, store, source, executor)
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.copied == 1
    assert len(summary.errors) == 1


def test_a_rejected_order_is_counted_and_leaves_no_position(leader, market, store):
    source = FakeSource(trades=[make_trade()], market=market)
    executor = RecordingExecutor(succeed=False)
    engine = CopyEngine(build_config(leader), store, source, executor)
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.failed == 1
    assert store.get_position(ASSET_ID) is None
    assert store.daily_spend() == 0.0
    assert store.recent_orders()[0]["error"] == "insufficient balance"


def test_a_partial_fill_only_books_what_filled(leader, market, store):
    source = FakeSource(trades=[make_trade()], market=market)
    executor = RecordingExecutor(fill_ratio=0.5)
    engine = CopyEngine(build_config(leader), store, source, executor)
    store.mark_initialised()

    engine.poll_once()
    intended = executor.placed[0].shares
    assert store.get_position(ASSET_ID).shares == pytest.approx(intended * 0.5)


def test_an_unfilled_order_counts_as_a_skip(leader, market, store):
    source = FakeSource(trades=[make_trade()], market=market)
    executor = RecordingExecutor(fill_ratio=0.0)
    engine = CopyEngine(build_config(leader), store, source, executor)
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.skipped == 1
    assert store.get_position(ASSET_ID) is None


def test_a_poisonous_trade_cannot_wedge_the_loop(leader, market, store):
    class ExplodingSource(FakeSource):
        def fetch_market(self, condition_id, use_cache=True):
            raise ValueError("gamma exploded")

    source = ExplodingSource(trades=[make_trade()], market=market)
    engine = CopyEngine(build_config(leader), store, source, RecordingExecutor())
    store.mark_initialised()

    summary = engine.poll_once()
    assert summary.failed == 1
    assert engine.poll_once().new_trades == 0  # marked seen, not retried forever


# ------------------------------------------------------------------ budgeting

def test_the_daily_cap_shrinks_then_stops_orders(leader, market, store):
    trades = [make_trade(tx_hash=f"0x{i}", age_seconds=100 - i) for i in range(5)]
    engine, _, executor = build_engine(
        leader,
        market,
        store,
        trades,
        risk=RiskConfig(min_leader_notional_usdc=50.0, daily_spend_cap_usdc=30.0),
    )
    store.mark_initialised()

    engine.poll_once()
    assert store.daily_spend() <= 30.0
    assert len(executor.placed) < len(trades)


def test_the_tighter_of_the_two_slippage_settings_wins(leader, market, store):
    engine, _, _ = build_engine(
        leader,
        market,
        store,
        [],
        execution=ExecutionConfig(slippage_bps=900),
        risk=RiskConfig(max_slippage_bps=50),
    )
    assert engine.slippage_bps == 50


# ---------------------------------------------------------------------- loop

def test_run_forever_stops_after_max_polls(leader, market, store):
    engine, source, _ = build_engine(leader, market, store, [make_trade()])
    engine.run_forever(max_polls=2)
    assert source.fetch_calls >= 2


def test_request_stop_ends_the_loop(leader, market, store):
    engine, _, _ = build_engine(leader, market, store, [])
    engine.request_stop()
    started = time.monotonic()
    engine.run_forever(max_polls=100)
    assert time.monotonic() - started < 2  # never slept through an interval


# --------------------------------------------------------------- reconciliation

def test_reconcile_is_a_no_op_in_dry_run(store):
    assert reconcile_positions(store, DryRunExecutor()) == []


def test_reconcile_reports_drift(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.4)

    class Liveish(DryRunExecutor):
        live = True

        def position_shares(self, token_id):
            return 60.0

    drift = reconcile_positions(store, Liveish())
    assert drift == [(ASSET_ID, 100.0, 60.0)]


def test_reconcile_tolerates_small_differences(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.4)

    class Liveish(DryRunExecutor):
        live = True

        def position_shares(self, token_id):
            return 100.005

    assert reconcile_positions(store, Liveish()) == []
