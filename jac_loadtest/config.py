"""LoadTestConfig — three-layer resolution: jac.toml → CLI flags → built-in defaults.

Phase 0: dataclass with built-in defaults only.
Phase 2 will add jac.toml reading via jac_scale.config_loader.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


BUILT_IN_DEFAULTS: dict = {
    "vus": 1,
    "duration": "30s",
    "iterations": 1,
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
    iterations: int  = 1
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


def parse_duration(s: str) -> float:
    """Convert a duration string ('30s', '2m', '1h') to seconds."""
    s = s.strip()
    if s.endswith("h"):
        return float(s[:-1]) * 3600
    if s.endswith("m"):
        return float(s[:-1]) * 60
    if s.endswith("s"):
        return float(s[:-1])
    return float(s)


def _load_toml_defaults() -> dict:
    """Read [plugins.scale.loadtest] from jac.toml using jac-scale's native config API.

    Returns an empty dict if jac.toml is absent, the section is missing, or
    the import fails (e.g. jac-scale not installed in a minimal test env).
    """
    try:
        from pathlib import Path
        from jac_scale.config_loader import get_scale_config, reset_scale_config
        reset_scale_config()
        scale_config = get_scale_config(project_dir=Path.cwd())
        return scale_config.get_section("loadtest")
    except Exception:
        return {}


def from_args(args: object) -> LoadTestConfig:
    """Build LoadTestConfig using three-layer resolution: CLI > jac.toml > built-in defaults."""
    toml = _load_toml_defaults()

    # For toml-sourced fields, use CLI value if provided (not None), else toml value,
    # else built-in default.
    def resolve(name: str) -> Any:
        cli_val = getattr(args, name, None)
        if cli_val is not None:
            return cli_val
        if name in toml:
            return toml[name]
        return BUILT_IN_DEFAULTS.get(name)

    return LoadTestConfig(
        # CLI-only fields: not sourced from jac.toml
        har_file=getattr(args, "har_file", "") or "",
        url=getattr(args, "url", None),
        username=getattr(args, "username", None),
        password=getattr(args, "password", None),
        credentials_file=getattr(args, "credentials_file", None),
        services_map=getattr(args, "services_map", None),
        report_out=getattr(args, "report_out", None),
        # Three-layer resolved fields
        iterations=resolve("iterations"),
        mode=resolve("mode"),
        vus=resolve("vus"),
        duration=resolve("duration"),
        ramp_up=resolve("ramp_up"),
        timeout=resolve("timeout"),
        think_time=resolve("think_time"),
        think_time_scale=resolve("think_time_scale"),
        login_path=resolve("login_path"),
        include_static=resolve("include_static"),
        rps=resolve("rps"),
        max_samples=resolve("max_samples"),
        csrf=resolve("csrf"),
        fail_on_error_rate=resolve("fail_on_error_rate"),
        fail_on_p95=resolve("fail_on_p95"),
        fail_on_p99=resolve("fail_on_p99"),
        abort_on_fail=resolve("abort_on_fail"),
        threshold_start_delay=resolve("threshold_start_delay"),
        report_format=resolve("report_format"),
        debug=resolve("debug"),
    )
