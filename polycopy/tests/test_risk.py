from __future__ import annotations

import dataclasses
import time

from polycopy.config import RiskConfig
from polycopy.risk import check_trade

from .conftest import ASSET_ID, CONDITION_ID, make_trade


def test_a_clean_trade_passes(market, store):
    verdict = check_trade(make_trade(price=0.40, size=1000), market, RiskConfig(), store)
    assert verdict.ok
    assert verdict.headroom is not None
    assert verdict.headroom["daily_headroom"] > 0


def test_missing_market_metadata_is_a_veto(store):
    verdict = check_trade(make_trade(), None, RiskConfig(), store)
    assert not verdict.ok
    assert "metadata unavailable" in verdict.reason


def test_malformed_trade_is_a_veto(market, store):
    verdict = check_trade(make_trade(price=0.0), market, RiskConfig(), store)
    assert not verdict.ok
    assert "malformed" in verdict.reason


def test_stale_trade_is_a_veto(market, store):
    verdict = check_trade(
        make_trade(age_seconds=900), market, RiskConfig(max_trade_age_seconds=300), store
    )
    assert not verdict.ok
    assert "stale" in verdict.reason


def test_price_band_vetoes_longshots_and_near_certainties(market, store):
    cfg = RiskConfig(min_price=0.10, max_price=0.90)
    assert not check_trade(make_trade(price=0.02, size=99999), market, cfg, store).ok
    assert not check_trade(make_trade(price=0.97, size=99999), market, cfg, store).ok
    assert check_trade(make_trade(price=0.50), market, cfg, store).ok


def test_small_leader_trades_are_ignored(market, store):
    cfg = RiskConfig(min_leader_notional_usdc=100.0)
    small = make_trade(price=0.5, size=10)  # $5
    assert not check_trade(small, market, cfg, store).ok
    assert "below" in check_trade(small, market, cfg, store).reason


def test_market_about_to_resolve_is_a_veto(market, store):
    soon = dataclasses.replace(market, end_date_ts=int(time.time()) + 60)
    verdict = check_trade(make_trade(), soon, RiskConfig(min_seconds_to_close=3600), store)
    assert not verdict.ok
    assert "resolves in" in verdict.reason


def test_open_ended_market_is_not_vetoed_on_close_time(market, store):
    endless = dataclasses.replace(market, end_date_ts=None)
    assert check_trade(make_trade(), endless, RiskConfig(), store).ok


def test_closed_inactive_and_halted_markets_are_vetoed(market, store):
    cfg = RiskConfig()
    for field in ("closed", "active", "accepting_orders"):
        broken = dataclasses.replace(market, **{field: field == "closed"})
        assert not check_trade(make_trade(), broken, cfg, store).ok


def test_block_and_allow_lists(market, store):
    blocked = RiskConfig(block_condition_ids=[CONDITION_ID.upper()])
    assert not check_trade(make_trade(), market, blocked, store).ok

    allowed_elsewhere = RiskConfig(allow_condition_ids=["0xsomethingelse"])
    assert not check_trade(make_trade(), market, allowed_elsewhere, store).ok

    allowed_here = RiskConfig(allow_condition_ids=[CONDITION_ID])
    assert check_trade(make_trade(), market, allowed_here, store).ok


def test_keyword_blocklist_matches_case_insensitively(market, store):
    cfg = RiskConfig(block_keywords=["EXAMPLE"])
    verdict = check_trade(make_trade(), market, cfg, store)
    assert not verdict.ok
    assert "keyword" in verdict.reason


def test_market_exposure_cap(market, store):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 100, 0.50)  # $50 at cost
    cfg = RiskConfig(max_market_exposure_usdc=50.0)
    verdict = check_trade(make_trade(), market, cfg, store)
    assert not verdict.ok
    assert "market exposure" in verdict.reason


def test_total_exposure_cap(market, store):
    store.apply_fill("other-asset", "0xother", "BUY", 100, 1.0)  # $100
    cfg = RiskConfig(max_total_exposure_usdc=100.0, max_market_exposure_usdc=1000.0)
    verdict = check_trade(make_trade(), market, cfg, store)
    assert not verdict.ok
    assert "total exposure" in verdict.reason


def test_daily_spend_cap(market, store):
    store.add_daily_spend(200.0)
    cfg = RiskConfig(daily_spend_cap_usdc=200.0)
    verdict = check_trade(make_trade(), market, cfg, store)
    assert not verdict.ok
    assert "daily spend" in verdict.reason


def test_headroom_reflects_partial_consumption(market, store):
    store.add_daily_spend(150.0)
    cfg = RiskConfig(daily_spend_cap_usdc=200.0)
    verdict = check_trade(make_trade(), market, cfg, store)
    assert verdict.ok
    assert verdict.headroom["daily_headroom"] == 50.0


def test_max_open_markets_blocks_new_markets_only(market, store):
    for i in range(3):
        store.apply_fill(f"asset-{i}", f"0xmarket-{i}", "BUY", 10, 0.5)
    cfg = RiskConfig(max_open_markets=3, max_market_exposure_usdc=1000, max_total_exposure_usdc=1e6)

    verdict = check_trade(make_trade(), market, cfg, store)
    assert not verdict.ok
    assert "max_open_markets" in verdict.reason

    # Adding to a market we already hold does not open a new one.
    held = make_trade(asset_id="asset-1", condition_id="0xmarket-1")
    held_market = dataclasses.replace(market, condition_id="0xmarket-1")
    assert check_trade(held, held_market, cfg, store).ok


def test_exits_bypass_price_band_notional_and_budget_caps(market, store):
    """If the leader is getting out, a full budget is no reason to keep holding."""
    store.add_daily_spend(10_000)
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", 1000, 0.99)
    cfg = RiskConfig(
        min_price=0.4,
        max_price=0.6,
        min_leader_notional_usdc=1e9,
        daily_spend_cap_usdc=1.0,
        max_total_exposure_usdc=1.0,
        max_market_exposure_usdc=1.0,
    )
    verdict = check_trade(make_trade(side="SELL", price=0.02, size=1), market, cfg, store)
    assert verdict.ok


def test_exits_are_still_blocked_on_a_closed_market(market, store):
    closed = dataclasses.replace(market, closed=True)
    assert not check_trade(make_trade(side="SELL"), closed, RiskConfig(), store).ok


def test_holding_the_other_outcome_does_not_count_as_a_new_market(market, store):
    """Buying NO after holding YES opens no new market, so the concurrency cap
    must not block it."""
    store.apply_fill("yes-token", CONDITION_ID, "BUY", 10, 0.5)
    for i in range(2):
        store.apply_fill(f"asset-{i}", f"0xmarket-{i}", "BUY", 10, 0.5)
    cfg = RiskConfig(max_open_markets=3, max_market_exposure_usdc=1000, max_total_exposure_usdc=1e6)

    no_token = make_trade(asset_id="no-token")
    assert check_trade(no_token, market, cfg, store).ok
