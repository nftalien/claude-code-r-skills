"""Configuration loading: YAML for strategy, environment for secrets.

Secrets are deliberately kept out of the YAML file so the config can be
committed and shared while the private key lives only in the environment.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any

import yaml

POLYGON_CHAIN_ID = 137
DEFAULT_CLOB_HOST = "https://clob.polymarket.com"
DEFAULT_DATA_API = "https://data-api.polymarket.com"
DEFAULT_GAMMA_API = "https://gamma-api.polymarket.com"


class ConfigError(ValueError):
    """Raised when the config file is malformed or internally inconsistent."""


@dataclass
class Leader:
    """A wallet to copy."""

    address: str
    label: str = ""
    enabled: bool = True
    weight: float = 1.0
    #: Hard ceiling on a single copied order for this leader, in USDC.
    max_order_usdc: float | None = None

    def __post_init__(self) -> None:
        self.address = self.address.strip().lower()
        if not (self.address.startswith("0x") and len(self.address) == 42):
            raise ConfigError(
                f"leader address is not a 0x-prefixed 20-byte address: {self.address!r}"
            )
        if self.weight <= 0:
            raise ConfigError(f"leader {self.address} has non-positive weight {self.weight}")
        if not self.label:
            self.label = self.address[:10]


@dataclass
class SizingConfig:
    """How large our mirrored order should be.

    modes:
      fixed             - always spend ``fixed_usdc`` per copied entry
      proportional      - spend ``proportional_factor`` x the leader's notional
      bankroll_fraction - spend ``bankroll_fraction`` x our configured bankroll
    """

    mode: str = "fixed"
    fixed_usdc: float = 10.0
    proportional_factor: float = 0.01
    bankroll_fraction: float = 0.01
    bankroll_usdc: float = 1000.0
    min_order_usdc: float = 1.0
    max_order_usdc: float = 50.0
    #: Exits: "proportional" mirrors the fraction the leader sold, "full" dumps
    #: our whole position, "off" ignores the leader's sells entirely.
    exit_policy: str = "proportional"

    _MODES = ("fixed", "proportional", "bankroll_fraction")
    _EXITS = ("proportional", "full", "off")

    def __post_init__(self) -> None:
        if self.mode not in self._MODES:
            raise ConfigError(f"sizing.mode must be one of {self._MODES}, got {self.mode!r}")
        if self.exit_policy not in self._EXITS:
            raise ConfigError(
                f"sizing.exit_policy must be one of {self._EXITS}, got {self.exit_policy!r}"
            )
        if self.min_order_usdc > self.max_order_usdc:
            raise ConfigError("sizing.min_order_usdc exceeds sizing.max_order_usdc")
        if self.max_order_usdc <= 0:
            raise ConfigError("sizing.max_order_usdc must be positive")


@dataclass
class RiskConfig:
    """Filters applied before any order is built. Every one of these can veto."""

    #: Ignore fills outside this price band - cheap longshots and near-resolved
    #: markets both copy badly (the edge is gone by the time we see the fill).
    min_price: float = 0.05
    max_price: float = 0.95
    #: Ignore leader fills smaller than this - usually dust or fee rebates.
    min_leader_notional_usdc: float = 50.0
    #: Never let one market hold more than this much of our money.
    max_market_exposure_usdc: float = 100.0
    #: Never let the book as a whole exceed this.
    max_total_exposure_usdc: float = 1000.0
    #: Rolling UTC-day cap on money deployed into new entries.
    daily_spend_cap_usdc: float = 200.0
    #: Refuse to copy a fill we saw too late - the price has moved on.
    max_trade_age_seconds: int = 300
    #: Refuse to enter a market that resolves within this window.
    min_seconds_to_close: int = 3600
    #: Ceiling on execution.slippage_bps (relative bps of the fill price);
    #: the effective slippage budget is the smaller of the two.
    max_slippage_bps: int = 200
    #: Cap on concurrent open markets.
    max_open_markets: int = 25
    allow_condition_ids: list[str] = field(default_factory=list)
    block_condition_ids: list[str] = field(default_factory=list)
    #: Case-insensitive substrings matched against the market question.
    block_keywords: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not 0 < self.min_price < self.max_price < 1:
            raise ConfigError(
                "risk requires 0 < min_price < max_price < 1, got "
                f"{self.min_price} / {self.max_price}"
            )
        self.allow_condition_ids = [c.lower() for c in self.allow_condition_ids]
        self.block_condition_ids = [c.lower() for c in self.block_condition_ids]
        self.block_keywords = [k.lower() for k in self.block_keywords]


@dataclass
class ExecutionConfig:
    """How the mirrored order reaches the book."""

    #: FAK crosses the spread and cancels the remainder - the right default for
    #: copying, where a resting order that never fills is worse than no order.
    order_type: str = "FAK"
    #: Slippage budget in bps *relative to the leader's fill price*: 100 bps
    #: on a 0.40 fill permits paying up to 0.404.
    slippage_bps: int = 100
    #: Round our size down to a whole number of shares to dodge tick issues.
    round_shares_down: bool = True
    #: Seconds to wait before polling the order's terminal status.
    fill_check_delay_seconds: float = 2.0

    _TYPES = ("FAK", "FOK", "GTC")

    def __post_init__(self) -> None:
        self.order_type = self.order_type.upper()
        if self.order_type not in self._TYPES:
            raise ConfigError(f"execution.order_type must be one of {self._TYPES}")


@dataclass
class Secrets:
    """Credentials, sourced only from the environment."""

    private_key: str = ""
    api_key: str = ""
    api_secret: str = ""
    api_passphrase: str = ""
    #: Address holding the USDC when trading through a Polymarket proxy wallet.
    funder: str = ""
    #: 0 = EOA, 1 = email/magic proxy, 2 = browser wallet proxy.
    signature_type: int = 0

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> Secrets:
        e = os.environ if env is None else env
        raw_sig = e.get("POLYMARKET_SIGNATURE_TYPE", "0").strip() or "0"
        try:
            sig = int(raw_sig)
        except ValueError as exc:
            raise ConfigError(
                f"POLYMARKET_SIGNATURE_TYPE must be 0, 1 or 2 (got {raw_sig!r})"
            ) from exc
        if sig not in (0, 1, 2):
            raise ConfigError(f"POLYMARKET_SIGNATURE_TYPE must be 0, 1 or 2 (got {sig})")
        return cls(
            private_key=e.get("POLYMARKET_PRIVATE_KEY", "").strip(),
            api_key=e.get("POLYMARKET_API_KEY", "").strip(),
            api_secret=e.get("POLYMARKET_API_SECRET", "").strip(),
            api_passphrase=e.get("POLYMARKET_API_PASSPHRASE", "").strip(),
            funder=e.get("POLYMARKET_FUNDER", "").strip(),
            signature_type=sig,
        )

    @property
    def has_key(self) -> bool:
        return bool(self.private_key)

    @property
    def has_api_creds(self) -> bool:
        return bool(self.api_key and self.api_secret and self.api_passphrase)

    def __repr__(self) -> str:  # never leak a key into a log line
        return (
            f"Secrets(private_key={'set' if self.has_key else 'unset'}, "
            f"api_creds={'set' if self.has_api_creds else 'unset'}, "
            f"funder={self.funder or 'unset'}, signature_type={self.signature_type})"
        )


@dataclass
class BotConfig:
    leaders: list[Leader] = field(default_factory=list)
    sizing: SizingConfig = field(default_factory=SizingConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)
    execution: ExecutionConfig = field(default_factory=ExecutionConfig)
    poll_interval_seconds: float = 15.0
    #: On a fresh database, mark existing history as seen instead of copying it.
    cold_start_lookback_seconds: int = 0
    #: How many recent trades to pull per leader per poll.
    fetch_limit: int = 50
    db_path: str = "polycopy.db"
    clob_host: str = DEFAULT_CLOB_HOST
    data_api: str = DEFAULT_DATA_API
    gamma_api: str = DEFAULT_GAMMA_API
    chain_id: int = POLYGON_CHAIN_ID
    #: Live trading is opt-in at every layer; this is the config-file layer.
    live: bool = False
    secrets: Secrets = field(default_factory=Secrets)

    def __post_init__(self) -> None:
        enabled = [ldr for ldr in self.leaders if ldr.enabled]
        if not enabled:
            raise ConfigError("no enabled leaders configured - nothing to copy")
        seen: set[str] = set()
        for ldr in enabled:
            if ldr.address in seen:
                raise ConfigError(f"leader {ldr.address} listed twice")
            seen.add(ldr.address)
        if self.poll_interval_seconds < 1:
            raise ConfigError("poll_interval_seconds must be >= 1")

    @property
    def enabled_leaders(self) -> list[Leader]:
        return [ldr for ldr in self.leaders if ldr.enabled]


def _build(cls: type, payload: dict[str, Any], section: str) -> Any:
    """Instantiate a config dataclass, rejecting unknown keys loudly.

    A silently ignored ``max_order_usd`` typo in a risk config is a real money
    bug, so unknown keys are an error rather than a warning.
    """
    if not isinstance(payload, dict):
        raise ConfigError(f"config section {section!r} must be a mapping")
    known = {f.name for f in fields(cls)}
    unknown = set(payload) - known
    if unknown:
        raise ConfigError(
            f"unknown key(s) in {section!r}: {', '.join(sorted(unknown))}. "
            f"Valid keys: {', '.join(sorted(known))}"
        )
    return cls(**payload)


def load_config(path: str | Path, env: dict[str, str] | None = None) -> BotConfig:
    """Read a YAML strategy file and merge in credentials from the environment."""
    path = Path(path)
    if not path.exists():
        raise ConfigError(f"config file not found: {path}")
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ConfigError("config file must contain a YAML mapping at the top level")

    raw_leaders = raw.pop("leaders", [])
    if not isinstance(raw_leaders, list) or not raw_leaders:
        raise ConfigError("config must define a non-empty 'leaders' list")
    leaders = [
        _build(Leader, ldr if isinstance(ldr, dict) else {"address": ldr}, "leaders[]")
        for ldr in raw_leaders
    ]

    sizing = _build(SizingConfig, raw.pop("sizing", {}) or {}, "sizing")
    risk = _build(RiskConfig, raw.pop("risk", {}) or {}, "risk")
    execution = _build(ExecutionConfig, raw.pop("execution", {}) or {}, "execution")

    top_level_known = {
        f.name for f in fields(BotConfig)
    } - {"leaders", "sizing", "risk", "execution", "secrets"}
    unknown = set(raw) - top_level_known
    if unknown:
        raise ConfigError(
            f"unknown top-level key(s): {', '.join(sorted(unknown))}. "
            f"Valid keys: {', '.join(sorted(top_level_known))}"
        )

    return BotConfig(
        leaders=leaders,
        sizing=sizing,
        risk=risk,
        execution=execution,
        secrets=Secrets.from_env(env),
        **raw,
    )
