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


# ---------------------------------------------------------------------------
# B2 — fractional rps from jac.toml must not silently zero out
# ---------------------------------------------------------------------------

test "toml fractional rps is preserved, not truncated to zero" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"rps": 2.5}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", rps=None));
    }
    assert cfg.rps == 2.5;
}

test "toml integer rps still resolves as a float" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"rps": 5}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", rps=None));
    }
    assert cfg.rps == 5.0;
}

test "cli integer rps overrides fractional toml rps" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"rps": 2.5}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", rps=10));
    }
    assert cfg.rps == 10.0;
}

test "missing rps in toml and cli falls back to built-in default" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", rps=None));
    }
    assert cfg.rps == BUILT_IN_DEFAULTS["rps"];
}


# ---------------------------------------------------------------------------
# H1 — open_loop resolves through the same CLI > toml > default layering
# ---------------------------------------------------------------------------

test "open_loop defaults to false" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", open_loop=None));
    }
    assert cfg.open_loop is False;
}

test "cli open_loop flag is honored" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", open_loop=True));
    }
    assert cfg.open_loop is True;
}

test "toml open_loop is honored when cli does not set it" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"open_loop": True}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", open_loop=None));
    }
    assert cfg.open_loop is True;
}

test "from_dict open_loop defaults to false" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.open_loop is False;
}

test "from_dict open_loop honors explicit true" {
    cfg = LoadTestConfig.from_dict({"open_loop": True, "rps": 10});
    assert cfg.open_loop is True;
}


# ---------------------------------------------------------------------------
# H3 — step_load fields resolve through the same CLI > toml > default layering
# ---------------------------------------------------------------------------

test "step_load fields default to off" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            step_load=None, step_vus=None, step_duration=None, step_max_vus=None,
        ));
    }
    assert cfg.step_load is False;
    assert cfg.step_vus == 0;
    assert cfg.step_duration == "30s";
    assert cfg.step_max_vus == 0;
}

test "cli step_load fields are honored" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            step_load=True, step_vus=10, step_duration="15s", step_max_vus=200,
        ));
    }
    assert cfg.step_load is True;
    assert cfg.step_vus == 10;
    assert cfg.step_duration == "15s";
    assert cfg.step_max_vus == 200;
}

test "toml step_load fields honored when cli does not set them" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={
        "step_load": True, "step_vus": 5, "step_duration": "20s", "step_max_vus": 100,
    }) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            step_load=None, step_vus=None, step_duration=None, step_max_vus=None,
        ));
    }
    assert cfg.step_load is True;
    assert cfg.step_vus == 5;
    assert cfg.step_duration == "20s";
    assert cfg.step_max_vus == 100;
}

test "from_dict step_load fields default to off" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.step_load is False;
    assert cfg.step_vus == 0;
    assert cfg.step_max_vus == 0;
}


# ---------------------------------------------------------------------------
# H9 — slo_map is a CLI-only raw JSON string, like services_map
# ---------------------------------------------------------------------------

test "slo_map defaults to none" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", slo=None));
    }
    assert cfg.slo_map is None;
}

test "cli slo flag is passed through unparsed" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            slo='{"/api": {"p95": {"good": 100, "bad": 500}}}',
        ));
    }
    assert cfg.slo_map == '{"/api": {"p95": {"good": 100, "bad": 500}}}';
}

test "slo_map is not sourced from toml" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"slo_map": '{"/api": {}}'}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", slo=None));
    }
    assert cfg.slo_map is None;
}

test "from_dict slo_map defaults to none" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.slo_map is None;
}

test "from_dict applies slo_map override" {
    cfg = LoadTestConfig.from_dict({"slo_map": '{"/api": {}}'});
    assert cfg.slo_map == '{"/api": {}}';
}


# ---------------------------------------------------------------------------
# H8 — assert_json is a CLI-only repeatable list, like other JSON-ish flags
# ---------------------------------------------------------------------------

test "assert_json defaults to none" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", assert_json=None));
    }
    assert cfg.assert_json is None;
}

test "cli assert_json flag is passed through unparsed" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost", assert_json=["ok=true", "count=1"],
        ));
    }
    assert cfg.assert_json == ["ok=true", "count=1"];
}

test "assert_json is not sourced from toml" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"assert_json": ["ok=true"]}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", assert_json=None));
    }
    assert cfg.assert_json is None;
}

test "from_dict assert_json defaults to none" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.assert_json is None;
}

test "from_dict applies assert_json override" {
    cfg = LoadTestConfig.from_dict({"assert_json": ["ok=true"]});
    assert cfg.assert_json == ["ok=true"];
}


