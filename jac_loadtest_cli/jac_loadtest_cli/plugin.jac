import sys;
import argparse;

def _int(s: str) -> int {
    return int(s);
}

def _float(s: str) -> float {
    return float(s);
}

def build_parser -> argparse.ArgumentParser {
    parser = argparse.ArgumentParser(
        prog="jac x loadtest",
        description="HAR-based load testing for jac-scale apps",
    );
    parser.add_argument("har_file", help="Path to .har file");
    parser.add_argument("--url", default=None, help="Target base URL (e.g. http://localhost:8000)");
    parser.add_argument("--mode", default=None, help="Deployment mode: monolith or microservice");
    parser.add_argument("--vus", type=_int, default=None, help="Number of virtual users");
    parser.add_argument("--workers", type=_int, default=None, help="Number of worker processes (default: CPU core count)");
    parser.add_argument("--iterations", type=_int, default=None, help="Stop each VU after N complete HAR replays (default: 1)");
    parser.add_argument("--ramp-up", dest="ramp_up", default=None, help="Time to ramp up to full VU count");
    parser.add_argument("--timeout", default=None, help="Per-request timeout");
    parser.add_argument("--think-time", dest="think_time", default=None, help="Inter-request delay: none, real, or scaled");
    parser.add_argument("--think-time-scale", dest="think_time_scale", type=_float, default=None, help="Multiplier when --think-time scaled");
    parser.add_argument("--username", default=None, help="Username for shared-credential auth");
    parser.add_argument("--password", default=None, help="Password for shared-credential auth");
    parser.add_argument("--login-path", dest="login_path", default=None, help="URL path detected as the login entry");
    parser.add_argument("--include-static", dest="include_static", action="store_true", default=None, help="Do not skip image/font/CSS entries");
    parser.add_argument("--rps", type=_int, default=None, help="Global requests-per-second cap (0 = unlimited)");
    parser.add_argument("--max-samples", dest="max_samples", type=_int, default=None, help="Max raw request records kept in memory for percentile calc");
    parser.add_argument("--services-map", dest="services_map", default=None, help='JSON map of service name to URL e.g. \'{"svc":"http://host:port"}\'');
    parser.add_argument("--csrf", action="store_true", default=None, help="Reserved for future CSRF token detection and injection; currently accepted but has no effect");
    parser.add_argument("--fail-on-error-rate", dest="fail_on_error_rate", type=_float, default=None, help="Exit 1 if error rate exceeds N percent");
    parser.add_argument("--fail-on-p95", dest="fail_on_p95", type=_float, default=None, help="Exit 1 if p95 latency exceeds N milliseconds");
    parser.add_argument("--fail-on-p99", dest="fail_on_p99", type=_float, default=None, help="Exit 1 if p99 latency exceeds N milliseconds");
    parser.add_argument("--abort-on-fail", dest="abort_on_fail", action="store_true", default=None, help="Stop test immediately when any threshold is breached");
    parser.add_argument("--threshold-start-delay", dest="threshold_start_delay", default=None, help="Delay threshold evaluation N seconds from test start");
    parser.add_argument("--report-format", dest="report_format", default=None, help="Output format: console, json, or html");
    parser.add_argument("--report-out", dest="report_out", default=None, help="Output file path for json/html reports");
    parser.add_argument("--debug", action="store_true", default=None, help="Print each request and response status to stderr during run");
    parser.add_argument("--apdex-t", dest="apdex_t", type=_float, default=None, help="Apdex satisfaction threshold in ms (default: 500). Satisfied <= T, Tolerating <= 4T, Frustrated > 4T or error");
    return parser;
}

def main {
    import from .cli { run }
    parser = build_parser();
    args = parser.parse_args(sys.argv[1:]);
    run(args);
}
