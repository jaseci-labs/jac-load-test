"""Registers `jac loadtest` with jaclang's CommandRegistry at module import time.

The @registry.command decorator fires when this module is imported (which happens
when jaclang loads this entry-point). The JacLoadtestCmd class is a marker that
the entry-point points to — importing it is what matters, not instantiating it.
"""
from jaclang.cli.registry import get_registry
from jaclang.cli.command import Arg, ArgKind

registry = get_registry()


@registry.command(
    name="loadtest",
    help="HAR-based load testing for jac-scale apps",
    args=[
        Arg.create("har_file", kind=ArgKind.POSITIONAL, help="Path to .har file"),
        Arg.create("url", typ=str, default=None, short="",
                   help="Target base URL (e.g. http://localhost:8000)"),
        Arg.create("mode", typ=str, default="monolith", short="",
                   help="Deployment mode: monolith or microservice"),
        Arg.create("vus", typ=int, default=1, short="",
                   help="Number of virtual users"),
        Arg.create("duration", typ=str, default="30s", short="",
                   help="Test duration (e.g. 30s, 2m, 1h)"),
        Arg.create("iterations", typ=int, default=None, short="",
                   help="Iteration cap per VU (alternative to --duration)"),
        Arg.create("ramp-up", typ=str, default="0s", short="",
                   help="Time to ramp up to full VU count"),
        Arg.create("timeout", typ=str, default="30s", short="",
                   help="Per-request timeout"),
        Arg.create("think-time", typ=str, default="none", short="",
                   help="Inter-request delay: none, real, or scaled"),
        Arg.create("think-time-scale", typ=float, default=1.0, short="",
                   help="Multiplier when --think-time scaled"),
        Arg.create("username", typ=str, default=None, short="",
                   help="Username for shared-credential auth"),
        Arg.create("password", typ=str, default=None, short="",
                   help="Password for shared-credential auth"),
        Arg.create("credentials-file", typ=str, default=None, short="",
                   help="CSV file with username,password rows (one per VU)"),
        Arg.create("login-path", typ=str, default="/user/login", short="",
                   help="URL path detected as the login entry"),
        Arg.create("include-static", typ=bool, default=False, short="",
                   help="Do not skip image/font/CSS entries"),
        Arg.create("rps", typ=int, default=0, short="",
                   help="Global requests-per-second cap (0 = unlimited)"),
        Arg.create("max-samples", typ=int, default=1_000_000, short="",
                   help="Max raw request records kept in memory for percentile calc"),
        Arg.create("services-map", typ=str, default=None, short="",
                   help='JSON map of service name to URL e.g. \'{"svc":"http://host:port"}\''),
        Arg.create("csrf", typ=bool, default=False, short="",
                   help="Enable CSRF token detection and injection"),
        Arg.create("fail-on-error-rate", typ=float, default=None, short="",
                   help="Exit 1 if error rate exceeds N percent"),
        Arg.create("fail-on-p95", typ=float, default=None, short="",
                   help="Exit 1 if p95 latency exceeds N milliseconds"),
        Arg.create("fail-on-p99", typ=float, default=None, short="",
                   help="Exit 1 if p99 latency exceeds N milliseconds"),
        Arg.create("abort-on-fail", typ=bool, default=False, short="",
                   help="Stop test immediately when any threshold is breached"),
        Arg.create("threshold-start-delay", typ=str, default="0s", short="",
                   help="Delay threshold evaluation N seconds from test start"),
        Arg.create("report-format", typ=str, default="console", short="",
                   help="Output format: console, json, or html"),
        Arg.create("report-out", typ=str, default=None, short="",
                   help="Output file path for json/html reports"),
        Arg.create("debug", typ=bool, default=False, short="",
                   help="Print each request and response status to stderr during run"),
    ],
    group="testing",
    source="jac-loadtest",
)
def loadtest(args: object) -> None:
    from jac_loadtest.cli import run
    run(args)
