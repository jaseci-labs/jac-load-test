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
    "include_static": False,
    "login_path": "/user/login",
    "fail_on_error_rate": None,
    "fail_on_p95": None,
    "fail_on_p99": None,
    "abort_on_fail": False,
    "threshold_start_delay": "0s",
    "report_format": "console",
    "max_samples": 1_000_000,
    "csrf": False,
    "debug": False,
    "apdex_t": 500.0,
};

obj LoadTestConfig {
    has vus: int = 1;
    has iterations: int = 1;
    has ramp_up: str = "0s";
    has timeout: str = "30s";
    has workers: int = 1;
    has mode: str = "monolith";
    has think_time: str = "none";
    has think_time_scale: float = 1.0;
    has rps: int = 0;
    has include_static: bool = False;
    has login_path: str = "/user/login";
    has csrf: bool = False;
    has fail_on_error_rate: float | None = None;
    has fail_on_p95: float | None = None;
    has fail_on_p99: float | None = None;
    has abort_on_fail: bool = False;
    has threshold_start_delay: str = "0s";
    has report_format: str = "console";
    has max_samples: int = 1_000_000;
    has debug: bool = False;
    has apdex_t: float = 500.0;
    has har_file: str = "";
    has url: str | None = None;
    has username: str | None = None;
    has password: str | None = None;
    has services_map: str | None = None;
    has report_out: str | None = None;
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
        import from jac_scale.config_loader { get_scale_config, reset_scale_config }
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

def from_args(args: object) -> LoadTestConfig {
    toml = _load_toml_defaults();
    return LoadTestConfig(
        har_file=_getattr_str(args, "har_file", ""),
        url=_getattr_opt_str(args, "url"),
        username=_getattr_opt_str(args, "username"),
        password=_getattr_opt_str(args, "password"),
        services_map=_getattr_opt_str(args, "services_map"),
        report_out=_getattr_opt_str(args, "report_out"),
        iterations=_resolve_int("iterations", args, toml),
        mode=_resolve_str("mode", args, toml),
        vus=_resolve_int("vus", args, toml),
        workers=_resolve_int("workers", args, toml),
        ramp_up=_resolve_str("ramp_up", args, toml),
        timeout=_resolve_str("timeout", args, toml),
        think_time=_resolve_str("think_time", args, toml),
        think_time_scale=_resolve_float("think_time_scale", args, toml),
        login_path=_resolve_str("login_path", args, toml),
        include_static=_resolve_bool("include_static", args, toml),
        rps=_resolve_int("rps", args, toml),
        max_samples=_resolve_int("max_samples", args, toml),
        csrf=_resolve_bool("csrf", args, toml),
        fail_on_error_rate=_resolve_opt_float("fail_on_error_rate", args, toml),
        fail_on_p95=_resolve_opt_float("fail_on_p95", args, toml),
        fail_on_p99=_resolve_opt_float("fail_on_p99", args, toml),
        abort_on_fail=_resolve_bool("abort_on_fail", args, toml),
        threshold_start_delay=_resolve_str("threshold_start_delay", args, toml),
        report_format=_resolve_str("report_format", args, toml),
        debug=_resolve_bool("debug", args, toml),
        apdex_t=_resolve_float("apdex_t", args, toml),
    );
}
