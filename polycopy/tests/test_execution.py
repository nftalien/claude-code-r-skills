"""Executor tests. The CLOB client is stubbed; no key is ever signed with."""

from __future__ import annotations

import pytest

from polycopy.config import BotConfig, ExecutionConfig, RiskConfig, Secrets, SizingConfig
from polycopy.execution import ClobExecutor, DryRunExecutor, build_executor
from polycopy.models import Decision, MarketMeta

from .conftest import CONDITION_ID, make_trade

MARKET = MarketMeta(condition_id=CONDITION_ID, tick_size=0.01, min_order_size=5)


def a_decision(shares=50.0, price=0.41, side="BUY"):
    return Decision(
        trade=make_trade(side=side),
        action="copy",
        shares=shares,
        limit_price=price,
        notional=shares * price,
    )


# ------------------------------------------------------------------- dry run

def test_dry_run_fills_completely_at_the_limit_price():
    result = DryRunExecutor().place(a_decision(shares=50), MARKET)
    assert result.success and result.dry_run
    assert result.filled_shares == 50
    assert result.status == "matched"


def test_dry_run_order_ids_are_unique():
    executor = DryRunExecutor()
    ids = {executor.place(a_decision(), MARKET).order_id for _ in range(3)}
    assert len(ids) == 3


def test_dry_run_reports_no_bankroll():
    assert DryRunExecutor().bankroll_usdc() is None
    assert "dry-run" in DryRunExecutor().describe()


# ------------------------------------------------------------- executor choice

def _config(live: bool, key: str = "") -> BotConfig:
    return BotConfig(
        leaders=[__import__("polycopy").Leader(address="0x" + "1" * 40)],
        sizing=SizingConfig(),
        risk=RiskConfig(),
        execution=ExecutionConfig(),
        db_path=":memory:",
        live=live,
        secrets=Secrets(private_key=key),
    )


def test_build_executor_defaults_to_paper():
    assert isinstance(build_executor(_config(live=False)), DryRunExecutor)


def test_force_dry_run_overrides_a_live_config():
    """Two independent switches, because getting this wrong spends real money."""
    executor = build_executor(_config(live=True, key="0xabc"), force_dry_run=True)
    assert isinstance(executor, DryRunExecutor)


def test_live_config_without_a_key_is_refused():
    with pytest.raises(RuntimeError, match="POLYMARKET_PRIVATE_KEY"):
        build_executor(_config(live=True))


# ------------------------------------------------- live response interpretation

def _bare_executor(order_type="FAK", fill_delay=0.0) -> ClobExecutor:
    """A ClobExecutor with its constructor bypassed, so the pure response-parsing
    logic can be tested without a signer or a network."""
    executor = object.__new__(ClobExecutor)
    executor._order_type = order_type
    executor._fill_delay = fill_delay
    executor._client = None
    return executor


def test_rejection_is_reported_with_the_error_message():
    result = _bare_executor()._interpret(
        {"success": False, "errorMsg": "not enough balance", "status": "rejected"}, a_decision()
    )
    assert not result.success
    assert result.error == "not enough balance"


def test_a_non_dict_response_is_a_failure_not_a_crash():
    result = _bare_executor()._interpret("gateway timeout", a_decision())
    assert not result.success
    assert "unexpected response" in result.error


def test_a_resting_gtc_order_reports_no_fill():
    result = _bare_executor("GTC")._interpret(
        {"success": True, "orderID": "abc", "status": "live"}, a_decision(shares=50)
    )
    assert result.success
    assert result.filled_shares == 0.0


def test_a_matched_order_without_an_id_assumes_a_full_fill():
    result = _bare_executor()._interpret(
        {"success": True, "status": "matched"}, a_decision(shares=50)
    )
    assert result.filled_shares == 50


def test_size_matched_is_preferred_over_the_optimistic_assumption():
    executor = _bare_executor()

    class Client:
        host = "https://clob.example"

        def get_order(self, order_id):
            return {"id": order_id, "size_matched": "12.5"}

    executor._client = Client()
    result = executor._interpret(
        {"success": True, "orderID": "abc", "status": "matched"}, a_decision(shares=50)
    )
    assert result.filled_shares == 12.5


def test_camelcase_size_matched_is_also_read():
    executor = _bare_executor()
    executor._client = type("C", (), {"get_order": lambda self, oid: {"sizeMatched": 7}})()
    result = executor._interpret(
        {"success": True, "orderID": "abc", "status": "matched"}, a_decision(shares=50)
    )
    assert result.filled_shares == 7


def test_an_unreadable_order_falls_back_to_the_reported_status():
    executor = _bare_executor()

    def boom(self, order_id):
        raise RuntimeError("504")

    executor._client = type("C", (), {"get_order": boom})()
    result = executor._interpret(
        {"success": True, "orderID": "abc", "status": "matched"}, a_decision(shares=50)
    )
    assert result.filled_shares == 50


def test_a_garbled_size_matched_falls_back_rather_than_raising():
    executor = _bare_executor()
    executor._client = type("C", (), {"get_order": lambda self, oid: {"size_matched": "n/a"}})()
    result = executor._interpret(
        {"success": True, "orderID": "abc", "status": "matched"}, a_decision(shares=50)
    )
    assert result.filled_shares == 50


def test_order_id_aliases_are_accepted():
    result = _bare_executor()._interpret(
        {"success": True, "orderId": "xyz", "status": "live"}, a_decision()
    )
    assert result.order_id == "xyz"


# ------------------------------------------------------------------- balances

def test_bankroll_converts_from_usdc_six_decimals():
    executor = _bare_executor()
    executor._client = type(
        "C", (), {"get_balance_allowance": lambda self, params: {"balance": "1250000"}}
    )()
    assert executor.bankroll_usdc() == pytest.approx(1.25)


def test_bankroll_returns_none_when_the_lookup_fails():
    executor = _bare_executor()

    def boom(self, params):
        raise RuntimeError("unauthorised")

    executor._client = type("C", (), {"get_balance_allowance": boom})()
    assert executor.bankroll_usdc() is None


def test_place_turns_a_signing_failure_into_a_result_not_an_exception():
    """A raise here would kill the poll loop, so every failure must be caught."""
    executor = _bare_executor()

    def boom(self, *args, **kwargs):
        raise ValueError("bad tick size")

    executor._client = type("C", (), {"create_order": boom})()
    result = executor.place(a_decision(), MARKET)
    assert not result.success
    assert "bad tick size" in result.error
