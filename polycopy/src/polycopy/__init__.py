"""polycopy - a copy-trading bot for Polymarket.

Watches one or more wallets on the Polymarket data API and mirrors their fills
onto your own CLOB account, subject to a configurable risk and sizing policy.
Dry run is the default at every layer.
"""

from .config import (
    BotConfig,
    ConfigError,
    ExecutionConfig,
    Leader,
    RiskConfig,
    SizingConfig,
    load_config,
)
from .datasource import DataSource
from .engine import CopyEngine, PollSummary
from .execution import ClobExecutor, DryRunExecutor, build_executor
from .models import Decision, MarketMeta, OrderResult, SourceTrade
from .store import Store

__version__ = "0.1.0"

__all__ = [
    "BotConfig",
    "ClobExecutor",
    "ConfigError",
    "CopyEngine",
    "DataSource",
    "Decision",
    "DryRunExecutor",
    "ExecutionConfig",
    "Leader",
    "MarketMeta",
    "OrderResult",
    "PollSummary",
    "RiskConfig",
    "SizingConfig",
    "SourceTrade",
    "Store",
    "build_executor",
    "load_config",
]
