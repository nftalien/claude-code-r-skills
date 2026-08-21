"""Command line interface."""

from __future__ import annotations

import logging
import sys
import time
from pathlib import Path

import typer
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table

from .config import BotConfig, ConfigError, load_config
from .datasource import DataSource
from .engine import CopyEngine, reconcile_positions
from .execution import ClobExecutor, build_executor
from .logging_setup import setup_logging
from .models import BUY
from .store import Store

app = typer.Typer(
    add_completion=False,
    help="Copy-trade Polymarket wallets. Dry run by default.",
    no_args_is_help=True,
)
console = Console()
log = logging.getLogger("polycopy")

DEFAULT_CONFIG = "config.yaml"

STARTER_CONFIG = """\
# polycopy configuration.
# Secrets never live here - see .env.example.

leaders:
  - address: "0x0000000000000000000000000000000000000000"  # replace me
    label: whale-1
    weight: 1.0
    # max_order_usdc: 25        # optional per-leader ceiling

sizing:
  mode: fixed                   # fixed | proportional | bankroll_fraction
  fixed_usdc: 10.0
  proportional_factor: 0.01     # used when mode = proportional
  bankroll_fraction: 0.01       # used when mode = bankroll_fraction
  bankroll_usdc: 1000.0
  min_order_usdc: 2.0
  max_order_usdc: 25.0
  exit_policy: proportional     # proportional | full | off

risk:
  min_price: 0.05
  max_price: 0.95
  min_leader_notional_usdc: 100.0
  max_market_exposure_usdc: 50.0
  max_total_exposure_usdc: 500.0
  daily_spend_cap_usdc: 150.0
  max_trade_age_seconds: 300
  min_seconds_to_close: 3600
  max_slippage_bps: 200
  max_open_markets: 20
  block_keywords: []

execution:
  order_type: FAK               # FAK | FOK | GTC
  slippage_bps: 100
  round_shares_down: true

poll_interval_seconds: 15
cold_start_lookback_seconds: 0  # 0 = ignore all history on first run
fetch_limit: 50
db_path: polycopy.db
live: false                     # must be true AND --live passed to trade for real
"""

ENV_TEMPLATE = """\
# Credentials for polycopy. Never commit a filled-in copy of this file.

# Private key of the signing wallet (0x-prefixed hex). Required only for live trading.
POLYMARKET_PRIVATE_KEY=

# L2 API credentials. Leave blank to derive them from the private key on startup.
POLYMARKET_API_KEY=
POLYMARKET_API_SECRET=
POLYMARKET_API_PASSPHRASE=

# Signature type: 0 = EOA, 1 = email/magic proxy, 2 = browser wallet proxy.
POLYMARKET_SIGNATURE_TYPE=0

# Address holding the USDC when signature type is 1 or 2 (your Polymarket deposit address).
POLYMARKET_FUNDER=
"""


def _load(config_path: str) -> BotConfig:
    load_dotenv()
    try:
        return load_config(config_path)
    except ConfigError as exc:
        console.print(f"[bold red]Config error:[/] {exc}")
        raise typer.Exit(code=2) from exc


def _confirm_live(config: BotConfig, force: bool) -> None:
    """Third and final gate before real money moves."""
    console.print()
    console.print("[bold red]LIVE TRADING[/] - real USDC will be spent.")
    table = Table(show_header=False, box=None)
    table.add_row("Leaders", ", ".join(ldr.label for ldr in config.enabled_leaders))
    table.add_row("Sizing", f"{config.sizing.mode}, max ${config.sizing.max_order_usdc:.2f}/order")
    table.add_row("Daily cap", f"${config.risk.daily_spend_cap_usdc:.2f}")
    table.add_row("Total exposure cap", f"${config.risk.max_total_exposure_usdc:.2f}")
    console.print(table)
    console.print()
    if force:
        return
    if not sys.stdin.isatty():
        console.print("[red]Refusing to start live without a TTY. Pass --force if intended.[/]")
        raise typer.Exit(code=3)
    answer = typer.prompt("Type LIVE to continue")
    if answer.strip() != "LIVE":
        console.print("Aborted.")
        raise typer.Exit(code=1)


@app.command()
def init(
    config_path: str = typer.Option(DEFAULT_CONFIG, "--config", "-c"),
    env_path: str = typer.Option(".env.example", "--env"),
    force: bool = typer.Option(False, "--force", help="Overwrite existing files."),
) -> None:
    """Write a starter config.yaml and .env.example."""
    for path, content in ((config_path, STARTER_CONFIG), (env_path, ENV_TEMPLATE)):
        target = Path(path)
        if target.exists() and not force:
            console.print(f"[yellow]skipped[/] {target} (exists; use --force)")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        console.print(f"[green]wrote[/] {target}")
    console.print("\nNext: add leader addresses to the config, then run [bold]polycopy watch[/].")