# ---------------------------------------------------------------------------
# H2 — --duration and its duration-aware effect on iterations resolution
# ---------------------------------------------------------------------------

test "duration defaults to none and iterations still defaults to one" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.duration is None;
    assert cfg.iterations == 1;
}

test "cli duration alone leaves iterations unbounded" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", duration="60s"));
    }
    assert cfg.duration == "60s";
    assert cfg.iterations is None;
}

test "cli duration with explicit cli iterations keeps both" {
    with mock.patch("jac_loadtest_cli.config._load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost", duration="60s", iterations=10,
        ));
    }
    assert cfg.duration == "60s";
    assert cfg.iterations == 10;
}

test "toml duration alone leaves iterations unbounded" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"duration": "5m"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.duration == "5m";
    assert cfg.iterations is None;
}

test "toml iterations wins over duration-implied unbounded" {
    with mock.patch.object(
        _cfg_mod, "_load_toml_defaults", return_value={"duration": "5m", "iterations": 3},
    ) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.duration == "5m";
    assert cfg.iterations == 3;
}

test "from_dict duration defaults to none" {
    cfg = LoadTestConfig.from_dict({});
    assert cfg.duration is None;
}

test "from_dict applies duration override" {
    cfg = LoadTestConfig.from_dict({"duration": "30s"});
    assert cfg.duration == "30s";
}


# ---------------------------------------------------------------------------
# --health-check and --fail-on-p95/--fail-on-p99's scoped "ENDPOINT:MS" form
# ---------------------------------------------------------------------------

test "health_check defaults to none" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.health_check is None;
}

test "health_check is read from cli or toml like other CLI+toml flags" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"health_check": "/healthz/live"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.health_check == "/healthz/live";

    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"health_check": "/healthz/live"}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost", health_check="/hz"));
    }
    assert cfg.health_check == "/hz";
}

test "a bare fail-on-p95/p99 value behaves exactly as before scoping existed" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            fail_on_p95_values=["500"], fail_on_p99_values=["1000"],
        ));
    }
    assert cfg.fail_on_p95 == 500.0;
    assert cfg.fail_on_p99 == 1000.0;
    assert cfg.fail_on_p95_scoped == {};
    assert cfg.fail_on_p99_scoped == {};
}

test "no fail-on-p95/p99 flag at all still resolves to none, not an error" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.fail_on_p95 is None;
    assert cfg.fail_on_p99 is None;
    assert cfg.fail_on_p95_scoped == {};
    assert cfg.fail_on_p99_scoped == {};
}

test "fail-on-p95 bare value still falls back to toml, unscoped" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"fail_on_p95": 500}) {
        cfg = from_args(types.SimpleNamespace(har_file="x.har", url="http://localhost"));
    }
    assert cfg.fail_on_p95 == 500.0;
    assert cfg.fail_on_p95_scoped == {};
}

test "ENDPOINT:MS scopes a threshold without setting the global one" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            fail_on_p99_values=["/healthz/live:100"],
        ));
    }
    assert cfg.fail_on_p99 is None;
    assert cfg.fail_on_p99_scoped == {"/healthz/live": 100.0};
}

test "a bare value and scoped values combine on one repeated flag" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        cfg = from_args(types.SimpleNamespace(
            har_file="x.har", url="http://localhost",
            fail_on_p95_values=["500", "/healthz/live:100", "/other:250"],
        ));
    }
    assert cfg.fail_on_p95 == 500.0;
    assert cfg.fail_on_p95_scoped == {"/healthz/live": 100.0, "/other": 250.0};
}

test "more than one bare value is rejected" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        try {
            from_args(types.SimpleNamespace(
                har_file="x.har", url="http://localhost",
                fail_on_p95_values=["500", "600"],
            ));
            assert False, "expected ValueError";
        } except ValueError as exc {
            assert "more than one" in str(exc);
        }
    }
}

test "a malformed scoped value raises a clear error" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={}) {
        try {
            from_args(types.SimpleNamespace(
                har_file="x.har", url="http://localhost",
                fail_on_p99_values=["/healthz/live:not-a-number"],
            ));
            assert False, "expected ValueError";
        } except ValueError as exc {
            assert "/healthz/live:not-a-number" in str(exc);
        }
    }
}

test "from_dict health_check and scoped thresholds pass through directly" {
    cfg = LoadTestConfig.from_dict({
        "health_check": "/healthz/live",
        "fail_on_p99_scoped": {"/healthz/live": 100.0},
    });
    assert cfg.health_check == "/healthz/live";
    assert cfg.fail_on_p99_scoped == {"/healthz/live": 100.0};
}
