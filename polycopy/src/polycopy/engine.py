"""The copy loop: poll leaders, gate each fill, size it, place it, record it."""

from __future__ import annotations

import logging
import signal
import time
from dataclasses import dataclass, field

from .config import BotConfig, Leader
from .datasource import DataSource
from .execution import Executor
from .models import BUY, Decision, OrderResult, SourceTrade
from .risk import check_trade
from .sizing import build_decision
from .store import Store

log = logging.getLogger(__name__)


@dataclass
class PollSummary:
    """What one pass over every leader did."""

    leaders_polled: int = 0
    trades_fetched: int = 0
    new_trades: int = 0
    copied: int = 0
    skipped: int = 0
    failed: int = 0
    notional: float = 0.0
    errors: list[str] = field(default_factory=list)

    def merge(self, other: PollSummary) -> None:
        self.leaders_polled += other.leaders_polled
        self.trades_fetched += other.trades_fetched
        self.new_trades += other.new_trades
        self.copied += other.copied
        self.skipped += other.skipped
        self.failed += other.failed
        self.notional += other.notional
        self.errors.extend(other.errors)

    def __str__(self) -> str:
        return (
            f"{self.leaders_polled} leader(s), {self.trades_fetched} fetched, "
            f"{self.new_trades} new, {self.copied} copied (${self.notional:.2f}), "
            f"{self.skipped} skipped, {self.failed} failed"
        )


