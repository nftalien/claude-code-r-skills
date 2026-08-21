"""Read-only Polymarket data access: leader activity and market metadata.

These endpoints need no authentication, which is what makes the watch-only mode
of this bot possible without ever touching a private key.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

from .models import LeaderPosition, MarketMeta, SourceTrade, parse_token_ids

__all__ = ["DataSource", "parse_token_ids"]

log = logging.getLogger(__name__)


class DataSource:
    """Client for the public data API (activity) and Gamma API (metadata)."""

    def __init__(
        self,
        data_api: str,
        gamma_api: str,
        client: httpx.Client | None = None,
        timeout: float = 10.0,
    ) -> None:
        self.data_api = data_api.rstrip("/")
        self.gamma_api = gamma_api.rstrip("/")
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": "polycopy/0.1"}
        )
        self._owns_client = client is None
        self._market_cache: dict[str, MarketMeta] = {}

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> DataSource:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _get_json(self, url: str, params: dict[str, Any]) -> Any:
        resp = self._client.get(url, params=params)
        resp.raise_for_status()
        return resp.json()

    # ------------------------------------------------------------------ trades

    def fetch_trades(self, address: str, limit: int = 50, offset: int = 0) -> list[SourceTrade]:
        """Recent fills for a wallet, newest first as returned by the API.

        ``takerOnly`` is left at the API default (taker fills). A copy bot wants
        the leader's deliberate crossing trades, not passive maker fills that
        happen to hit their resting orders.
        """
        payload = self._get_json(
            f"{self.data_api}/trades",
            {"user": address, "limit": limit, "offset": offset},
        )
        if not isinstance(payload, list):
            log.warning("unexpected /trades payload type: %s", type(payload).__name__)
            return []

        trades: list[SourceTrade] = []
        for item in payload:
            if not isinstance(item, dict):
                continue
            trade = SourceTrade.from_api(item, leader=address)
            if trade.is_valid():
                trades.append(trade)
            else:
                log.debug("discarding unparseable trade for %s: %s", address, item)
        return trades

    def fetch_positions(self, address: str, limit: int = 500) -> list[LeaderPosition]:
        """Open positions for a wallet, used to size proportional exits."""
        try:
            payload = self._get_json(
                f"{self.data_api}/positions",
                {"user": address, "limit": limit, "sizeThreshold": 0.1},
            )
        except httpx.HTTPError as exc:
            log.warning("positions lookup failed for %s: %s", address, exc)
            return []
        if not isinstance(payload, list):
            return []
        return [
            LeaderPosition.from_api(item)
            for item in payload
            if isinstance(item, dict) and item.get("asset")
        ]

    def leader_position_size(self, address: str, asset_id: str) -> float | None:
        """Shares the leader currently holds of ``asset_id``.

        Returns ``None`` when the lookup fails, which the caller must treat
        differently from a genuine zero.
        """
        positions = self.fetch_positions(address)
        if not positions:
            return None
        for pos in positions:
            if pos.asset_id == asset_id:
                return pos.size
        return 0.0

    # ----------------------------------------------------------------- markets

    def fetch_market(self, condition_id: str, use_cache: bool = True) -> MarketMeta | None:
        """Market metadata by condition id.

        Metadata is cached for the process lifetime: a market's tick size and
        close date do not change, and a busy leader produces many fills in the
        same market.
        """
        key = condition_id.lower()
        if use_cache and key in self._market_cache:
            return self._market_cache[key]

        try:
            payload = self._get_json(
                f"{self.gamma_api}/markets", {"condition_ids": condition_id}
            )
        except httpx.HTTPError as exc:
            log.warning("market lookup failed for %s: %s", condition_id, exc)
            return None

        # Gamma returns a bare list here, but has wrapped it in {"data": [...]}
        # on some deployments; accept either shape.
        if isinstance(payload, dict):
            payload = payload.get("data", [])
        if not isinstance(payload, list) or not payload:
            log.warning("no market metadata found for %s", condition_id)
            return None

        meta = MarketMeta.from_gamma(payload[0])
        self._market_cache[key] = meta
        return meta

    def invalidate_market(self, condition_id: str) -> None:
        self._market_cache.pop(condition_id.lower(), None)