@app.command()
def doctor(
    config_path: str = typer.Option(DEFAULT_CONFIG, "--config", "-c"),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
) -> None:
    """Check configuration, API reachability and credentials."""
    setup_logging(verbose)
    config = _load(config_path)
    console.print(f"[green]OK[/] config parsed: {len(config.enabled_leaders)} enabled leader(s)")
    console.print(f"     secrets: {config.secrets!r}")

    source = DataSource(config.data_api, config.gamma_api)
    problems = 0
    with source:
        for leader in config.enabled_leaders:
            try:
                trades = source.fetch_trades(leader.address, limit=5)
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]FAIL[/] data API for {leader.label}: {exc}")
                problems += 1
                continue
            if trades:
                newest = time.time() - trades[0].timestamp
                console.print(
                    f"[green]OK[/] {leader.label}: {len(trades)} recent trade(s), "
                    f"newest {newest / 60:.0f} min ago"
                )
            else:
                console.print(f"[yellow]WARN[/] {leader.label}: no recent trades returned")

        if config.enabled_leaders:
            sample = None
            for leader in config.enabled_leaders:
                try:
                    found = source.fetch_trades(leader.address, limit=1)
                except Exception:  # noqa: BLE001 - already reported above
                    continue
                if found:
                    sample = found[0]
                    break
            if sample is not None:
                meta = source.fetch_market(sample.condition_id)
                if meta:
                    console.print(
                        f"[green]OK[/] gamma API: '{meta.question[:60]}' "
                        f"tick={meta.tick_size} min_size={meta.min_order_size}"
                    )
                else:
                    console.print("[red]FAIL[/] gamma API returned no market metadata")
                    problems += 1

    if config.live:
        if not config.secrets.has_key:
            console.print("[red]FAIL[/] live: true but POLYMARKET_PRIVATE_KEY is not set")
            problems += 1
        else:
            try:
                executor = ClobExecutor(config)
                balance = executor.bankroll_usdc()
                console.print(f"[green]OK[/] CLOB auth as {executor.address}")
                console.print(
                    f"[green]OK[/] USDC balance: "
                    f"{'unknown' if balance is None else f'${balance:.2f}'}"
                )
            except Exception as exc:  # noqa: BLE001
                console.print(f"[red]FAIL[/] CLOB client: {exc}")
                problems += 1
    else:
        console.print("[cyan]INFO[/] live: false - orders will be simulated")

    if problems:
        console.print(f"\n[bold red]{problems} problem(s) found.[/]")
        raise typer.Exit(code=1)
    console.print("\n[bold green]All checks passed.[/]")


@app.command()
def watch(
    config_path: str = typer.Option(DEFAULT_CONFIG, "--config", "-c"),
    limit: int = typer.Option(20, "--limit", "-n", help="Trades to show per leader."),
    follow: bool = typer.Option(False, "--follow", "-f", help="Keep polling for new fills."),
) -> None:
    """Show leader activity. Never places or simulates an order."""
    setup_logging()
    config = _load(config_path)
    seen: set[str] = set()

    with DataSource(config.data_api, config.gamma_api) as source:
        while True:
            for leader in config.enabled_leaders:
                try:
                    trades = source.fetch_trades(leader.address, limit=limit)
                except Exception as exc:  # noqa: BLE001
                    console.print(f"[red]{leader.label}: {exc}[/]")
                    continue

                fresh = [t for t in trades if t.key not in seen]
                if not follow:
                    fresh = trades
                if not fresh:
                    continue

                table = Table(title=f"{leader.label} ({leader.address[:10]}...)")
                table.add_column("when")
                table.add_column("side")
                table.add_column("price", justify="right")
                table.add_column("size", justify="right")
                table.add_column("USDC", justify="right")
                table.add_column("market")
                for trade in sorted(fresh, key=lambda t: t.timestamp, reverse=True):
                    seen.add(trade.key)
                    age = (time.time() - trade.timestamp) / 60
                    colour = "green" if trade.side == BUY else "red"
                    table.add_row(
                        f"{age:.0f}m ago",
                        f"[{colour}]{trade.side}[/]",
                        f"{trade.price:.3f}",
                        f"{trade.size:,.0f}",
                        f"${trade.notional:,.0f}",
                        f"{(trade.title or trade.condition_id)[:50]} · {trade.outcome}",
                    )
                console.print(table)

            if not follow:
                return
            time.sleep(config.poll_interval_seconds)


