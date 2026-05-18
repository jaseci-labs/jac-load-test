"""LoadTestConfig — three-layer resolution: jac.toml → CLI flags → built-in defaults.

Phase 0: dataclass with built-in defaults only.
Phase 2 will add jac.toml reading via jac_scale.config_loader.
"""
from __future__ import annotations
from dataclasses import dataclass, field


BUILT_IN_DEFAULTS: dict = {
    "vus": 1,
    "duration": "30s",
    "ramp_up": "0s",
    "timeout": "30s",
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
}


@dataclass
class LoadTestConfig:
    # Load shape
    vus: int = 1
    duration: str = "30s"
    iterations: int | None = None
    ramp_up: str = "0s"
    timeout: str = "30s"

    # Traffic
    mode: str = "monolith"
    think_time: str = "none"
    think_time_scale: float = 1.0
    rps: int = 0
    include_static: bool = False

    # Auth
    login_path: str = "/user/login"
    csrf: bool = False

    # CI thresholds
    fail_on_error_rate: float | None = None
    fail_on_p95: float | None = None
    fail_on_p99: float | None = None
    abort_on_fail: bool = False
    threshold_start_delay: str = "0s"

    # Output
    report_format: str = "console"
    max_samples: int = 1_000_000
    debug: bool = False

    # CLI-only — not sourced from jac.toml (environment-specific or security-sensitive)
    har_file: str = ""
    url: str | None = None
    username: str | None = None
    password: str | None = None
    credentials_file: str | None = None
    services_map: str | None = None
    report_out: str | None = None


def from_args(args: object) -> LoadTestConfig:
    """Build LoadTestConfig by applying CLI args on top of built-in defaults.

    Phase 2 will insert a jac.toml layer between defaults and CLI args.
    """
    def get(name: str, default=None):
        return getattr(args, name, default)

    return LoadTestConfig(
        har_file=get("har_file", ""),
        url=get("url"),
        mode=get("mode", BUILT_IN_DEFAULTS["mode"]),
        vus=get("vus", BUILT_IN_DEFAULTS["vus"]),
        duration=get("duration", BUILT_IN_DEFAULTS["duration"]),
        iterations=get("iterations"),
        ramp_up=get("ramp_up", BUILT_IN_DEFAULTS["ramp_up"]),
        timeout=get("timeout", BUILT_IN_DEFAULTS["timeout"]),
        think_time=get("think_time", BUILT_IN_DEFAULTS["think_time"]),
        think_time_scale=get("think_time_scale", BUILT_IN_DEFAULTS["think_time_scale"]),
        username=get("username"),
        password=get("password"),
        credentials_file=get("credentials_file"),
        login_path=get("login_path", BUILT_IN_DEFAULTS["login_path"]),
        include_static=get("include_static", BUILT_IN_DEFAULTS["include_static"]),
        rps=get("rps", BUILT_IN_DEFAULTS["rps"]),
        max_samples=get("max_samples", BUILT_IN_DEFAULTS["max_samples"]),
        services_map=get("services_map"),
        csrf=get("csrf", BUILT_IN_DEFAULTS["csrf"]),
        fail_on_error_rate=get("fail_on_error_rate"),
        fail_on_p95=get("fail_on_p95"),
        fail_on_p99=get("fail_on_p99"),
        abort_on_fail=get("abort_on_fail", BUILT_IN_DEFAULTS["abort_on_fail"]),
        threshold_start_delay=get("threshold_start_delay", BUILT_IN_DEFAULTS["threshold_start_delay"]),
        report_format=get("report_format", BUILT_IN_DEFAULTS["report_format"]),
        report_out=get("report_out"),
        debug=get("debug", BUILT_IN_DEFAULTS["debug"]),
    )
