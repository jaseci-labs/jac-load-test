"""Unit tests for config.jac — three-layer resolution: CLI > jac.toml > built-in defaults."""

import types;
import from unittest { mock }
import from jac_loadtest_cli.config { BUILT_IN_DEFAULTS, LoadTestConfig, from_args, parse_duration, _load_toml_defaults }
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
    with mock.patch("jaclang.scale.config.config_loader.get_scale_config", side_effect=Exception("unavailable")) {
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


# ---------------------------------------------------------------------------
# LoadTestConfig.from_dict — canonical web entry point
# ---------------------------------------------------------------------------

test "from_dict empty dict uses built-in defaults" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.vus == BUILT_IN_DEFAULTS["vus"];
    assert cfg.mode == BUILT_IN_DEFAULTS["mode"];
    assert cfg.apdex_t == BUILT_IN_DEFAULTS["apdex_t"];
    assert cfg.har_file == "";
    assert cfg.url is None;
}

test "from_dict applies provided overrides" {
    cfg = LoadTestConfig.from_dict({
        "har_file": "recording.har",
        "url": "http://localhost:8000",
        "vus": 25,
        "mode": "microservice",
        "apdex_t": 250.0,
    });
    assert cfg.har_file == "recording.har";
    assert cfg.url == "http://localhost:8000";
    assert cfg.vus == 25;
    assert cfg.mode == "microservice";
    assert cfg.apdex_t == 250.0;
}

test "from_dict explicit null falls back to default" {
    cfg = LoadTestConfig.from_dict({"vus": None, "iterations": None});
    assert cfg.vus == BUILT_IN_DEFAULTS["vus"];
    assert cfg.iterations == BUILT_IN_DEFAULTS["iterations"];
}

test "from_dict ignores unknown keys" {
    cfg = LoadTestConfig.from_dict({"vus": 5, "not_a_real_field": "whatever"});
    assert cfg.vus == 5;
    assert not hasattr(cfg, "not_a_real_field");
}

test "from_dict never touches toml or argparse" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", side_effect=AssertionError("should not be called")) {
        cfg = LoadTestConfig.from_dict({"vus": 3});
    }
    assert cfg.vus == 3;
}
