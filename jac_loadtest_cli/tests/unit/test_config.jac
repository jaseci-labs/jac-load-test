"""Unit tests for config.jac — three-layer resolution: CLI > jac.toml > built-in defaults."""

import types;
import from unittest { mock }
import from jac_loadtest_cli.config { BUILT_IN_DEFAULTS, from_args, parse_duration, _load_toml_defaults }
import jac_loadtest_cli.config as _cfg_mod;


# ---------------------------------------------------------------------------
# parse_duration
# ---------------------------------------------------------------------------

test "parse duration seconds" {
    assert parse_duration("30s") == 30.0;
}

test "parse duration minutes" {
    assert parse_duration("2m") == 120.0;
}

test "parse duration hours" {
    assert parse_duration("1h") == 3600.0;
}


# ---------------------------------------------------------------------------
# CLI wins over toml and defaults
# ---------------------------------------------------------------------------

test "cli overrides toml" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={"vus": 50}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", vus=10));
    }
    assert cfg.vus == 10;
}

test "cli overrides defaults" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", iterations=5));
    }
    assert cfg.iterations == 5;
}


# ---------------------------------------------------------------------------
# Toml wins over defaults when CLI not set
# ---------------------------------------------------------------------------

test "toml overrides defaults" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"vus": 50, "ramp_up": "10s"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.vus == 50;
    assert cfg.ramp_up == "10s";
}

test "toml login path override" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"login_path": "/auth/login"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.login_path == "/auth/login";
}


# ---------------------------------------------------------------------------
# Missing / empty toml falls back to built-in defaults
# ---------------------------------------------------------------------------

test "missing toml uses defaults" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.vus == BUILT_IN_DEFAULTS["vus"];
    assert cfg.think_time == BUILT_IN_DEFAULTS["think_time"];
}

test "load toml defaults swallows exceptions" {
    with mock.patch("jac_scale.config_loader.get_scale_config", side_effect=Exception("unavailable")) {
        result = _load_toml_defaults();
    }
    assert result == {};
}


# ---------------------------------------------------------------------------
# CLI-only fields are never sourced from toml
# ---------------------------------------------------------------------------

test "cli only fields not from toml" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={"url": "http://toml-host", "username": "toml-user"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har"));
    }
    assert cfg.url is None;
    assert cfg.username is None;
}

test "iterations defaults to one" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.iterations == 1;
}
