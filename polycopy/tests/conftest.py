"""Shared fixtures. Everything here is offline: no test touches the network."""

from __future__ import annotations

import time

import pytest

from polycopy.config import (
    BotConfig,
    ExecutionConfig,
    Leader,
    RiskConfig,
    Secrets,
    SizingConfig,
)
from polycopy.models import MarketMeta, SourceTrade
from polycopy.store import Store

LEADER_ADDRESS = "0x1111111111111111111111111111111111111111"
CONDITION_ID = "0xcafe00000000000000000000000000000000000000000000000000000000beef"
ASSET_ID = "71321045679252212594626385532706912750332728571942532289631379312455583992563"


@pytest.fixture
def now() -> float:
    return time.time()


@pytest.fixture
def leader() -> Leader:
    return Leader(address=LEADER_ADDRESS, label="whale")


@pytest.fixture
def store() -> Store:
    s = Store(":memory:")
    yield s
    s.close()


@pytest.fixture
def market() -> MarketMeta:
    return MarketMeta(
        condition_id=CONDITION_ID,
        question="Will the example resolve YES?",
        slug="example",
        closed=False,
        active=True,
        accepting_orders=True,
        end_date_ts=int(time.time()) + 86_400 * 30,
        neg_risk=False,
        tick_size=0.01,
        min_order_size=5.0,
        token_ids=(ASSET_ID, "999"),
    )


def make_trade(
    side: str = "BUY",
    price: float = 0.40,
    size: float = 1000.0,
    age_seconds: float = 30.0,
    asset_id: str = ASSET_ID,
    condition_id: str = CONDITION_ID,
    tx_hash: str = "0xdeadbeef",
    leader: str = LEADER_ADDRESS,
) -> SourceTrade:
    return SourceTrade(
        leader=leader.lower(),
        asset_id=asset_id,
        condition_id=condition_id,
        side=side,
        price=price,
        size=size,
        timestamp=int(time.time() - age_seconds),
        title="Will the example resolve YES?",
        outcome="Yes",
        slug="example",
        tx_hash=tx_hash,
    )


@pytest.fixture
def trade() -> SourceTrade:
    return make_trade()


@pytest.fixture
def config(leader: Leader) -> BotConfig:
    return BotConfig(
        leaders=[leader],
        sizing=SizingConfig(
            mode="fixed", fixed_usdc=10.0, min_order_usdc=1.0, max_order_usdc=50.0
        ),
        risk=RiskConfig(min_leader_notional_usdc=50.0),
        execution=ExecutionConfig(order_type="FAK", slippage_bps=100),
        poll_interval_seconds=1,
        db_path=":memory:",
        live=False,
        secrets=Secrets(),
    )
