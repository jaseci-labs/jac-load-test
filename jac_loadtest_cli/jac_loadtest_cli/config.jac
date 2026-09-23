import os;

glob BUILT_IN_DEFAULTS: dict[str, object] = {
    "vus": 1,
    "iterations": 1,
    "ramp_up": "0s",
    "timeout": "30s",
    "workers": os.cpu_count() or 1,
    "mode": "monolith",
    "think_time": "none",
    "think_time_scale": 1.0,
    "rps": 0,
    "open_loop": False,
    "step_load": False,
    "step_vus": 0,
    "step_duration": "30s",
    "step_max_vus": 0,
    "include_static": False,
    "login_path": "/user/login",
    "register_path": "/user/register",
    "auto_register": True,
    "auth_delay": 0.0,
    "auth_batch_size": 0,
    "auth_batch_delay": 0.0,
    "skip_failed_accounts": False,
    "fail_on_error_rate": None,
    "fail_on_p95": None,
    "fail_on_p99": None,
    "abort_on_fail": False,
    "threshold_start_delay": "0s",
    "report_format": "console",
    "max_samples": 1_000_000,
    "csrf": False,
    "body_check": True,
    "infra_block_threshold": 3,
    "check_shape": False,
    "fail_on_shape_drift": False,
    "auto_correlate": True,
    "debug": False,
    "apdex_t": 500.0,
    "poll_timeout": "60s",
};

# LoadTestConfig fields with no BUILT_IN_DEFAULTS entry — used by from_dict() to fill
# in the remaining constructor kwargs so it never needs argparse or jac.toml lookups.
glob _NON_BUILT_IN_DEFAULTS: dict[str, object] = {
    "har_file": "",
    "spec": None,
    "url": None,
    "username": None,
    "password": None,
    "services_map": None,
    "report_out": None,
    "slo_map": None,
    "assert_json": None,
    "correlate": None,
    "accounts": None,
    "param": None,
    "proxy_pool": None,
    "duration": None,
    # Phase 9 — protocol-specific config blocks alongside the HTTP config
    # above. Each is either a JSON array string (CLI-style) or an
    # already-parsed list[dict] (from_dict()/web-style); see
    # core/ws_engine.jac:parse_ws_scenarios() and
    # core/graphql_engine.jac:parse_graphql_scenarios().
    "ws_scenarios": None,
    "graphql_scenarios": None,
    "health_check": None,
    "fail_on_p95_scoped": {},
    "fail_on_p99_scoped": {},
    "poll_until": None,
    "poll_error_until": None,
    "poll_interval": None,
};

