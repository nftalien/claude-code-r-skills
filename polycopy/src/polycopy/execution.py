"""Order placement.

Two implementations behind one interface: a paper executor that fills
everything at the limit price, and a live executor that signs and posts to the
Polymarket CLOB. The engine cannot tell them apart, which is what makes a dry
run a genuine rehearsal rather than a different code path.
"""

from __future__ import annotations

import logging
import time
from typing import Any, Protocol

from .config import BotConfig
from .models import BUY, Decision, MarketMeta, OrderResult

log = logging.getLogger(__name__)


class Executor(Protocol):
    """Anything that can turn a Decision into an OrderResult."""

    live: bool

    def place(self, decision: Decision, meta: MarketMeta) -> OrderResult: ...

    def bankroll_usdc(self) -> float | None: ...

    def describe(self) -> str: ...


class DryRunExecutor:
    """Paper trading: assumes a complete fill at our limit price.

    That assumption is optimistic on purpose. A dry run that models partial
    fills would need the live book anyway, and an optimistic paper P&L is
    easier to reason about than a half-simulated one - just do not read it as a
    backtest.
    """

    live = False

    def __init__(self) -> None:
        self._counter = 0

    def place(self, decision: Decision, meta: MarketMeta) -> OrderResult:
        self._counter += 1
        log.info(
            "[DRY RUN] would %s %.2f shares @ %.3f ($%.2f) - %s",
            decision.trade.side,
            decision.shares,
            decision.limit_price,
            decision.notional,
            decision.trade.title or decision.trade.condition_id,
        )
        return OrderResult(
            success=True,
            order_id=f"dry-{self._counter:06d}",
            status="matched",
            filled_shares=decision.shares,
            dry_run=True,
        )

    def bankroll_usdc(self) -> float | None:
        return None

    def describe(self) -> str:
        return "dry-run (no orders are sent)"