@app.command()
def run(
    config_path: str = typer.Option(DEFAULT_CONFIG, "--config", "-c"),
    live: bool = typer.Option(
        False, "--live", help="Place real orders (config must also set live: true)."
    ),
    once: bool = typer.Option(False, "--once", help="Run a single poll and exit."),
    max_polls: int | None = typer.Option(None, "--max-polls", help="Stop after N polls."),
    force: bool = typer.Option(False, "--force", help="Skip the live-trading confirmation prompt."),
    verbose: bool = typer.Option(False, "--verbose", "-v"),
    log_file: str | None = typer.Option(None, "--log-file"),
) -> None:
    """Run the copy loop."""
    setup_logging(verbose, log_file)
    config = _load(config_path)

    if live and not config.live:
        console.print(
            "[red]--live passed but the config sets live: false.[/] "
            "Both must agree before real orders are sent."
        )
        raise typer.Exit(code=3)
    going_live = live and config.live
    if going_live:
        _confirm_live(config, force)
    elif config.live:
        console.print("[yellow]Config sets live: true, but --live was not passed - simulating.[/]")

    store = Store(config.db_path)
    source = DataSource(config.data_api, config.gamma_api)
    try:
        executor = build_executor(config, force_dry_run=not going_live)
    except Exception as exc:  # noqa: BLE001
        console.print(f"[red]Could not start the executor:[/] {exc}")
        raise typer.Exit(code=4) from exc

    console.print(f"Executor: [bold]{executor.describe()}[/]")
    engine = CopyEngine(config, store, source, executor)
    engine.install_signal_handlers()

    limit = 1 if once else max_polls
    try:
        total = engine.run_forever(max_polls=limit)
    finally:
        source.close()
        store.close()
    console.print(f"\n[bold]Done.[/] {total}")
    for err in total.errors[:10]:
        console.print(f"  [yellow]{err}[/]")


@app.command()
def status(
    config_path: str = typer.Option(DEFAULT_CONFIG, "--config", "-c"),
    orders: int = typer.Option(15, "--orders", "-n", help="Recent orders to show."),
    reconcile: bool = typer.Option(
        False, "--reconcile", help="Compare the local ledger against on-chain balances."
    ),
) -> None:
    """Show positions, exposure and recent orders."""
    setup_logging()
    config = _load(config_path)
    store = Store(config.db_path)

    positions = store.open_positions()
    if positions:
        table = Table(title="Open positions")
        table.add_column("market")
        table.add_column("shares", justify="right")
        table.add_column("avg", justify="right")
        table.add_column("cost", justify="right")
        for pos in positions:
            table.add_row(
                (pos.title or pos.condition_id)[:50],
                f"{pos.shares:,.2f}",
                f"{pos.avg_price:.3f}",
                f"${pos.cost_usdc:,.2f}",
            )
        console.print(table)
    else:
        console.print("No open positions.")

    summary = Table(show_header=False, box=None, title="Exposure")
    summary.add_row("Total at cost", f"${store.total_exposure():,.2f}")
    summary.add_row("Open markets", str(store.open_market_count()))
    summary.add_row(
        "Spent today",
        f"${store.daily_spend():,.2f} / ${config.risk.daily_spend_cap_usdc:,.2f}",
    )
    summary.add_row("Realised P&L", f"${store.realized_pnl():,.2f}")
    summary.add_row("Trades evaluated", str(store.seen_count()))
    console.print(summary)

    recent = store.recent_orders(orders)
    if recent:
        table = Table(title="Recent orders")
        table.add_column("when")
        table.add_column("mode")
        table.add_column("side")
        table.add_column("shares", justify="right")
        table.add_column("price", justify="right")
        table.add_column("status")
        table.add_column("market")
        for row in recent:
            age = (time.time() - row["created_at"]) / 60
            table.add_row(
                f"{age:.0f}m ago",
                "paper" if row["dry_run"] else "live",
                row["side"],
                f"{row['shares']:,.2f}",
                f"{row['limit_price']:.3f}",
                row["status"] or (row["error"][:20] if row["error"] else "?"),
                (row["title"] or row["condition_id"])[:40],
            )
        console.print(table)

    if reconcile:
        if not config.live or not config.secrets.has_key:
            console.print("[yellow]Reconcile needs live: true and a private key.[/]")
        else:
            drift = reconcile_positions(store, ClobExecutor(config))
            if drift:
                console.print("[yellow]Ledger drift detected:[/]")
                for asset, ledger, chain in drift:
                    console.print(f"  {asset[:16]}...: ledger {ledger:.2f} vs chain {chain:.2f}")
            else:
                console.print("[green]Ledger matches on-chain balances.[/]")

    store.close()


if __name__ == "__main__":
    app()