obj LoadTestConfig {
    has vus: int = 1;
    has iterations: int | None = 1;
    has duration: str | None = None;
    has ramp_up: str = "0s";
    has timeout: str = "30s";
    has workers: int = 1;
    has mode: str = "monolith";
    has think_time: str = "none";
    has think_time_scale: float = 1.0;
    has rps: float = 0;
    has open_loop: bool = False;
    has step_load: bool = False;
    has step_vus: int = 0;
    has step_duration: str = "30s";
    has step_max_vus: int = 0;
    has include_static: bool = False;
    has login_path: str = "/user/login";
    # Phase 7b — jac-scale's built-in signup endpoint, used only as a fallback
    # when a login 401s AND the account turns out not to exist.
    has register_path: str = "/user/register";
    has auto_register: bool = True;
    # Pacing for the pre-run auth burst (register/login per account), so a
    # large --accounts pool doesn't trip a target's rate limiter or WAF.
    # auth_delay paces every account uniformly; auth_batch_size/auth_batch_delay
    # additionally (or instead) pause after every N accounts, matching a
    # windowed rate limit (e.g. "50 requests per minute") more directly than a
    # uniform delay can. See bridge/auth.jac:authenticate_all().
    has auth_delay: float = 0.0;
    has auth_batch_size: int = 0;
    has auth_batch_delay: float = 0.0;
    # Phase 7b — continue when some accounts fail to authenticate, instead of
    # aborting the run. Off by default: in CI a bad credential should be fatal.
    has skip_failed_accounts: bool = False;
    has csrf: bool = False;
    # Phase 8b — treat a 200 carrying an error envelope as a failure. On by
    # default: on jac-scale a walker reporting failure inside a 200 is the
    # normal shape, and counting it as success makes a broken run look clean.
    has body_check: bool = True;
    # Phase 8a — how many distinct endpoints must return the same non-JSON body
    # in one time bucket before it is read as an infrastructure block rather
    # than an application error. Below 2 disables the check.
    has infra_block_threshold: int = 3;
    # Structural divergence from the recorded response. Off by default and a
    # softer signal — the response did not say it failed, it just looks
    # different, which legitimately happens as an app evolves.
    has check_shape: bool = False;
    has fail_on_shape_drift: bool = False;
    # Phase 7a — detect correlations statically from the HAR at startup. On by
    # default: the scan reads the recorded file, costs no round trip, and the
    # stale-id failure it prevents is the top blocker for mixed workflows.
    has auto_correlate: bool = True;
    has fail_on_error_rate: float | None = None;
    has fail_on_p95: float | None = None;
    has fail_on_p99: float | None = None;
    # Endpoint -> threshold(ms), parsed from repeated "ENDPOINT:MS" values on
    # --fail-on-p95/--fail-on-p99. Checked against that endpoint's own p95/p99
    # (from EndpointStats), separately from the plain global threshold above —
    # see cli.jac. CLI-only, like --assert-json/--correlate: not read from
    # jac.toml, since it's a run-specific gate rather than a project default.
    has fail_on_p95_scoped: dict[str, float] = {};
    has fail_on_p99_scoped: dict[str, float] = {};
    has abort_on_fail: bool = False;
    has threshold_start_delay: str = "0s";
    has report_format: str = "console";
    has max_samples: int = 1_000_000;
    has debug: bool = False;
    has apdex_t: float = 500.0;
    has har_file: str = "";
    # Phase 10c — alternative to har_file: an OpenAPI/Swagger source (URL or
    # file) parsed straight into HarEntry-compatible entries in memory, no
    # intermediate .har file. Mutually exclusive with har_file (cli.jac/
    # headless.jac enforce this).
    has spec: str | None = None;
    has url: str | None = None;
    has username: str | None = None;
    has password: str | None = None;
    has services_map: str | None = None;
    has report_out: str | None = None;
    has slo_map: str | None = None;
    has assert_json: list[str] | None = None;
    # Explicit "Producer.response.a.b -> Consumer.body.c" rules; take precedence
    # over anything detection proposes for the same producer/consumer pair.
    has correlate: list[str] | None = None;
    # Phase 7b — per-VU account pool. Either an inline JSON map
    # ('{"alice":"pw1"}'), an inline JSON array, or a path to a .json/.csv
    # file. object because the headless entry point may pass an already-parsed
    # dict or list rather than a string.
    has accounts: object | None = None;
    # Phase 7c — "<endpoint>.<target>=<file>" rules feeding request fields from
    # a list of real values. Inline {{...}} tokens need no config at all.
    has param: list[str] | None = None;
    # Phase 8a — file of proxy URLs to spread egress across. A partial
    # mitigation for single-source-IP blocking, not a substitute for Phase 11.
    has proxy_pool: str | None = None;
    # object because it accepts either a raw JSON array string (CLI) or a
    # plain list[dict] (LoadTestConfig.from_dict() / web callers).
    has ws_scenarios: object | None = None;
    has graphql_scenarios: object | None = None;
    # One extra unauthenticated GET fired against --url + this path, once per
    # VU per iteration, alongside the HAR replay -- e.g. "/healthz/live". Its
    # samples get their own endpoint row in the report and are excluded from
    # the run's global/TOTAL aggregates (cli.jac, output/reporter.jac), so it
    # can be gated on its own via --fail-on-p95/--fail-on-p99's scoped form
    # without diluting, or being diluted by, the rest of the traffic mix.
    has health_check: str | None = None;
    # --poll-until support (see core/engine.jac). Collapses a consecutively
    # recorded run of same-endpoint requests (a status-polling loop) into a
    # wait-until step instead of replaying it a fixed number of times: keep
    # re-sending the block's recorded request until a JSON field in the
    # response body reaches one of poll_until's terminal SUCCESS values, or
    # one of poll_error_until's terminal FAILURE values, or poll_timeout
    # elapses. Off by default — plain HAR replay is unaffected unless set.
    has poll_until: list[str] | None = None;
    has poll_error_until: list[str] | None = None;
    has poll_timeout: str = "60s";
    # Gap between polls inside a block. Defaults (None) to the gap actually
    # recorded between those calls in the HAR — see core/engine.jac:
    # _run_poll_block(). Override when the recording only captured a few fast
    # polls and the real interval you want to poll at differs.
    has poll_interval: str | None = None;

    # Canonical web entry point: build a LoadTestConfig from a plain dict (e.g. a
    # JSON request body). Missing or explicit-null keys fall back to BUILT_IN_DEFAULTS
    # / _NON_BUILT_IN_DEFAULTS; unknown keys in `d` are ignored. No jac.toml lookup,
    # no argparse — safe to call with no CLI context.
    class def from_dict(d: dict) -> LoadTestConfig {
        merged: dict[str, object] = {**BUILT_IN_DEFAULTS, **_NON_BUILT_IN_DEFAULTS};
        for key in merged {
            if key in d and d[key] is not None {
                merged[key] = d[key];
            }
        }
        return LoadTestConfig(**merged);
    }
}