class ClobExecutor:
    """Live executor backed by py-clob-client."""

    live = True

    def __init__(self, config: BotConfig) -> None:
        # Imported lazily so that watch/dry-run modes work without the trading
        # dependency chain (web3, eth-account) being importable.
        from py_clob_client.client import ClobClient
        from py_clob_client.clob_types import ApiCreds

        secrets = config.secrets
        if not secrets.has_key:
            raise RuntimeError(
                "live trading needs POLYMARKET_PRIVATE_KEY in the environment"
            )

        creds = None
        if secrets.has_api_creds:
            creds = ApiCreds(
                api_key=secrets.api_key,
                api_secret=secrets.api_secret,
                api_passphrase=secrets.api_passphrase,
            )

        self._client = ClobClient(
            config.clob_host,
            chain_id=config.chain_id,
            key=secrets.private_key,
            creds=creds,
            signature_type=secrets.signature_type,
            funder=secrets.funder or None,
        )
        if creds is None:
            # L2 credentials are deterministic from the key, so deriving them
            # keeps first-run setup to a single environment variable.
            log.info("no API credentials in environment; deriving from private key")
            self._client.set_api_creds(self._client.create_or_derive_api_creds())

        self._order_type = config.execution.order_type
        self._fill_delay = config.execution.fill_check_delay_seconds
        self.address = self._client.get_address()

    @property
    def client(self) -> Any:
        return self._client

    def place(self, decision: Decision, meta: MarketMeta) -> OrderResult:
        from py_clob_client.clob_types import (
            OrderArgs,
            OrderType,
            PartialCreateOrderOptions,
        )

        trade = decision.trade
        try:
            signed = self._client.create_order(
                OrderArgs(
                    token_id=trade.asset_id,
                    price=decision.limit_price,
                    size=decision.shares,
                    side=trade.side,
                ),
                PartialCreateOrderOptions(neg_risk=meta.neg_risk),
            )
            order_type = getattr(OrderType, self._order_type, OrderType.FAK)
            response = self._client.post_order(signed, order_type)
        except Exception as exc:  # noqa: BLE001 - any failure must not kill the loop
            log.exception("order placement failed for %s", trade.asset_id)
            return OrderResult(success=False, error=f"{type(exc).__name__}: {exc}")

        return self._interpret(response, decision)

    def _interpret(self, response: Any, decision: Decision) -> OrderResult:
        if not isinstance(response, dict):
            return OrderResult(success=False, error=f"unexpected response: {response!r}")

        success = bool(response.get("success", False))
        order_id = str(response.get("orderID") or response.get("orderId") or "")
        status = str(response.get("status") or "")
        error = str(response.get("errorMsg") or response.get("error") or "")

        if not success:
            return OrderResult(
                success=False, order_id=order_id, status=status, error=error or "rejected"
            )

        filled = self._resolve_fill(order_id, status, decision)
        return OrderResult(
            success=True,
            order_id=order_id,
            status=status,
            filled_shares=filled,
            error=error,
        )

    def _resolve_fill(self, order_id: str, status: str, decision: Decision) -> float:
        """How many shares actually traded.

        The post response reports amounts in maker/taker terms that differ by
        side, so rather than guessing we re-read the order and use its
        ``size_matched`` field. A resting GTC order legitimately reports zero.
        """
        if status in ("live", "delayed", "unmatched"):
            return 0.0
        if not order_id:
            # A matched immediate-or-cancel order with no id to re-read: the
            # optimistic read is the full size, and the ledger is reconciled
            # against the API on the next `status --reconcile`.
            return decision.shares if status == "matched" else 0.0

        if self._fill_delay > 0:
            time.sleep(self._fill_delay)
        try:
            order = self._client.get_order(order_id)
        except Exception as exc:  # noqa: BLE001
            log.warning("could not re-read order %s: %s", order_id, exc)
            return decision.shares if status == "matched" else 0.0

        if isinstance(order, dict):
            for field in ("size_matched", "sizeMatched"):
                if field in order:
                    try:
                        return float(order[field])
                    except (TypeError, ValueError):
                        break
        return decision.shares if status == "matched" else 0.0

    def bankroll_usdc(self) -> float | None:
        """Free USDC collateral, in dollars."""
        from py_clob_client.clob_types import AssetType, BalanceAllowanceParams

        try:
            resp = self._client.get_balance_allowance(
                BalanceAllowanceParams(asset_type=AssetType.COLLATERAL)
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("balance lookup failed: %s", exc)
            return None
        if not isinstance(resp, dict):
            return None
        raw = resp.get("balance")
        try:
            # USDC on Polygon has 6 decimals.
            return float(raw) / 1_000_000
        except (TypeError, ValueError):
            return None

    def position_shares(self, token_id: str) -> float | None:
        """On-chain share balance for an outcome token, used to reconcile."""
        from py_clob_client.clob_types import AssetType, BalanceAllowanceParams

        try:
            resp = self._client.get_balance_allowance(
                BalanceAllowanceParams(asset_type=AssetType.CONDITIONAL, token_id=token_id)
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("conditional balance lookup failed for %s: %s", token_id, exc)
            return None
        if not isinstance(resp, dict):
            return None
        try:
            return float(resp.get("balance")) / 1_000_000
        except (TypeError, ValueError):
            return None

    def cancel_all(self) -> Any:
        return self._client.cancel_all()

    def describe(self) -> str:
        return f"LIVE via {self._client.host} as {self.address} ({self._order_type} orders)"


def build_executor(config: BotConfig, force_dry_run: bool = False) -> Executor:
    """Pick an executor.

    Live trading requires the config flag *and* the absence of a dry-run
    override: two independent switches, because the failure mode of getting
    this wrong is spending real money.
    """
    if force_dry_run or not config.live:
        return DryRunExecutor()
    return ClobExecutor(config)


def side_is_entry(decision: Decision) -> bool:
    return decision.trade.side == BUY
