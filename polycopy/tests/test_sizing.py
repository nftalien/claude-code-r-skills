from __future__ import annotations

import pytest

from polycopy.config import Leader, SizingConfig
from polycopy.models import MarketMeta
from polycopy.sizing import (
    MIN_NOTIONAL_USDC,
    build_decision,
    limit_price_for,
    round_shares,
    round_to_tick,
    size_entry,
    size_exit,
)

from .conftest import ASSET_ID, CONDITION_ID, make_trade

CAPS = {"slippage_bps": 100.0, "whole_shares": 1.0}


# ------------------------------------------------------------------ rounding

@pytest.mark.parametrize(
    ("price", "tick", "direction", "expected"),
    [
        (0.4321, 0.01, "up", 0.44),
        (0.4321, 0.01, "down", 0.43),
        (0.4321, 0.001, "up", 0.433),
        (0.4321, 0.001, "down", 0.432),
        (0.40, 0.01, "up", 0.40),      # already on the grid: do not move it
        (0.40, 0.01, "down", 0.40),
    ],
)
def test_round_to_tick(price, tick, direction, expected):
    assert round_to_tick(price, tick, direction) == pytest.approx(expected)


def test_round_to_tick_resists_binary_float_noise():
    """0.63 / 0.01 is 62.99999999999999, and naive flooring drops a full tick."""
    assert round_to_tick(0.63, 0.01, "down") == pytest.approx(0.63)
    assert round_to_tick(0.29, 0.01, "up") == pytest.approx(0.29)


def test_round_shares_always_rounds_down():
    assert round_shares(10.99, whole=True) == 10.0
    assert round_shares(10.999, whole=False) == 10.99


# ------------------------------------------------------------- limit pricing

def test_buy_limit_pays_up_and_sell_limit_concedes(market):
    buy = limit_price_for(make_trade(side="BUY", price=0.40), market, slippage_bps=100)
    sell = limit_price_for(make_trade(side="SELL", price=0.40), market, slippage_bps=100)
    assert buy >= 0.40 and sell <= 0.40
    # 100 bps on 0.40 is 0.404, which snaps up to the next 0.01 tick.
    assert buy == pytest.approx(0.41)
    assert sell == pytest.approx(0.39)


def test_limit_price_stays_inside_the_tradeable_range(market):
    high = limit_price_for(make_trade(side="BUY", price=0.99), market, slippage_bps=5000)
    low = limit_price_for(make_trade(side="SELL", price=0.01), market, slippage_bps=5000)
    assert 0 < high <= 1 - market.tick_size
    assert low >= market.tick_size


# -------------------------------------------------------------------- entries

def test_fixed_sizing_spends_the_configured_amount(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=20.0, max_order_usdc=50.0)
    decision = size_entry(make_trade(price=0.40), leader, market, cfg, store, CAPS)
    assert decision.copying
    assert decision.limit_price == pytest.approx(0.41)
    assert decision.shares == 48.0  # floor(20 / 0.41)
    assert decision.notional <= 20.0


def test_proportional_sizing_tracks_leader_notional(leader, market, store):
    cfg = SizingConfig(mode="proportional", proportional_factor=0.02, max_order_usdc=1000)
    trade = make_trade(price=0.50, size=2000)  # $1000 notional
    decision = size_entry(trade, leader, market, cfg, store, CAPS)
    assert decision.copying
    assert decision.notional == pytest.approx(20.0, abs=0.6)  # 2% of $1000


def test_bankroll_fraction_sizing(leader, market, store):
    cfg = SizingConfig(
        mode="bankroll_fraction", bankroll_usdc=2000, bankroll_fraction=0.01, max_order_usdc=1000
    )
    decision = size_entry(make_trade(price=0.50), leader, market, cfg, store, CAPS)
    assert decision.notional == pytest.approx(20.0, abs=0.6)


