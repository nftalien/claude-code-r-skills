from __future__ import annotations

import pytest

from polycopy.config import ConfigError, Leader, RiskConfig, Secrets, SizingConfig, load_config

VALID = "0x1111111111111111111111111111111111111111"


def test_leader_normalises_address_and_label():
    messy = "  0x1111111111111111111111111111111111111111  ".upper().replace("0X", "0x")
    leader = Leader(address=messy)
    assert leader.address == VALID
    assert leader.label == VALID[:10]


@pytest.mark.parametrize(
    "bad", ["", "0x123", "1111111111111111111111111111111111111111", "nonsense"]
)
def test_leader_rejects_bad_addresses(bad):
    with pytest.raises(ConfigError):
        Leader(address=bad)


def test_leader_rejects_nonpositive_weight():
    with pytest.raises(ConfigError):
        Leader(address=VALID, weight=0)


@pytest.mark.parametrize("mode", ["fixed", "proportional", "bankroll_fraction"])
def test_sizing_accepts_known_modes(mode):
    assert SizingConfig(mode=mode).mode == mode


def test_sizing_rejects_unknown_mode():
    with pytest.raises(ConfigError):
        SizingConfig(mode="martingale")


def test_sizing_rejects_inverted_bounds():
    with pytest.raises(ConfigError):
        SizingConfig(min_order_usdc=100, max_order_usdc=10)


def test_risk_rejects_inverted_price_band():
    with pytest.raises(ConfigError):
        RiskConfig(min_price=0.9, max_price=0.1)


def test_risk_lowercases_filters():
    cfg = RiskConfig(block_condition_ids=["0xABC"], block_keywords=["Trump"])
    assert cfg.block_condition_ids == ["0xabc"]
    assert cfg.block_keywords == ["trump"]


def test_secrets_never_leak_the_key_in_repr():
    secrets = Secrets.from_env({"POLYMARKET_PRIVATE_KEY": "0xsupersecret"})
    assert "supersecret" not in repr(secrets)
    assert secrets.has_key


def test_secrets_reject_bad_signature_type():
    with pytest.raises(ConfigError):
        Secrets.from_env({"POLYMARKET_SIGNATURE_TYPE": "7"})
    with pytest.raises(ConfigError):
        Secrets.from_env({"POLYMARKET_SIGNATURE_TYPE": "eoa"})


def _write(tmp_path, body):
    path = tmp_path / "config.yaml"
    path.write_text(body)
    return path


def test_load_config_round_trip(tmp_path):
    path = _write(
        tmp_path,
        f"""
leaders:
  - address: "{VALID}"
    label: whale
sizing:
  mode: proportional
  proportional_factor: 0.02
risk:
  min_price: 0.1
poll_interval_seconds: 30
""",
    )
    cfg = load_config(path, env={})
    assert cfg.enabled_leaders[0].label == "whale"
    assert cfg.sizing.proportional_factor == 0.02
    assert cfg.risk.min_price == 0.1
    assert cfg.poll_interval_seconds == 30
    assert cfg.live is False  # dry run unless explicitly enabled


def test_load_config_accepts_bare_address_strings(tmp_path):
    path = _write(tmp_path, f'leaders:\n  - "{VALID}"\n')
    assert load_config(path, env={}).enabled_leaders[0].address == VALID


def test_load_config_rejects_typo_in_section(tmp_path):
    """A silently ignored key here is a real money bug, so it must be fatal."""
    path = _write(tmp_path, f'leaders:\n  - address: "{VALID}"\nrisk:\n  max_order_usd: 10\n')
    with pytest.raises(ConfigError, match="max_order_usd"):
        load_config(path, env={})


def test_load_config_rejects_top_level_typo(tmp_path):
    path = _write(tmp_path, f'leaders:\n  - address: "{VALID}"\npoll_interval: 5\n')
    with pytest.raises(ConfigError, match="poll_interval"):
        load_config(path, env={})


def test_load_config_requires_leaders(tmp_path):
    with pytest.raises(ConfigError, match="leaders"):
        load_config(_write(tmp_path, "sizing:\n  mode: fixed\n"), env={})


def test_load_config_rejects_all_leaders_disabled(tmp_path):
    path = _write(tmp_path, f'leaders:\n  - address: "{VALID}"\n    enabled: false\n')
    with pytest.raises(ConfigError, match="nothing to copy"):
        load_config(path, env={})


def test_load_config_rejects_duplicate_leaders(tmp_path):
    path = _write(tmp_path, f'leaders:\n  - address: "{VALID}"\n  - address: "{VALID}"\n')
    with pytest.raises(ConfigError, match="twice"):
        load_config(path, env={})


def test_load_config_missing_file(tmp_path):
    with pytest.raises(ConfigError, match="not found"):
        load_config(tmp_path / "nope.yaml", env={})
