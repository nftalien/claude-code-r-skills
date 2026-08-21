"""Pre-trade risk gate.

Every check here is a veto with a human-readable reason, and the reason is
persisted alongside the trade so a run can always answer "why didn't you copy
that one?" after the fact.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from .config import RiskConfig
from .models import BUY, MarketMeta, SourceTrade
from .store import Store


@dataclass
class RiskVerdict:
    """Result of the risk gate.

    ``headroom`` is passed on to sizing so a partially-consumed budget shrinks
    the order instead of rejecting it.
    """

    ok: bool
    reason: str = ""
    headroom: dict[str, float] | None = None

    @classmethod
    def veto(cls, reason: str) -> RiskVerdict:
        return cls(ok=False, reason=reason)


def check_trade(
    trade: SourceTrade,
    meta: MarketMeta | None,
    cfg: RiskConfig,
    store: Store,
    now: float | None = None,
) -> RiskVerdict:
    now = time.time() if now is None else now

    if not trade.is_valid():
        return RiskVerdict.veto("malformed trade payload")

    age = now - trade.timestamp
    if age > cfg.max_trade_age_seconds:
        return RiskVerdict.veto(
            f"stale: {age:.0f}s old, limit {cfg.max_trade_age_seconds}s"
        )

    if meta is None:
        return RiskVerdict.veto("market metadata unavailable")

    condition = trade.condition_id.lower()
    if cfg.allow_condition_ids and condition not in cfg.allow_condition_ids:
        return RiskVerdict.veto("market not in allow_condition_ids")
    if condition in cfg.block_condition_ids:
        return RiskVerdict.veto("market in block_condition_ids")

    haystack = f"{meta.question} {trade.title}".lower()
    for keyword in cfg.block_keywords:
        if keyword in haystack:
            return RiskVerdict.veto(f"blocked keyword {keyword!r} in market question")

    if meta.closed or not meta.active:
        return RiskVerdict.veto("market is closed or inactive")
    if not meta.accepting_orders:
        return RiskVerdict.veto("market is not accepting orders")

    # Exits are allowed to bypass the checks below: if the leader is getting out,
    # a price band or a full budget is no reason to keep holding.
    if trade.side != BUY:
        return RiskVerdict(ok=True, reason="exit permitted", headroom={})

    if not cfg.min_price <= trade.price <= cfg.max_price:
        return RiskVerdict.veto(
            f"price {trade.price:.3f} outside band "
            f"[{cfg.min_price:.2f}, {cfg.max_price:.2f}]"
        )

    if trade.notional < cfg.min_leader_notional_usdc:
        return RiskVerdict.veto(
            f"leader notional ${trade.notional:.2f} below "
            f"${cfg.min_leader_notional_usdc:.2f} threshold"
        )

    if meta.end_date_ts is not None:
        seconds_left = meta.end_date_ts - now
        if seconds_left < cfg.min_seconds_to_close:
            return RiskVerdict.veto(
                f"market resolves in {max(seconds_left, 0):.0f}s, "
                f"below {cfg.min_seconds_to_close}s buffer"
            )

    market_used = store.market_exposure(trade.condition_id)
    market_headroom = cfg.max_market_exposure_usdc - market_used
    if market_headroom <= 0:
        return RiskVerdict.veto(
            f"market exposure ${market_used:.2f} at cap ${cfg.max_market_exposure_usdc:.2f}"
        )

    total_used = store.total_exposure()
    total_headroom = cfg.max_total_exposure_usdc - total_used
    if total_headroom <= 0:
        return RiskVerdict.veto(
            f"total exposure ${total_used:.2f} at cap ${cfg.max_total_exposure_usdc:.2f}"
        )

    spent_today = store.daily_spend()
    daily_headroom = cfg.daily_spend_cap_usdc - spent_today
    if daily_headroom <= 0:
        return RiskVerdict.veto(
            f"daily spend ${spent_today:.2f} at cap ${cfg.daily_spend_cap_usdc:.2f}"
        )

    # Only block a *new* market once the cap is hit. Adding to a market we
    # already hold - even on the other outcome - opens no new market, so the
    # test is market exposure rather than this particular token.
    if market_used <= 0 and store.open_market_count() >= cfg.max_open_markets:
        return RiskVerdict.veto(
            f"already holding {cfg.max_open_markets} markets (max_open_markets)"
        )

    return RiskVerdict(
        ok=True,
        reason="passed risk checks",
        headroom={
            "market_headroom": market_headroom,
            "total_headroom": total_headroom,
            "daily_headroom": daily_headroom,
        },
    )
