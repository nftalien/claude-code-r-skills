from __future__ import annotations

import json
import time

from polycopy.models import MarketMeta, SourceTrade

from .conftest import LEADER_ADDRESS, make_trade


def test_from_api_parses_a_realistic_payload():
    payload = {
        "proxyWallet": LEADER_ADDRESS,
        "side": "buy",
        "asset": "7132104567925221259462638553270691275033272857194253228963137931245558399256",
        "conditionId": "0xabc",
        "size": "1500.5",
        "price": "0.42",
        "timestamp": 1735689600,
        "title": "Will X happen?",
        "outcome": "Yes",
        "slug": "will-x-happen",
        "transactionHash": "0xFEED",
    }
    trade = SourceTrade.from_api(payload, leader=LEADER_ADDRESS.upper())
    assert trade.side == "BUY"  # normalised
    assert trade.leader == LEADER_ADDRESS.lower()
    assert trade.size == 1500.5
    assert trade.price == 0.42
    assert round(trade.notional, 2) == 630.21
    assert trade.is_valid()


def test_from_api_tolerates_missing_and_junk_fields():
    """A bot that crashes on an unexpected payload silently stops copying."""
    payload = {"side": "BUY", "price": None, "size": "abc"}
    trade = SourceTrade.from_api(payload, leader=LEADER_ADDRESS)
    assert trade.price == 0.0
    assert trade.size == 0.0
    assert not trade.is_valid()


def test_from_api_accepts_camelcase_aliases():
    trade = SourceTrade.from_api(
        {"assetId": "42", "condition_id": "0xabc", "side": "SELL", "price": 0.3,
         "size": 10, "timestamp": 1, "txHash": "0x1"},
        leader=LEADER_ADDRESS,
    )
    assert trade.asset_id == "42"
    assert trade.condition_id == "0xabc"
    assert trade.tx_hash == "0x1"


def test_invalid_when_price_out_of_range():
    assert not make_trade(price=0.0).is_valid()
    assert not make_trade(price=1.0).is_valid()
    assert make_trade(price=0.999).is_valid()


def test_key_is_stable_and_distinguishes_fills_in_one_transaction():
    """One Polygon transaction can settle several fills, so the hash alone
    cannot be the idempotency key."""
    a = make_trade(size=100, tx_hash="0xsame")
    b = make_trade(size=200, tx_hash="0xsame")
    assert a.key != b.key
    assert a.key == make_trade(size=100, tx_hash="0xsame").key
    assert len(a.key) == 32


def test_key_distinguishes_leaders():
    other = "0x2222222222222222222222222222222222222222"
    assert make_trade().key != make_trade(leader=other).key


def test_market_meta_from_gamma_parses_json_encoded_fields():
    meta = MarketMeta.from_gamma(
        {
            "conditionId": "0xabc",
            "question": "Will Y happen?",
            "slug": "will-y",
            "closed": False,
            "active": True,
            "acceptingOrders": True,
            "endDate": "2026-12-31T23:59:59Z",
            "negRisk": True,
            "orderPriceMinTickSize": "0.001",
            "orderMinSize": "5",
            "clobTokenIds": json.dumps(["111", "222"]),
        }
    )
    assert meta.tick_size == 0.001
    assert meta.min_order_size == 5.0
    assert meta.token_ids == ("111", "222")
    assert meta.neg_risk is True
    assert meta.end_date_ts is not None and meta.end_date_ts > time.time()


def test_market_meta_survives_a_malformed_end_date():
    meta = MarketMeta.from_gamma({"conditionId": "0xabc", "endDate": "not-a-date"})
    assert meta.end_date_ts is None
    assert meta.tick_size == 0.01  # falls back to the usual grid


def test_market_meta_falls_back_when_tick_size_is_zero_or_missing():
    assert MarketMeta.from_gamma({"orderPriceMinTickSize": 0}).tick_size == 0.01
    assert MarketMeta.from_gamma({}).min_order_size == 5.0


def test_millisecond_timestamps_are_normalised_to_seconds():
    """If the API ever switched units, every fill would otherwise look
    impossibly fresh and sail straight past the staleness check."""
    payload = {
        "asset": "1", "conditionId": "0xabc", "side": "BUY",
        "price": 0.4, "size": 10, "timestamp": 1735689600000,
    }
    assert SourceTrade.from_api(payload, leader=LEADER_ADDRESS).timestamp == 1735689600
