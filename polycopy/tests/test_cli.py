"""CLI tests. HTTP is mocked; no command in this file can place a real order."""

from __future__ import annotations

import httpx
import respx
from typer.testing import CliRunner

from polycopy.cli import app

runner = CliRunner()

ADDRESS = "0x1111111111111111111111111111111111111111"
DATA_API = "https://data.test"
GAMMA_API = "https://gamma.test"

CONFIG = f"""
leaders:
  - address: "{ADDRESS}"
    label: whale
sizing:
  mode: fixed
  fixed_usdc: 10.0
  max_order_usdc: 25.0
risk:
  min_leader_notional_usdc: 50.0
execution:
  order_type: FAK
poll_interval_seconds: 1
data_api: "{DATA_API}"
gamma_api: "{GAMMA_API}"
live: {{live}}
db_path: "{{db}}"
cold_start_lookback_seconds: {{lookback}}
"""


def write_config(tmp_path, live="false", lookback=600):
    """``lookback`` defaults to 10 minutes so freshly-minted test trades are
    eligible on the first poll; cold start would otherwise skip them all."""
    path = tmp_path / "config.yaml"
    path.write_text(
        CONFIG.format(live=live, db=tmp_path / "state.db", lookback=lookback)
    )
    return str(path)


def mock_apis(trades):
    respx.get(f"{DATA_API}/trades").mock(return_value=httpx.Response(200, json=trades))
    respx.get(f"{DATA_API}/positions").mock(return_value=httpx.Response(200, json=[]))
    respx.get(f"{GAMMA_API}/markets").mock(
        return_value=httpx.Response(
            200,
            json=[{
                "conditionId": "0xabc",
                "question": "Will X happen?",
                "closed": False,
                "active": True,
                "acceptingOrders": True,
                "endDate": "2030-01-01T00:00:00Z",
                "orderPriceMinTickSize": "0.01",
                "orderMinSize": "5",
                "clobTokenIds": '["12345"]',
            }],
        )
    )


def a_trade(age_seconds=30, tx="0xfeed"):
    import time

    return {
        "proxyWallet": ADDRESS,
        "side": "BUY",
        "asset": "12345",
        "conditionId": "0xabc",
        "size": "1000",
        "price": "0.40",
        "timestamp": int(time.time() - age_seconds),
        "title": "Will X happen?",
        "outcome": "Yes",
        "transactionHash": tx,
    }


def test_help_lists_every_command():
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    for command in ("init", "doctor", "watch", "run", "status"):
        assert command in result.output


def test_init_writes_a_starter_config(tmp_path):
    config = tmp_path / "config.yaml"
    env = tmp_path / ".env.example"
    result = runner.invoke(app, ["init", "--config", str(config), "--env", str(env)])
    assert result.exit_code == 0
    assert "leaders:" in config.read_text()
    assert "POLYMARKET_PRIVATE_KEY" in env.read_text()
    assert "live: false" in config.read_text()


def test_init_does_not_clobber_existing_files(tmp_path):
    config = tmp_path / "config.yaml"
    config.write_text("mine\n")
    runner.invoke(app, ["init", "--config", str(config), "--env", str(tmp_path / ".env")])
    assert config.read_text().strip() == "mine"


def test_a_bad_config_exits_with_a_message(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_text("leaders:\n  - address: nonsense\n")
    result = runner.invoke(app, ["run", "--config", str(path)])
    assert result.exit_code == 2
    assert "Config error" in result.output


@respx.mock
def test_run_copies_a_qualifying_trade_on_paper(tmp_path):
    mock_apis([a_trade()])
    config = write_config(tmp_path)
    result = runner.invoke(app, ["run", "--config", config, "--once"])
    assert result.exit_code == 0, result.output
    assert "dry-run" in result.output
    assert "1 copied" in result.output


@respx.mock
def test_run_ignores_history_on_the_first_run(tmp_path):
    """Cold start must not fire 50 orders the first time it starts."""
    mock_apis([a_trade(age_seconds=120, tx=f"0x{i}") for i in range(10)])
    config = write_config(tmp_path, lookback=0)  # 0 = ignore everything that predates the run
    result = runner.invoke(app, ["run", "--config", config, "--once"])
    assert result.exit_code == 0
    assert "0 copied" in result.output


@respx.mock
def test_live_flag_without_a_live_config_is_refused(tmp_path):
    mock_apis([])
    result = runner.invoke(app, ["run", "--config", write_config(tmp_path), "--live", "--once"])
    assert result.exit_code == 3
    assert "Both must agree" in result.output


@respx.mock
def test_a_live_config_without_the_flag_still_simulates(tmp_path):
    mock_apis([])
    result = runner.invoke(app, ["run", "--config", write_config(tmp_path, live="true"), "--once"])
    assert result.exit_code == 0
    assert "simulating" in result.output


@respx.mock
def test_live_run_refuses_to_start_without_a_tty(tmp_path, monkeypatch):
    mock_apis([])
    monkeypatch.setenv("POLYMARKET_PRIVATE_KEY", "0x" + "1" * 64)
    config = write_config(tmp_path, live="true")
    result = runner.invoke(app, ["run", "--config", config, "--live", "--once"])
    assert result.exit_code == 3
    assert "Refusing to start live" in result.output


@respx.mock
def test_watch_prints_activity_without_trading(tmp_path):
    mock_apis([a_trade()])
    result = runner.invoke(app, ["watch", "--config", write_config(tmp_path)])
    assert result.exit_code == 0
    assert "BUY" in result.output
    assert "whale" in result.output
    # watch never opens the database, so nothing can be recorded
    assert not (tmp_path / "state.db").exists()


@respx.mock
def test_status_on_an_empty_database(tmp_path):
    mock_apis([])
    result = runner.invoke(app, ["status", "--config", write_config(tmp_path)])
    assert result.exit_code == 0
    assert "No open positions" in result.output


@respx.mock
def test_status_reports_a_position_after_a_paper_run(tmp_path):
    mock_apis([a_trade()])
    config = write_config(tmp_path)
    runner.invoke(app, ["run", "--config", config, "--once"])
    result = runner.invoke(app, ["status", "--config", config])
    assert result.exit_code == 0
    assert "Will X happen?" in result.output
    assert "paper" in result.output


@respx.mock
def test_doctor_reports_reachable_apis(tmp_path):
    mock_apis([a_trade()])
    result = runner.invoke(app, ["doctor", "--config", write_config(tmp_path)])
    assert result.exit_code == 0
    assert "All checks passed" in result.output
    assert "orders will be simulated" in result.output


@respx.mock
def test_doctor_fails_loudly_when_the_data_api_is_down(tmp_path):
    respx.get(f"{DATA_API}/trades").mock(return_value=httpx.Response(500))
    respx.get(f"{GAMMA_API}/markets").mock(return_value=httpx.Response(200, json=[]))
    result = runner.invoke(app, ["doctor", "--config", write_config(tmp_path)])
    assert result.exit_code == 1
    assert "FAIL" in result.output


@respx.mock
def test_doctor_flags_a_live_config_with_no_key(tmp_path, monkeypatch):
    monkeypatch.delenv("POLYMARKET_PRIVATE_KEY", raising=False)
    mock_apis([a_trade()])
    result = runner.invoke(app, ["doctor", "--config", write_config(tmp_path, live="true")])
    assert result.exit_code == 1
    assert "POLYMARKET_PRIVATE_KEY" in result.output
