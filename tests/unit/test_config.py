"""Unit tests for three-layer config resolution: CLI > jac.toml > built-in defaults."""
from __future__ import annotations

import types
from unittest.mock import patch

import pytest

from jac_loadtest.config import BUILT_IN_DEFAULTS, from_args, parse_duration


# ---------------------------------------------------------------------------
# parse_duration
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_parse_duration_seconds():
    assert parse_duration("30s") == 30.0


@pytest.mark.unit
def test_parse_duration_minutes():
    assert parse_duration("2m") == 120.0


@pytest.mark.unit
def test_parse_duration_hours():
    assert parse_duration("1h") == 3600.0


# ---------------------------------------------------------------------------
# Three-layer resolution helpers
# ---------------------------------------------------------------------------

def _args(**kwargs) -> object:
    """Build a SimpleNamespace with only the fields provided (others absent)."""
    return types.SimpleNamespace(**kwargs)


def _mock_toml(section: dict):
    """Patch _load_toml_defaults to return a fixed dict."""
    return patch("jac_loadtest.config._load_toml_defaults", return_value=section)


# ---------------------------------------------------------------------------
# CLI wins over toml and defaults
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_cli_overrides_toml():
    with _mock_toml({"vus": 50}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost", vus=10))
    assert cfg.vus == 10


@pytest.mark.unit
def test_cli_overrides_defaults():
    with _mock_toml({}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost", duration="5m"))
    assert cfg.duration == "5m"


# ---------------------------------------------------------------------------
# Toml wins over defaults when CLI not set
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_toml_overrides_defaults():
    with _mock_toml({"vus": 50, "duration": "10m"}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost"))
    assert cfg.vus == 50
    assert cfg.duration == "10m"


@pytest.mark.unit
def test_toml_login_path_override():
    with _mock_toml({"login_path": "/auth/login"}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost"))
    assert cfg.login_path == "/auth/login"


# ---------------------------------------------------------------------------
# Missing / empty toml falls back to built-in defaults
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_missing_toml_uses_defaults():
    with _mock_toml({}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost"))
    assert cfg.vus == BUILT_IN_DEFAULTS["vus"]
    assert cfg.duration == BUILT_IN_DEFAULTS["duration"]
    assert cfg.think_time == BUILT_IN_DEFAULTS["think_time"]


@pytest.mark.unit
def test_load_toml_defaults_swallows_exceptions():
    """_load_toml_defaults returns {} when get_scale_config raises any exception."""
    from jac_loadtest.config import _load_toml_defaults
    with patch("jac_scale.config_loader.get_scale_config", side_effect=Exception("unavailable")):
        result = _load_toml_defaults()
    assert result == {}


# ---------------------------------------------------------------------------
# CLI-only fields are never sourced from toml
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_cli_only_fields_not_from_toml():
    """url, username, password, credentials_file must not be set from toml."""
    with _mock_toml({"url": "http://toml-host", "username": "toml-user"}):
        cfg = from_args(_args(har_file="x.har"))
    assert cfg.url is None
    assert cfg.username is None


@pytest.mark.unit
def test_iterations_defaults_to_one():
    with _mock_toml({}):
        cfg = from_args(_args(har_file="x.har", url="http://localhost"))
    assert cfg.iterations == 1