def test_leader_weight_scales_the_order(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=20.0, max_order_usdc=100)
    half = Leader(address=leader.address, weight=0.5)
    full_size = size_entry(make_trade(), leader, market, cfg, store, CAPS).notional
    half_size = size_entry(make_trade(), half, market, cfg, store, CAPS).notional
    assert half_size == pytest.approx(full_size / 2, abs=0.5)


def test_max_order_usdc_clamps_the_order(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=500.0, max_order_usdc=25.0)
    assert size_entry(make_trade(), leader, market, cfg, store, CAPS).notional <= 25.0


def test_per_leader_ceiling_overrides_the_global_one(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=100.0, max_order_usdc=100.0)
    capped = Leader(address=leader.address, max_order_usdc=10.0)
    assert size_entry(make_trade(), capped, market, cfg, store, CAPS).notional <= 10.0


def test_budget_headroom_shrinks_rather_than_rejects(leader, market, store):
    """A nearly-full daily cap should still trade, just smaller."""
    cfg = SizingConfig(mode="fixed", fixed_usdc=50.0, max_order_usdc=100.0, min_order_usdc=1.0)
    caps = dict(CAPS, daily_headroom=6.0)
    decision = size_entry(make_trade(price=0.40), leader, market, cfg, store, caps)
    assert decision.copying
    assert decision.notional <= 6.0


def test_entry_rejected_when_headroom_falls_below_the_minimum(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=50.0, min_order_usdc=5.0, max_order_usdc=100)
    caps = dict(CAPS, total_headroom=0.5)
    decision = size_entry(make_trade(), leader, market, cfg, store, caps)
    assert not decision.copying
    assert "below minimum" in decision.reason


def test_entry_rejected_below_market_minimum_share_count(leader, market, store):
    """$2 at 0.90 buys 2 shares, under the 5-share market floor."""
    cfg = SizingConfig(mode="fixed", fixed_usdc=2.0, min_order_usdc=1.0, max_order_usdc=10)
    decision = size_entry(make_trade(price=0.90), leader, market, cfg, store, CAPS)
    assert not decision.copying
    assert "below market minimum" in decision.reason


def test_entry_never_falls_under_the_dollar_floor(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=0.5, min_order_usdc=0.1, max_order_usdc=10)
    decision = size_entry(make_trade(), leader, market, cfg, store, CAPS)
    assert not decision.copying
    assert str(MIN_NOTIONAL_USDC) in decision.reason or "minimum" in decision.reason


# --------------------------------------------------------------------- exits

def _hold(store, shares=100.0, price=0.40):
    store.apply_fill(ASSET_ID, CONDITION_ID, "BUY", shares, price, "Will the example resolve YES?")


def test_exit_is_sized_from_our_position_not_the_leaders(market, store):
    """The leader may hold 10,000 shares where we hold 100; only the fraction
    they exited transfers."""
    _hold(store, shares=100)
    cfg = SizingConfig(exit_policy="proportional")
    trade = make_trade(side="SELL", price=0.50, size=5000)  # leader sells half of 10,000
    decision = size_exit(trade, market, cfg, store, leader_position_after=5000, budget_caps=CAPS)
    assert decision.copying
    assert decision.shares == pytest.approx(50.0)  # half of *our* 100


def test_exit_defaults_to_flat_when_leader_position_is_unknown(market, store):
    _hold(store, shares=100)
    cfg = SizingConfig(exit_policy="proportional")
    decision = size_exit(
        make_trade(side="SELL", size=10), market, cfg, store, leader_position_after=None,
        budget_caps=CAPS,
    )
    assert decision.copying
    assert decision.shares == pytest.approx(100.0)
    assert "unavailable" in decision.reason


def test_full_exit_policy_ignores_the_leaders_fraction(market, store):
    _hold(store, shares=100)
    cfg = SizingConfig(exit_policy="full")
    decision = size_exit(
        make_trade(side="SELL", size=1), market, cfg, store, leader_position_after=9999,
        budget_caps=CAPS,
    )
    assert decision.shares == pytest.approx(100.0)


