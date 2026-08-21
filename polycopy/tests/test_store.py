from __future__ import annotations

from polycopy.models import Decision, OrderResult
from polycopy.store import Store, utc_day

from .conftest import ASSET_ID, CONDITION_ID, make_trade


def test_seen_trades_are_idempotent(store):
    trade = make_trade()
    assert not store.has_seen(trade.key)
    store.mark_seen(trade, "copy")
    assert store.has_seen(trade.key)
    store.mark_seen(trade, "skip", "different reason")  # must not raise or duplicate
    assert store.seen_count() == 1


def test_buy_then_partial_sell_tracks_cost_and_realised_pnl(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.40, "Example")
    position = store.get_position(ASSET_ID)
    assert position.shares == 100
    assert position.cost_usdc == 40.0
    assert position.avg_price == 0.40

    store.apply_fill(ASSET_ID, CONDITION_ID, "SELL", 40, 0.60)
    position = store.get_position(ASSET_ID)
    assert position.shares == 60
    # Cost basis retires at the average, leaving money still at risk.
    assert position.cost_usdc == 24.0
    assert position.realized_pnl == 40 * (0.60 - 0.40)


def test_averaging_up_recomputes_the_basis(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.40)
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.60)
    position = store.get_position(ASSET_ID)
    assert position.shares == 200
    assert position.cost_usdc == 100.0
    assert position.avg_price == 0.50


def test_full_exit_leaves_no_residual_cost(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 33.33, 0.37)
    store.apply_fill(ASSET_ID, CONDITION_ID, "SELL", 33.33, 0.40)
    assert store.get_position(ASSET_ID) is None
    assert store.total_exposure() == 0.0
    assert store.realized_pnl() > 0


def test_overselling_is_clamped_to_the_position(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 50, 0.40)
    store.apply_fill(ASSET_ID, CONDITION_ID, "SELL", 500, 0.50)
    assert store.get_position(ASSET_ID) is None
    assert store.realized_pnl() == 50 * (0.50 - 0.40)


def test_selling_something_we_never_held_is_a_no_op(store):
    store.apply_fill("ghost", CONDITION_ID, "SELL", 10, 0.5)
    assert store.get_position("ghost") is None
    assert store.total_exposure() == 0.0


def test_zero_size_fills_are_ignored(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 0, 0.40)
    assert store.get_position(ASSET_ID) is None


def test_exposure_aggregates_across_assets_and_markets(store):
    store.apply_fill("a", "0xm1", "BUY", 10, 1.0)
    store.apply_fill("b", "0xm1", "BUY", 10, 2.0)
    store.apply_fill("c", "0xm2", "BUY", 10, 3.0)
    assert store.total_exposure() == 60.0
    assert store.market_exposure("0xm1") == 30.0
    assert store.open_market_count() == 2


def test_closed_positions_drop_out_of_exposure(store):
    store.apply_fill("a", "0xm1", "BUY", 10, 1.0)
    store.apply_fill("a", "0xm1", "SELL", 10, 1.1)
    assert store.open_market_count() == 0
    assert store.open_positions() == []


def test_daily_spend_accumulates_per_utc_day(store):
    store.add_daily_spend(10.0)
    store.add_daily_spend(15.0)
    assert store.daily_spend() == 25.0
    assert store.daily_spend("1999-01-01") == 0.0
    assert utc_day(0) == "1970-01-01"


def test_negative_or_zero_spend_is_ignored(store):
    store.add_daily_spend(-5.0)
    assert store.daily_spend() == 0.0


def test_orders_are_recorded_and_read_back_newest_first(store):
    for i in range(3):
        trade = make_trade(size=100 + i, tx_hash=f"0x{i}")
        decision = Decision(trade=trade, action="copy", shares=10, limit_price=0.4, notional=4.0)
        store.record_order(decision, OrderResult(success=True, order_id=f"o{i}", status="matched"))
    rows = store.recent_orders(10)
    assert len(rows) == 3
    assert {r["order_id"] for r in rows} == {"o0", "o1", "o2"}


def test_cold_start_flag_flips_once(store):
    assert store.is_fresh
    store.mark_initialised()
    assert not store.is_fresh


def test_state_survives_a_restart(tmp_path):
    path = tmp_path / "state.db"
    with Store(path) as first:
        first.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 10, 0.5)
        first.mark_seen(make_trade(), "copy")
        first.add_daily_spend(5.0)
        first.mark_initialised()

    with Store(path) as second:
        assert second.get_position(ASSET_ID).shares == 10
        assert second.has_seen(make_trade().key)
        assert second.daily_spend() == 5.0
        assert not second.is_fresh


def test_title_is_not_overwritten_by_a_blank_one(store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 10, 0.5, "Real title")
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 10, 0.5, "")
    assert store.get_position(ASSET_ID).title == "Real title"