class CopyEngine:
    def __init__(
        self,
        config: BotConfig,
        store: Store,
        source: DataSource,
        executor: Executor,
    ) -> None:
        self.config = config
        self.store = store
        self.source = source
        self.executor = executor
        self._stop = False
        # The tighter of the two slippage settings wins, so a permissive
        # execution config can never quietly exceed the risk ceiling.
        self.slippage_bps = min(
            config.execution.slippage_bps, config.risk.max_slippage_bps
        )

    # --------------------------------------------------------------- lifecycle

    def cold_start(self) -> int:
        """Mark pre-existing leader history as seen on a fresh database.

        Without this, a first run would copy every trade the API returns - up to
        50 historic positions at once. Only trades inside
        ``cold_start_lookback_seconds`` stay eligible.
        """
        if not self.store.is_fresh:
            return 0

        cutoff = time.time() - self.config.cold_start_lookback_seconds
        marked = 0
        for leader in self.config.enabled_leaders:
            try:
                trades = self.source.fetch_trades(leader.address, limit=self.config.fetch_limit)
            except Exception as exc:  # noqa: BLE001
                log.warning("cold start fetch failed for %s: %s", leader.label, exc)
                continue
            for trade in trades:
                if trade.timestamp < cutoff:
                    self.store.mark_seen(trade, "cold_start", "predates first run")
                    marked += 1

        self.store.mark_initialised()
        log.info("cold start: marked %d historic trade(s) as seen", marked)
        return marked

    def request_stop(self) -> None:
        self._stop = True

    def install_signal_handlers(self) -> None:
        def handler(signum: int, _frame: object) -> None:
            log.info("received signal %s, finishing current poll then stopping", signum)
            self.request_stop()

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                # Not the main thread, or a platform without the signal.
                pass

    # -------------------------------------------------------------------- poll

    def poll_once(self) -> PollSummary:
        summary = PollSummary()
        for leader in self.config.enabled_leaders:
            summary.merge(self._poll_leader(leader))
        return summary

    def _poll_leader(self, leader: Leader) -> PollSummary:
        summary = PollSummary(leaders_polled=1)
        try:
            trades = self.source.fetch_trades(leader.address, limit=self.config.fetch_limit)
        except Exception as exc:  # noqa: BLE001 - a flaky leader must not stop the rest
            msg = f"fetch failed for {leader.label}: {type(exc).__name__}: {exc}"
            log.warning(msg)
            summary.errors.append(msg)
            return summary

        summary.trades_fetched = len(trades)
        # Oldest first: an entry must be recorded before the exit that closes it.
        fresh = sorted(
            (t for t in trades if not self.store.has_seen(t.key)),
            key=lambda t: t.timestamp,
        )
        summary.new_trades = len(fresh)

        for trade in fresh:
            try:
                self._handle_trade(trade, leader, summary)
            except Exception as exc:  # noqa: BLE001
                msg = f"error handling trade {trade.key[:8]}: {type(exc).__name__}: {exc}"
                log.exception(msg)
                summary.errors.append(msg)
                summary.failed += 1
                # Marked seen so a permanently poisonous payload cannot wedge
                # the loop into retrying it on every poll.
                self.store.mark_seen(trade, "error", msg[:200])
        return summary

    def _handle_trade(self, trade: SourceTrade, leader: Leader, summary: PollSummary) -> None:
        meta = self.source.fetch_market(trade.condition_id)
        verdict = check_trade(trade, meta, self.config.risk, self.store)
        if not verdict.ok:
            log.info("skip [%s] %s: %s", leader.label, _describe(trade), verdict.reason)
            self.store.mark_seen(trade, "skip", verdict.reason)
            summary.skipped += 1
            return

        assert meta is not None  # check_trade vetoes a missing market

        headroom = dict(verdict.headroom or {})
        headroom["slippage_bps"] = float(self.slippage_bps)
        headroom["whole_shares"] = 1.0 if self.config.execution.round_shares_down else 0.0

        leader_position_after: float | None = None
        if trade.side != BUY and self.config.sizing.exit_policy == "proportional":
            leader_position_after = self.source.leader_position_size(
                leader.address, trade.asset_id
            )

        decision = build_decision(
            trade=trade,
            leader=leader,
            meta=meta,
            cfg=self.config.sizing,
            store=self.store,
            budget_caps=headroom,
            leader_position_after=leader_position_after,
        )
        if not decision.copying:
            log.info("skip [%s] %s: %s", leader.label, _describe(trade), decision.reason)
            self.store.mark_seen(trade, "skip", decision.reason)
            summary.skipped += 1
            return

        result = self.executor.place(decision, meta)
        self.store.record_order(decision, result)
        self._settle(decision, result, summary)

        action = "copy" if result.success else "failed"
        self.store.mark_seen(trade, action, result.error or decision.reason)

    def _settle(self, decision: Decision, result: OrderResult, summary: PollSummary) -> None:
        """Fold a result into the ledger and the run summary."""
        if not result.success:
            log.warning(
                "order rejected: %s (%s)", result.error or "unknown error", result.status
            )
            summary.failed += 1
            return

        filled = min(result.filled_shares, decision.shares)
        if filled <= 0:
            log.info("order %s placed but unfilled (status=%s)", result.order_id, result.status)
            summary.skipped += 1
            return

        trade = decision.trade
        self.store.apply_fill(
            asset_id=trade.asset_id,
            condition_id=trade.condition_id,
            side=trade.side,
            shares=filled,
            price=decision.limit_price,
            title=trade.title,
        )
        notional = filled * decision.limit_price
        if trade.side == BUY:
            self.store.add_daily_spend(notional)

        summary.copied += 1
        summary.notional += notional
        log.info(
            "%s %s %.2f shares @ %.3f ($%.2f) - %s",
            "PAPER" if result.dry_run else "FILLED",
            trade.side,
            filled,
            decision.limit_price,
            notional,
            trade.title or trade.condition_id,
        )

    # -------------------------------------------------------------------- loop

    def run_forever(self, max_polls: int | None = None) -> PollSummary:
        """Poll until stopped. ``max_polls`` bounds the loop for tests."""
        self.cold_start()
        total = PollSummary()
        polls = 0
        while not self._stop and (max_polls is None or polls < max_polls):
            started = time.monotonic()
            summary = self.poll_once()
            total.merge(summary)
            polls += 1
            if summary.new_trades or summary.errors:
                log.info("poll %d: %s", polls, summary)
            else:
                log.debug("poll %d: %s", polls, summary)

            if self._stop or (max_polls is not None and polls >= max_polls):
                break
            elapsed = time.monotonic() - started
            time.sleep(max(0.0, self.config.poll_interval_seconds - elapsed))
        return total


def _describe(trade: SourceTrade) -> str:
    label = trade.title or trade.condition_id[:12]
    outcome = f" {trade.outcome}" if trade.outcome else ""
    return f"{trade.side} {trade.size:g}@{trade.price:.3f} {label}{outcome}"


def reconcile_positions(store: Store, executor: Executor) -> list[tuple[str, float, float]]:
    """Compare our ledger against on-chain balances.

    Returns ``(asset_id, ledger_shares, chain_shares)`` for every mismatch. The
    ledger is optimistic about fills, so drift is expected and worth surfacing
    rather than silently trading on.
    """
    if not getattr(executor, "live", False):
        return []
    lookup = getattr(executor, "position_shares", None)
    if lookup is None:
        return []

    drift: list[tuple[str, float, float]] = []
    for position in store.open_positions():
        actual = lookup(position.asset_id)
        if actual is None:
            continue
        if abs(actual - position.shares) > max(0.01, position.shares * 0.01):
            drift.append((position.asset_id, position.shares, actual))
    return drift