def parse_duration(s: str) -> float {
    s = s.strip();
    if s.endswith("h") {
        return float(s[:-1]) * 3600;
    }
    if s.endswith("m") {
        return float(s[:-1]) * 60;
    }
    if s.endswith("s") {
        return float(s[:-1]);
    }
    return float(s);
}

def _load_toml_defaults() -> dict[str, object] {
    try {
        import from pathlib { Path }
        import from jaclang.scale.config.config_loader { get_scale_config, reset_scale_config }
        reset_scale_config();
        scale_config = get_scale_config(project_dir=Path.cwd());
        return scale_config.get_section("loadtest");
    } except Exception {
        return {};
    }
}

def _resolve(name: str, args: object, toml: dict[str, object]) -> object {
    cli_val = getattr(args, name, None);
    if cli_val is not None {
        return cli_val;
    }
    if name in toml {
        val = toml[name];
        if val is not None {
            return val;
        }
    }
    return BUILT_IN_DEFAULTS.get(name);
}

def _resolve_str(name: str, args: object, toml: dict[str, object]) -> str {
    val = _resolve(name, args, toml);
    if isinstance(val, str) {
        return val;
    }
    return "";
}

def _resolve_int(name: str, args: object, toml: dict[str, object]) -> int {
    val = _resolve(name, args, toml);
    if isinstance(val, int) {
        return val;
    }
    return 0;
}

def _resolve_float(name: str, args: object, toml: dict[str, object]) -> float {
    val = _resolve(name, args, toml);
    if isinstance(val, float) {
        return val;
    }
    if isinstance(val, int) {
        return float(val);
    }
    return 0.0;
}

def _resolve_bool(name: str, args: object, toml: dict[str, object]) -> bool {
    val = _resolve(name, args, toml);
    if isinstance(val, bool) {
        return val;
    }
    return False;
}

def _resolve_opt_str(name: str, args: object, toml: dict[str, object]) -> str | None {
    val = _resolve(name, args, toml);
    if isinstance(val, str) {
        return val;
    }
    return None;
}

def _resolve_opt_float(name: str, args: object, toml: dict[str, object]) -> float | None {
    val = _resolve(name, args, toml);
    if val is None {
        return None;
    }
    if isinstance(val, float) {
        return val;
    }
    if isinstance(val, int) {
        return float(val);
    }
    return None;
}

def _parse_fail_on_latency(
    flag: str, cli_values: list[str] | None, toml_val: object
) -> tuple[float | None, dict[str, float]] {
    # A bare value ("500") is the plain global threshold, unchanged from
    # before this existed. "ENDPOINT:MS" ("/healthz/live:100") scopes a
    # threshold to that one endpoint instead. At most one bare value is
    # allowed per flag; any number of scoped ones can be combined with it.
    scoped: dict[str, float] = {};
    global_val: float | None = None;
    for item in (cli_values or []) {
        if ":" in item {
            _parts = item.rpartition(":");
            endpoint = _parts[0];
            value_str = _parts[2];
            try {
                scoped[endpoint] = float(value_str);
            } except ValueError {
                raise ValueError(
                    f"Invalid {flag} value '{item}': expected 'ENDPOINT:MS', "
                    "e.g. '/healthz/live:100'"
                );
            }
        } else {
            try {
                parsed = float(item);
            } except ValueError {
                raise ValueError(f"Invalid {flag} value '{item}': not a number");
            }
            if global_val is not None {
                raise ValueError(
                    f"{flag} was given more than one plain (non-scoped) value "
                    f"({global_val:g} and {parsed:g}) — only one global threshold "
                    "is allowed; use 'ENDPOINT:MS' to add per-endpoint thresholds"
                );
            }
            global_val = parsed;
        }
    }
    if global_val is None {
        if isinstance(toml_val, float) {
            global_val = toml_val;
        } elif isinstance(toml_val, int) {
            global_val = float(toml_val);
        }
    }
    return (global_val, scoped);
}

def _resolve_iterations(args: object, toml: dict[str, object]) -> int | None {
    cli_val = getattr(args, "iterations", None);
    if isinstance(cli_val, int) {
        return cli_val;
    }
    toml_val = toml.get("iterations");
    if isinstance(toml_val, int) {
        return toml_val;
    }
    duration_set = getattr(args, "duration", None) is not None or toml.get("duration") is not None;
    if duration_set {
        # --duration with no explicit --iterations: run is time-bound, not
        # replay-count-bound, so VUs loop until the duration watcher stops them.
        return None;
    }
    default = BUILT_IN_DEFAULTS.get("iterations");
    if isinstance(default, int) {
        return default;
    }
    return None;
}

