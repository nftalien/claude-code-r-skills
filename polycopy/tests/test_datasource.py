"""DataSource tests. All HTTP is mocked; nothing here touches the network."""

from __future__ import annotations

import httpx
import pytest
import respx

from polycopy.datasource import DataSource, parse_token_ids

DATA_API = "https://data-api.example"
GAMMA_API = "https://gamma-api.example"
ADDRESS = "0x1111111111111111111111111111111111111111"

TRADE_PAYLOAD = {
    "proxyWallet": ADDRESS,
    "side": "BUY",
    "asset": "12345",
    "conditionId": "0xabc",
    "size": "500",
    "price": "0.42",
    "timestamp": 1735689600,
    "title": "Will X happen?",
    "outcome": "Yes",
    "slug": "will-x",
    "transactionHash": "0xfeed",
}

MARKET_PAYLOAD = {
    "conditionId": "0xabc",
    "question": "Will X happen?",
    "slug": "will-x",
    "closed": False,
    "active": True,
    "acceptingOrders": True,
    "endDate": "2027-01-01T00:00:00Z",
    "negRisk": False,
    "orderPriceMinTickSize": "0.01",
    "orderMinSize": "5",
    "clobTokenIds": '["12345", "67890"]',
}


@pytest.fixture
def source():
    with DataSource(DATA_API, GAMMA_API) as s:
        yield s


@respx.mock
def test_fetch_trades_parses_and_filters(source):
    respx.get(f"{DATA_API}/trades").mock(
        return_value=httpx.Response(200, json=[TRADE_PAYLOAD, {"side": "BUY"}])
    )
    trades = source.fetch_trades(ADDRESS)
    assert len(trades) == 1  # the unparseable second entry is dropped
    assert trades[0].price == 0.42
    assert trades[0].size == 500


@respx.mock
def test_fetch_trades_passes_the_user_and_limit(source):
    route = respx.get(f"{DATA_API}/trades").mock(return_value=httpx.Response(200, json=[]))
    source.fetch_trades(ADDRESS, limit=7)
    assert route.calls.last.request.url.params["user"] == ADDRESS
    assert route.calls.last.request.url.params["limit"] == "7"


@respx.mock
def test_fetch_trades_tolerates_an_unexpected_payload_shape(source):
    respx.get(f"{DATA_API}/trades").mock(
        return_value=httpx.Response(200, json={"error": "rate limited"})
    )
    assert source.fetch_trades(ADDRESS) == []


@respx.mock
def test_fetch_trades_raises_on_http_error_so_the_engine_can_count_it(source):
    respx.get(f"{DATA_API}/trades").mock(return_value=httpx.Response(500))
    with pytest.raises(httpx.HTTPError):
        source.fetch_trades(ADDRESS)


@respx.mock
def test_fetch_market_parses_metadata(source):
    respx.get(f"{GAMMA_API}/markets").mock(
        return_value=httpx.Response(200, json=[MARKET_PAYLOAD])
    )
    meta = source.fetch_market("0xabc")
    assert meta.tick_size == 0.01
    assert meta.token_ids == ("12345", "67890")
    assert meta.accepting_orders


@respx.mock
def test_fetch_market_accepts_a_wrapped_payload(source):
    respx.get(f"{GAMMA_API}/markets").mock(
        return_value=httpx.Response(200, json={"data": [MARKET_PAYLOAD]})
    )
    assert source.fetch_market("0xabc").question == "Will X happen?"


@respx.mock
def test_fetch_market_caches_by_condition_id(source):
    route = respx.get(f"{GAMMA_API}/markets").mock(
        return_value=httpx.Response(200, json=[MARKET_PAYLOAD])
    )
    source.fetch_market("0xabc")
    source.fetch_market("0xABC")  # case-insensitive cache hit
    assert route.call_count == 1

    source.invalidate_market("0xabc")
    source.fetch_market("0xabc")
    assert route.call_count == 2


@respx.mock
def test_fetch_market_returns_none_rather_than_raising(source):
    respx.get(f"{GAMMA_API}/markets").mock(return_value=httpx.Response(503))
    assert source.fetch_market("0xabc") is None


@respx.mock
def test_fetch_market_returns_none_on_empty_result(source):
    respx.get(f"{GAMMA_API}/markets").mock(return_value=httpx.Response(200, json=[]))
    assert source.fetch_market("0xabc") is None


@respx.mock
def test_leader_position_size_distinguishes_zero_from_unknown(source):
    route = respx.get(f"{DATA_API}/positions")

    route.mock(return_value=httpx.Response(200, json=[
        {"asset": "12345", "conditionId": "0xabc", "size": "800", "avgPrice": "0.4"}
    ]))
    assert source.leader_position_size(ADDRESS, "12345") == 800.0

    # Held other things, but not this one: a genuine zero.
    assert source.leader_position_size(ADDRESS, "99999") == 0.0

    # Endpoint down: unknown, which the caller must treat differently.
    route.mock(return_value=httpx.Response(500))
    assert source.leader_position_size(ADDRESS, "12345") is None


def test_parse_token_ids_handles_every_shape():
    assert parse_token_ids('["1","2"]') == ("1", "2")
    assert parse_token_ids([1, 2]) == ("1", "2")
    assert parse_token_ids("not json") == ()
    assert parse_token_ids(None) == ()
