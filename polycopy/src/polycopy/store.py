"""SQLite-backed state.

The bot must survive restarts without re-copying history it has already acted
on, so idempotency keys, our own position ledger and the daily spend counter all
live in one small database rather than in memory.
"""

from __future__ import annotations

import sqlite3
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .models import BUY, Decision, OrderResult, SourceTrade

SCHEMA = """
CREATE TABLE IF NOT EXISTS seen_trades (
    key          TEXT PRIMARY KEY,
    leader       TEXT NOT NULL,
    asset_id     TEXT NOT NULL,
    condition_id TEXT NOT NULL,
    side         TEXT NOT NULL,
    price        REAL NOT NULL,
    size         REAL NOT NULL,
    timestamp    INTEGER NOT NULL,
    seen_at      INTEGER NOT NULL,
    action       TEXT NOT NULL,
    reason       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_seen_leader_ts ON seen_trades (leader, timestamp DESC);

CREATE TABLE IF NOT EXISTS orders (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    trade_key     TEXT NOT NULL,
    leader        TEXT NOT NULL,
    asset_id      TEXT NOT NULL,
    condition_id  TEXT NOT NULL,
    title         TEXT NOT NULL DEFAULT '',
    side          TEXT NOT NULL,
    shares        REAL NOT NULL,
    limit_price   REAL NOT NULL,
    notional      REAL NOT NULL,
    order_id      TEXT NOT NULL DEFAULT '',
    status        TEXT NOT NULL DEFAULT '',
    filled_shares REAL NOT NULL DEFAULT 0,
    error         TEXT NOT NULL DEFAULT '',
    dry_run       INTEGER NOT NULL DEFAULT 1,
    created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders (created_at DESC);

CREATE TABLE IF NOT EXISTS positions (
    asset_id     TEXT PRIMARY KEY,
    condition_id TEXT NOT NULL,
    title        TEXT NOT NULL DEFAULT '',
    shares       REAL NOT NULL DEFAULT 0,
    cost_usdc    REAL NOT NULL DEFAULT 0,
    realized_pnl REAL NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS daily_spend (
    day       TEXT PRIMARY KEY,
    usdc      REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


@dataclass
class Position:
    asset_id: str
    condition_id: str
    title: str
    shares: float
    cost_usdc: float
    realized_pnl: float = 0.0

    @property
    def avg_price(self) -> float:
        return self.cost_usdc / self.shares if self.shares > 0 else 0.0


def utc_day(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc)
    return dt.strftime("%Y-%m-%d")


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> Store:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        try:
            yield self.conn
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

    # -------------------------------------------------------------- meta flags

    def get_meta(self, key: str, default: str = "") -> str:
        row = self.conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default

    def set_meta(self, key: str, value: str) -> None:
        with self._tx() as c:
            c.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )

    @property
    def is_fresh(self) -> bool:
        """True until the first poll has been recorded (drives cold start)."""
        return self.get_meta("initialised") != "1"

    def mark_initialised(self) -> None:
        self.set_meta("initialised", "1")

    # ------------------------------------------------------------ seen trades

    def has_seen(self, key: str) -> bool:
        row = self.conn.execute("SELECT 1 FROM seen_trades WHERE key = ?", (key,)).fetchone()
        return row is not None

    def mark_seen(self, trade: SourceTrade, action: str, reason: str = "") -> None:
        """Record a trade as processed.

        Called for skipped trades too: without that, a trade rejected by a risk
        filter would be re-evaluated on every poll forever, and could be copied
        late if the filter state changed.
        """
        with self._tx() as c:
            c.execute(
                "INSERT OR IGNORE INTO seen_trades "
                "(key, leader, asset_id, condition_id, side, price, size, timestamp, "
                " seen_at, action, reason) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    trade.key,
                    trade.leader,
                    trade.asset_id,
                    trade.condition_id,
                    trade.side,
                    trade.price,
                    trade.size,
                    trade.timestamp,
                    int(time.time()),
                    action,
                    reason,
                ),
            )

    def seen_count(self) -> int:
        return self.conn.execute("SELECT COUNT(*) AS n FROM seen_trades").fetchone()["n"]

    # ---------------------------------------------------------------- orders

    def record_order(self, decision: Decision, result: OrderResult) -> int:
        trade = decision.trade
        with self._tx() as c:
            cur = c.execute(
                "INSERT INTO orders "
                "(trade_key, leader, asset_id, condition_id, title, side, shares, limit_price,"
                " notional, order_id, status, filled_shares, error, dry_run, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    trade.key,
                    trade.leader,
                    trade.asset_id,
                    trade.condition_id,
                    trade.title,
                    trade.side,
                    decision.shares,
                    decision.limit_price,
                    decision.notional,
                    result.order_id,
                    result.status,
                    result.filled_shares,
                    result.error,
                    1 if result.dry_run else 0,
                    int(time.time()),
                ),
            )
            return int(cur.lastrowid or 0)

    def recent_orders(self, limit: int = 20) -> list[sqlite3.Row]:
        return list(
            self.conn.execute(
                "SELECT * FROM orders ORDER BY created_at DESC, id DESC LIMIT ?", (limit,)
            ).fetchall()
        )

    # ------------------------------------------------------------- positions

    def get_position(self, asset_id: str) -> Position | None:
        row = self.conn.execute(
            "SELECT * FROM positions WHERE asset_id = ?", (asset_id,)
        ).fetchone()
        if row is None or row["shares"] <= 0:
            return None
        return Position(
            asset_id=row["asset_id"],
            condition_id=row["condition_id"],
            title=row["title"],
            shares=row["shares"],
            cost_usdc=row["cost_usdc"],
            realized_pnl=row["realized_pnl"],
        )

    def open_positions(self) -> list[Position]:
        rows = self.conn.execute(
            "SELECT * FROM positions WHERE shares > 1e-9 ORDER BY cost_usdc DESC"
        ).fetchall()
        return [
            Position(
                asset_id=r["asset_id"],
                condition_id=r["condition_id"],
                title=r["title"],
                shares=r["shares"],
                cost_usdc=r["cost_usdc"],
                realized_pnl=r["realized_pnl"],
            )
            for r in rows
        ]

    def apply_fill(
        self,
        asset_id: str,
        condition_id: str,
        side: str,
        shares: float,
        price: float,
        title: str = "",
    ) -> None:
        """Update our position ledger from a fill.

        Buys add shares at cost; sells retire shares at average cost and book the
        difference as realised P&L, so ``cost_usdc`` always reflects money still
        at risk rather than money ever spent.
        """
        if shares <= 0:
            return
        now = int(time.time())
        with self._tx() as c:
            row = c.execute("SELECT * FROM positions WHERE asset_id = ?", (asset_id,)).fetchone()
            cur_shares = row["shares"] if row else 0.0
            cur_cost = row["cost_usdc"] if row else 0.0
            realized = row["realized_pnl"] if row else 0.0

            if side == BUY:
                new_shares = cur_shares + shares
                new_cost = cur_cost + shares * price
            else:
                sold = min(shares, cur_shares)
                avg = cur_cost / cur_shares if cur_shares > 0 else 0.0
                new_shares = cur_shares - sold
                new_cost = max(0.0, cur_cost - sold * avg)
                realized += sold * (price - avg)
                # Clear residual cost from float drift once the position is flat.
                if new_shares <= 1e-9:
                    new_shares, new_cost = 0.0, 0.0

            c.execute(
                "INSERT INTO positions "
                "(asset_id, condition_id, title, shares, cost_usdc, realized_pnl, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(asset_id) DO UPDATE SET "
                "  condition_id = excluded.condition_id,"
                "  title        = CASE WHEN excluded.title != '' THEN excluded.title"
                "                      ELSE positions.title END,"
                "  shares       = excluded.shares,"
                "  cost_usdc    = excluded.cost_usdc,"
                "  realized_pnl = excluded.realized_pnl,"
                "  updated_at   = excluded.updated_at",
                (asset_id, condition_id, title, new_shares, new_cost, realized, now),
            )

    # -------------------------------------------------------------- exposure

    def total_exposure(self) -> float:
        row = self.conn.execute(
            "SELECT COALESCE(SUM(cost_usdc), 0) AS v FROM positions WHERE shares > 1e-9"
        ).fetchone()
        return float(row["v"])

    def market_exposure(self, condition_id: str) -> float:
        row = self.conn.execute(
            "SELECT COALESCE(SUM(cost_usdc), 0) AS v FROM positions "
            "WHERE condition_id = ? AND shares > 1e-9",
            (condition_id,),
        ).fetchone()
        return float(row["v"])

    def open_market_count(self) -> int:
        row = self.conn.execute(
            "SELECT COUNT(DISTINCT condition_id) AS n FROM positions WHERE shares > 1e-9"
        ).fetchone()
        return int(row["n"])

    def realized_pnl(self) -> float:
        row = self.conn.execute(
            "SELECT COALESCE(SUM(realized_pnl), 0) AS v FROM positions"
        ).fetchone()
        return float(row["v"])

    # ------------------------------------------------------------ daily spend

    def daily_spend(self, day: str | None = None) -> float:
        day = day or utc_day()
        row = self.conn.execute("SELECT usdc FROM daily_spend WHERE day = ?", (day,)).fetchone()
        return float(row["usdc"]) if row else 0.0

    def add_daily_spend(self, amount: float, day: str | None = None) -> None:
        if amount <= 0:
            return
        day = day or utc_day()
        with self._tx() as c:
            c.execute(
                "INSERT INTO daily_spend (day, usdc) VALUES (?, ?) "
                "ON CONFLICT(day) DO UPDATE SET usdc = daily_spend.usdc + excluded.usdc",
                (day, amount),
            )