def _getattr_str(src: object, name: str, fallback: str = "") -> str {
    val = getattr(src, name, fallback);
    if isinstance(val, str) {
        return val;
    }
    return fallback;
}

def _getattr_opt_str(src: object, name: str) -> str | None {
    val = getattr(src, name, None);
    if isinstance(val, str) {
        return val;
    }
    return None;
}

def _getattr_opt_list_str(src: object, name: str) -> list[str] | None {
    val = getattr(src, name, None);
    if isinstance(val, list) {
        return val;
    }
    return None;
}

def from_args(args: object) -> LoadTestConfig {
    toml = _load_toml_defaults();
    _fail_p95 = _parse_fail_on_latency(
        "--fail-on-p95", _getattr_opt_list_str(args, "fail_on_p95_values"), toml.get("fail_on_p95")
    );
    _fail_p99 = _parse_fail_on_latency(
        "--fail-on-p99", _getattr_opt_list_str(args, "fail_on_p99_values"), toml.get("fail_on_p99")
    );
    return LoadTestConfig(
        har_file=_getattr_str(args, "har_file", ""),
        spec=_getattr_opt_str(args, "spec"),
        url=_getattr_opt_str(args, "url"),
        username=_getattr_opt_str(args, "username"),
        password=_getattr_opt_str(args, "password"),
        services_map=_getattr_opt_str(args, "services_map"),
        slo_map=_getattr_opt_str(args, "slo"),
        assert_json=_getattr_opt_list_str(args, "assert_json"),
        report_out=_getattr_opt_str(args, "report_out"),
        iterations=_resolve_iterations(args, toml),
        duration=_resolve_opt_str("duration", args, toml),
        mode=_resolve_str("mode", args, toml),
        vus=_resolve_int("vus", args, toml),
        workers=_resolve_int("workers", args, toml),
        auto_correlate=_resolve_bool("auto_correlate", args, toml),
        correlate=getattr(args, "correlate", None),
        ramp_up=_resolve_str("ramp_up", args, toml),
        timeout=_resolve_str("timeout", args, toml),
        think_time=_resolve_str("think_time", args, toml),
        think_time_scale=_resolve_float("think_time_scale", args, toml),
        login_path=_resolve_str("login_path", args, toml),
        register_path=_resolve_str("register_path", args, toml),
        auto_register=_resolve_bool("auto_register", args, toml),
        auth_delay=_resolve_float("auth_delay", args, toml),
        auth_batch_size=_resolve_int("auth_batch_size", args, toml),
        auth_batch_delay=_resolve_float("auth_batch_delay", args, toml),
        skip_failed_accounts=_resolve_bool("skip_failed_accounts", args, toml),
        accounts=_resolve("accounts", args, toml),
        param=getattr(args, "param", None),
        include_static=_resolve_bool("include_static", args, toml),
        rps=_resolve_float("rps", args, toml),
        open_loop=_resolve_bool("open_loop", args, toml),
        step_load=_resolve_bool("step_load", args, toml),
        step_vus=_resolve_int("step_vus", args, toml),
        step_duration=_resolve_str("step_duration", args, toml),
        step_max_vus=_resolve_int("step_max_vus", args, toml),
        max_samples=_resolve_int("max_samples", args, toml),
        csrf=_resolve_bool("csrf", args, toml),
        body_check=_resolve_bool("body_check", args, toml),
        infra_block_threshold=_resolve_int("infra_block_threshold", args, toml),
        proxy_pool=_resolve_opt_str("proxy_pool", args, toml),
        check_shape=_resolve_bool("check_shape", args, toml),
        fail_on_shape_drift=_resolve_bool("fail_on_shape_drift", args, toml),
        fail_on_error_rate=_resolve_opt_float("fail_on_error_rate", args, toml),
        fail_on_p95=_fail_p95[0],
        fail_on_p99=_fail_p99[0],
        fail_on_p95_scoped=_fail_p95[1],
        fail_on_p99_scoped=_fail_p99[1],
        health_check=_resolve_opt_str("health_check", args, toml),
        poll_until=getattr(args, "poll_until", None),
        poll_error_until=getattr(args, "poll_error_until", None),
        poll_timeout=_resolve_str("poll_timeout", args, toml),
        poll_interval=_resolve_opt_str("poll_interval", args, toml),
        abort_on_fail=_resolve_bool("abort_on_fail", args, toml),
        threshold_start_delay=_resolve_str("threshold_start_delay", args, toml),
        report_format=_resolve_str("report_format", args, toml),
        debug=_resolve_bool("debug", args, toml),
        apdex_t=_resolve_float("apdex_t", args, toml),
    );
}
