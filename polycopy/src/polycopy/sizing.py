"""Turning a leader's fill into an order size and a limit price.

Sizing is deliberately separate from risk: risk decides *whether* to copy, this
module decides *how much*, and both can independently veto (a size that rounds
below the market minimum is a veto too).
"""

from __future__ import annotations

import logging
import math

from .config import Leader, SizingConfig
from .models import BUY, SELL, Decision, MarketMeta, SourceTrade
from .store import Store

log = logging.getLogger(__name__)

#: Polymarket rejects orders below roughly one dollar of notional.
MIN_NOTIONAL_USDC = 1.0


def round_to_tick(price: float, tick: float, direction: str) -> float:
    """Snap a price onto the market's tick grid.

    ``direction`` is "up" for buys and "down" for sells, so rounding always
    spends the slippage budget in the direction that helps the order fill rather
    than quietly making it unmarketable.
    """
    if tick <= 0:
        return round(price, 4)
    steps = price / tick
    # Nudge for float noise: 0.63 / 0.01 is 62.99999999999999 in binary floating
    # point, and rounding that down would drop a whole tick.
    snapped = math.ceil(steps - 1e-9) if direction == "up" else math.floor(steps + 1e-9)
    # Ticks are 0.1/0.01/0.001, so 4 decimals is always enough to land exactly.
    return round(snapped * tick, 4)


def _whole_shares(budget_caps: dict[str, float]) -> bool:
    return bool(budget_caps.get("whole_shares", 0))


def round_shares(shares: float, whole: bool) -> float:
    """Round a share count *down* so we never exceed the intended notional."""
    if whole:
        return float(math.floor(shares))
    return math.floor(shares * 100) / 100


def limit_price_for(trade: SourceTrade, meta: MarketMeta, slippage_bps: int) -> float:
    """Our limit price: the leader's fill price plus a slippage budget.

    ``slippage_bps`` is relative to the price, so 100 bps on a 0.40 fill allows
    0.404 - the convention that keeps a fixed setting sane across the whole
    0..1 probability range.
    """
    factor = slippage_bps / 10_000.0
    tick = meta.tick_size
    if trade.side == BUY:
        raw = trade.price * (1 + factor)
        price = round_to_tick(raw, tick, "up")
        return min(price, round(1 - tick, 4))
    raw = trade.price * (1 - factor)
    price = round_to_tick(raw, tick, "down")
    return max(price, tick)


def _entry_notional(trade: SourceTrade, leader: Leader, cfg: SizingConfig) -> float:
    if cfg.mode == "fixed":
        target = cfg.fixed_usdc
    elif cfg.mode == "proportional":
        target = trade.notional * cfg.proportional_factor
    else:  # bankroll_fraction
        target = cfg.bankroll_usdc * cfg.bankroll_fraction
    return target * leader.weight


def size_entry(
    trade: SourceTrade,
    leader: Leader,
    meta: MarketMeta,
    cfg: SizingConfig,
    store: Store,
    budget_caps: dict[str, float],
) -> Decision:
    """Size a BUY. ``budget_caps`` carries the headroom left by the risk layer."""
    price = limit_price_for(trade, meta, budget_caps.get("slippage_bps", 100))
    if price <= 0 or price >= 1:
        return Decision.skip(trade, f"limit price {price} outside (0, 1)")

    target = _entry_notional(trade, leader, cfg)
    target = min(target, cfg.max_order_usdc)
    if leader.max_order_usdc is not None:
        target = min(target, leader.max_order_usdc)

    # The risk layer computed how much room is left; sizing shrinks to fit
    # rather than rejecting outright, so a nearly-full budget still trades.
    for name in ("market_headroom", "total_headroom", "daily_headroom"):
        if name in budget_caps:
            target = min(target, budget_caps[name])

    if target < max(cfg.min_order_usdc, MIN_NOTIONAL_USDC):
        return Decision.skip(
            trade,
            f"sized notional ${target:.2f} below minimum "
            f"${max(cfg.min_order_usdc, MIN_NOTIONAL_USDC):.2f}",
        )

    shares = round_shares(target / price, _whole_shares(budget_caps))
    if shares < meta.min_order_size:
        return Decision.skip(
            trade,
            f"{shares:g} shares below market minimum {meta.min_order_size:g}",
        )

    notional = shares * price
    if notional < MIN_NOTIONAL_USDC:
        return Decision.skip(trade, f"order notional ${notional:.2f} below $1 minimum")

    return Decision(
        trade=trade,
        action="copy",
        reason=f"entry sized by {cfg.mode}",
        shares=shares,
        limit_price=price,
        notional=notional,
    )