def test_exit_policy_off_ignores_sells(market, store):
    _hold(store)
    cfg = SizingConfig(exit_policy="off")
    decision = size_exit(make_trade(side="SELL"), market, cfg, store, 50, CAPS)
    assert not decision.copying
    assert "exit_policy=off" in decision.reason


def test_exit_skipped_when_we_hold_nothing(market, store):
    cfg = SizingConfig(exit_policy="proportional")
    decision = size_exit(make_trade(side="SELL"), market, cfg, store, 50, CAPS)
    assert not decision.copying
    assert "no position" in decision.reason


def test_trim_that_would_strand_dust_is_promoted_to_a_full_exit(market, store):
    """A 3-share remainder can never be sold: it is under the market minimum."""
    _hold(store, shares=100)
    cfg = SizingConfig(exit_policy="proportional")
    trade = make_trade(side="SELL", size=97)
    decision = size_exit(trade, market, cfg, store, leader_position_after=3, budget_caps=CAPS)
    assert decision.shares == pytest.approx(100.0)
    assert "full exit" in decision.reason


def test_tiny_trim_is_skipped_rather_than_sold_below_the_minimum(market, store):
    """0.2% of 1000 shares is 2 shares, under the 5-share market floor, and the
    998-share remainder is far too large to justify promoting to a full exit."""
    _hold(store, shares=1000)
    cfg = SizingConfig(exit_policy="proportional")
    trade = make_trade(side="SELL", size=1)
    decision = size_exit(trade, market, cfg, store, leader_position_after=499, budget_caps=CAPS)
    assert not decision.copying
    assert "below market minimum" in decision.reason


def test_trim_rounding_to_zero_shares_is_skipped(market, store):
    _hold(store, shares=1000)
    cfg = SizingConfig(exit_policy="proportional")
    trade = make_trade(side="SELL", size=1)
    decision = size_exit(trade, market, cfg, store, leader_position_after=9999, budget_caps=CAPS)
    assert not decision.copying
    assert "rounds to zero" in decision.reason


def test_exit_survives_a_leader_selling_more_than_they_held(market, store):
    _hold(store, shares=100)
    cfg = SizingConfig(exit_policy="proportional")
    decision = size_exit(
        make_trade(side="SELL", size=500), market, cfg, store, leader_position_after=0,
        budget_caps=CAPS,
    )
    assert decision.shares == pytest.approx(100.0)  # capped at what we hold


# -------------------------------------------------------------------- router

def test_build_decision_routes_by_side(leader, market, store):
    cfg = SizingConfig(mode="fixed", fixed_usdc=20.0, max_order_usdc=50)
    assert build_decision(make_trade("BUY"), leader, market, cfg, store, CAPS).copying
    _hold(store)
    assert build_decision(
        make_trade("SELL"), leader, market, cfg, store, CAPS, leader_position_after=0
    ).copying


def test_build_decision_rejects_an_unknown_side(leader, market, store):
    trade = make_trade("BUY")
    weird = type(trade)(**{**trade.__dict__, "side": "MINT"})
    decision = build_decision(weird, leader, market, SizingConfig(), store, CAPS)
    assert not decision.copying
    assert "unknown side" in decision.reason


def test_thousandth_tick_market_prices_correctly(leader, store):
    fine = MarketMeta(condition_id=CONDITION_ID, tick_size=0.001, min_order_size=5)
    cfg = SizingConfig(mode="fixed", fixed_usdc=20.0, max_order_usdc=50)
    decision = size_entry(make_trade(price=0.427), leader, fine, cfg, store, CAPS)
    assert decision.copying
    assert decision.limit_price == pytest.approx(0.432)  # 0.427 * 1.01 = 0.43127, up a tick
