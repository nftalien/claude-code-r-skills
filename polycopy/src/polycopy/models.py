"""Core value types shared across the bot."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any

BUY = "BUY"
SELL = "SELL"


def parse_token_ids(raw: Any) -> tuple[str, ...]:
    """Parse Gamma's ``clobTokenIds``, which arrives JSON-encoded inside JSON."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return ()
    if isinstance(raw, list):
        return tuple(str(v) for v in raw)
    return ()


def _f(value: Any, default: float = 0.0) -> float:
    """Coerce an API field to float without exploding on None/''/garbage."""
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class SourceTrade:
    """A single fill observed on a watched ("leader") wallet.

    Field names mirror the Polymarket data API, but every accessor is defensive:
    the API has added and renamed keys before, and a copy bot that crashes on an
    unexpected payload is a copy bot that silently stops copying.
    """

    leader: str
    asset_id: str          # ERC1155 token id of the outcome ("clob token id")
    condition_id: str      # market identifier
    side: str              # BUY | SELL
    price: float           # price per share, 0..1
    size: float            # shares
    timestamp: int         # unix seconds
    title: str = ""
    outcome: str = ""
    slug: str = ""
    tx_hash: str = ""
    raw: dict[str, Any] = field(default_factory=dict, repr=False, compare=False)

    @property
    def notional(self) -> float:
        """USDC value of the leader's fill."""
        return self.price * self.size

    @property
    def key(self) -> str:
        """Stable idempotency key.

        A transaction hash is not unique on its own: one Polygon transaction can
        settle several fills, and multi-outcome trades share a hash. Hashing the
        full tuple keeps distinct fills distinct while staying stable across
        restarts and re-fetches.
        """
        parts = (
            self.leader.lower(),
            self.tx_hash.lower(),
            self.asset_id,
            self.side,
            f"{self.price:.6f}",
            f"{self.size:.6f}",
            str(self.timestamp),
        )
        return hashlib.sha256("|".join(parts).encode()).hexdigest()[:32]

    @classmethod
    def from_api(cls, payload: dict[str, Any], leader: str) -> SourceTrade:
        side = str(payload.get("side", "")).upper()
        timestamp = _f(payload.get("timestamp"))
        if timestamp > 1e12:  # milliseconds, not seconds
            timestamp /= 1000.0
        return cls(
            leader=leader.lower(),
            asset_id=str(payload.get("asset") or payload.get("assetId") or ""),
            condition_id=str(payload.get("conditionId") or payload.get("condition_id") or ""),
            side=side,
            price=_f(payload.get("price")),
            size=_f(payload.get("size")),
            timestamp=int(timestamp),
            title=str(payload.get("title") or ""),
            outcome=str(payload.get("outcome") or ""),
            slug=str(payload.get("slug") or payload.get("eventSlug") or ""),
            tx_hash=str(payload.get("transactionHash") or payload.get("txHash") or ""),
            raw=payload,
        )

    def is_valid(self) -> bool:
        return bool(
            self.asset_id
            and self.side in (BUY, SELL)
            and 0.0 < self.price < 1.0
            and self.size > 0
            and self.timestamp > 0
        )


@dataclass(frozen=True)
class MarketMeta:
    """Market metadata used for risk filtering and order rounding."""

    condition_id: str
    question: str = ""
    slug: str = ""
    closed: bool = False
    active: bool = True
    accepting_orders: bool = True
    end_date_ts: int | None = None       # unix seconds, None when open-ended
    neg_risk: bool = False
    tick_size: float = 0.01
    min_order_size: float = 5.0          # shares
    token_ids: tuple[str, ...] = ()

    @classmethod
    def from_gamma(cls, payload: dict[str, Any]) -> MarketMeta:
        end_ts: int | None = None
        end_raw = payload.get("endDate") or payload.get("end_date_iso")
        if end_raw:
            from datetime import datetime

            try:
                end_ts = int(
                    datetime.fromisoformat(str(end_raw).replace("Z", "+00:00")).timestamp()
                )
            except ValueError:
                end_ts = None

        return cls(
            condition_id=str(payload.get("conditionId") or payload.get("condition_id") or ""),
            question=str(payload.get("question") or ""),
            slug=str(payload.get("slug") or ""),
            closed=bool(payload.get("closed", False)),
            active=bool(payload.get("active", True)),
            accepting_orders=bool(payload.get("acceptingOrders", True)),
            end_date_ts=end_ts,
            neg_risk=bool(payload.get("negRisk", False)),
            tick_size=_f(payload.get("orderPriceMinTickSize"), 0.01) or 0.01,
            min_order_size=_f(payload.get("orderMinSize"), 5.0) or 5.0,
            token_ids=parse_token_ids(payload.get("clobTokenIds")),
        )


@dataclass(frozen=True)
class LeaderPosition:
    """A position held by a watched wallet (used for proportional exits)."""

    asset_id: str
    condition_id: str
    size: float
    avg_price: float = 0.0

    @classmethod
    def from_api(cls, payload: dict[str, Any]) -> LeaderPosition:
        return cls(
            asset_id=str(payload.get("asset") or ""),
            condition_id=str(payload.get("conditionId") or ""),
            size=_f(payload.get("size")),
            avg_price=_f(payload.get("avgPrice")),
        )


@dataclass
class Decision:
    """Outcome of running one source trade through the risk + sizing pipeline."""

    trade: SourceTrade
    action: str                    # "copy" | "skip"
    reason: str = ""
    shares: float = 0.0            # shares we intend to trade
    limit_price: float = 0.0       # our limit price after slippage budget
    notional: float = 0.0          # USDC at limit price

    @property
    def copying(self) -> bool:
        return self.action == "copy"

    @classmethod
    def skip(cls, trade: SourceTrade, reason: str) -> Decision:
        return cls(trade=trade, action="skip", reason=reason)


@dataclass
class OrderResult:
    """What happened when we tried to place the mirrored order."""

    success: bool
    order_id: str = ""
    status: str = ""
    filled_shares: float = 0.0
    error: str = ""
    dry_run: bool = False