def size_exit(
    trade: SourceTrade,
    meta: MarketMeta,
    cfg: SizingConfig,
    store: Store,
    leader_position_after: float | None,
    budget_caps: dict[str, float],
) -> Decision:
    """Size a SELL against *our* position, never against the leader's size.

    The leader may hold ten thousand shares where we hold fifty; copying their
    absolute sell size would be meaningless. What transfers is the *fraction*
    of their position they exited.
    """
    if cfg.exit_policy == "off":
        return Decision.skip(trade, "exit_policy=off, ignoring leader sells")

    position = store.get_position(trade.asset_id)
    if position is None or position.shares <= 0:
        return Decision.skip(trade, "no position held in this outcome")

    price = limit_price_for(trade, meta, budget_caps.get("slippage_bps", 100))
    if price <= 0 or price >= 1:
        return Decision.skip(trade, f"limit price {price} outside (0, 1)")

    if cfg.exit_policy == "full":
        fraction = 1.0
        reason = "full exit"
    else:
        fraction, reason = _exit_fraction(trade, leader_position_after)

    shares = round_shares(position.shares * fraction, _whole_shares(budget_caps))

    # A dust remainder cannot be sold later (it falls under the market minimum),
    # so a trim that would strand one is promoted to a full exit.
    remainder = position.shares - shares
    if 0 < remainder < meta.min_order_size:
        shares = round_shares(position.shares, _whole_shares(budget_caps))
        reason += " (rounded up to full exit: remainder below market minimum)"

    if shares <= 0:
        return Decision.skip(trade, "computed exit size rounds to zero")
    if shares < meta.min_order_size:
        return Decision.skip(
            trade, f"exit of {shares:g} shares below market minimum {meta.min_order_size:g}"
        )

    return Decision(
        trade=trade,
        action="copy",
        reason=reason,
        shares=shares,
        limit_price=price,
        notional=shares * price,
    )


def _exit_fraction(trade: SourceTrade, leader_position_after: float | None) -> tuple[float, str]:
    """Fraction of our position to sell, mirroring the leader's trim.

    When the leader's remaining position cannot be read we exit in full: flat is
    the safe default, and holding a position whose thesis-owner may have already
    left is the risk this bot exists to avoid.
    """
    if leader_position_after is None:
        return 1.0, "full exit (leader position unavailable, defaulting to flat)"
    before = leader_position_after + trade.size
    if before <= 0:
        return 1.0, "full exit (leader position before sale was zero)"
    fraction = min(1.0, trade.size / before)
    return fraction, f"proportional exit: leader sold {fraction:.1%} of position"


def build_decision(
    trade: SourceTrade,
    leader: Leader,
    meta: MarketMeta,
    cfg: SizingConfig,
    store: Store,
    budget_caps: dict[str, float],
    leader_position_after: float | None = None,
) -> Decision:
    if trade.side == BUY:
        return size_entry(trade, leader, meta, cfg, store, budget_caps)
    if trade.side == SELL:
        return size_exit(trade, meta, cfg, store, leader_position_after, budget_caps)
    return Decision.skip(trade, f"unknown side {trade.side!r}")
