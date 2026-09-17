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
    parser.add_argument("har_file", nargs="?", default=None, help="Path to .har file. Omit when using --spec.");
    parser.add_argument(
        "--spec", dest="spec", default=None, metavar="SOURCE",
        help=(
            "Load test directly from an OpenAPI 3.0/3.1 or Swagger 2.0 document (URL or "
            "local file, JSON or YAML) instead of a recorded .har file -- one entry per "
            "operation, parsed straight into memory (see 'jac x loadtest from-spec' to "
            "write it out as a .har instead). Mutually exclusive with har_file."
        ),
    );
    parser.add_argument("--url", default=None, help="Target base URL (e.g. http://localhost:8000)");
    parser.add_argument(
        "--health-check", dest="health_check", default=None, metavar="PATH",
        help=(
            "Fire one extra unauthenticated GET request to PATH (e.g. "
            "'/healthz/live'), against --url, once per VU per completed "
            "iteration -- alongside the HAR replay, not part of it. Reported "
            "as its own row in the endpoint table and excluded from the run's "
            "global/TOTAL aggregates, so it can be gated independently with "
            "--fail-on-p95/--fail-on-p99's 'ENDPOINT:MS' scoped form (e.g. "
            "--fail-on-p99 '/healthz/live:100') without diluting, or being "
            "diluted by, the rest of the traffic mix. Requires --url."
        ),
    );
    parser.add_argument("--mode", default=None, help="Deployment mode: monolith or microservice");
    parser.add_argument("--vus", type=_int, default=None, help="Number of virtual users");
    parser.add_argument("--workers", type=_int, default=None, help="Number of worker processes (default: CPU core count)");
    parser.add_argument("--iterations", type=_int, default=None, help="Stop each VU after N complete HAR replays (default: 1)");
    parser.add_argument(
        "--duration", default=None,
        help=(
            "Hard wall-clock cutoff for the whole run (e.g. 60s, 5m) — stops all "
            "VUs once elapsed, regardless of --iterations. If set without an "
            "explicit --iterations, VUs loop until the duration elapses instead "
            "of stopping after 1 replay. Not compatible with --step-load, which "
            "has its own step-based timing."
        ),
    );
    parser.add_argument("--ramp-up", dest="ramp_up", default=None, help="Time to ramp up to full VU count");
    parser.add_argument("--timeout", default=None, help="Per-request timeout");
    parser.add_argument("--think-time", dest="think_time", default=None, help="Inter-request delay: none, real, or scaled");
    parser.add_argument("--think-time-scale", dest="think_time_scale", type=_float, default=None, help="Multiplier when --think-time scaled");
    parser.add_argument(
        "--accounts", dest="accounts", default=None, metavar="MAP_OR_FILE",
        help=(
            "Per-VU account pool. Each VU is assigned one account, logs in as that "
            "identity before the replay loop, and replays with its own token — so N "
            "VUs exercise N root graphs instead of contending on one. Accepts an "
            'inline JSON map \'{"alice":"pw1","bob":"pw2"}\' (same shape as '
            "--services-map), an inline JSON array of {username,password} objects, or "
            "a path to a .json or .csv file. VUs are assigned round-robin when there "
            "are more VUs than accounts. If a login returns 401 and the account turns "
            "out not to exist, it is registered via --register-path and the login is "
            "retried; a 401 on an account that DOES exist is reported as a wrong "
            "password, never re-registered. NOTE: an inline map puts passwords in your "
            "shell history and in `ps` output — prefer a file outside a shared machine."
        ),
    );
    parser.add_argument(
        "--username", default=None,
        help=(
            "Single shared credential. Superseded by --accounts, which covers this as "
            "a one-entry pool; kept working so existing scripts and jac.toml files do "
            "not break."
        ),
    );
    parser.add_argument(
        "--password", default=None,
        help="Password for --username. See --accounts for the per-VU pool.",
    );
    parser.add_argument("--login-path", dest="login_path", default=None, help="URL path detected as the login entry");
    parser.add_argument(
        "--register-path", dest="register_path", default=None,
        help=(
            "Path used to create an account that does not exist yet "
            "(default: /user/register, jac-scale's built-in signup endpoint). Only "
            "reached after a login 401s and the account is confirmed missing."
        ),
    );
    parser.add_argument(
        "--skip-failed-accounts", dest="skip_failed_accounts", action="store_true", default=None,
        help=(
            "Continue when some accounts in --accounts cannot authenticate, instead "
            "of aborting. The requested VU count is preserved: VUs are re-spread "
            "over the accounts that did authenticate, so concurrency is unchanged "
            "and only identity diversity degrades. The report states how many "
            "accounts were lost and why. The run still aborts if NO account "
            "authenticates, since that is a misconfiguration rather than a bad row. "
            "Off by default \u2014 in CI a bad credential should fail the build."
        ),
    );
    parser.add_argument(
        "--no-auto-register", dest="auto_register", action="store_false", default=None,
        help=(
            "Never create accounts. A login failure for a missing account is then "
            "reported as a failure instead of being registered and retried."
        ),
    );
    parser.add_argument(
        "--auth-delay", dest="auth_delay", type=_float, default=None,
        help=(
            "Seconds to wait after each account's register/login during the "
            "pre-run auth burst, so a large --accounts pool doesn't trip the "
            "target's rate limiter or WAF (default: 0, no delay). Combine with "
            "--auth-batch-size/--auth-batch-delay for a windowed limit instead "
            "of a uniform one."
        ),
    );
    parser.add_argument(
        "--auth-batch-size", dest="auth_batch_size", type=_int, default=None,
        help=(
            "Pause for --auth-batch-delay after every N accounts during the "
            "pre-run auth burst, matching a windowed rate limit (e.g. '50 "
            "requests per minute') more directly than --auth-delay's uniform "
            "spacing. Requires --auth-batch-delay."
        ),
    );
    parser.add_argument(
        "--auth-batch-delay", dest="auth_batch_delay", type=_float, default=None,
        help="Seconds to pause between batches when --auth-batch-size is set.",
    );
    parser.add_argument("--include-static", dest="include_static", action="store_true", default=None, help="Do not skip image/font/CSS entries");
    parser.add_argument("--rps", type=_int, default=None, help="Global requests-per-second cap (0 = unlimited)");
    parser.add_argument(
        "--open-loop", dest="open_loop", action="store_true", default=None,
        help=(
            "Fixed-arrival-rate mode: launch new sessions at --rps regardless of "
            "response time, instead of pacing each VU by its own completions. "
            "Requires --rps > 0; concurrency grows unbounded if the target can't "
            "keep up, revealing true queueing instead of self-throttling."
        ),
    );
    parser.add_argument(
        "--step-load", dest="step_load", action="store_true", default=None,
        help=(
            "Step-load / ramp-to-failure mode: start at --vus, hold for "
            "--step-duration, add --step-vus more, repeat — until a --fail-on-* "
            "threshold breaches or --step-max-vus is reached. Finds the capacity "
            "knee instead of testing at one fixed VU count. Single-process only "
            "(--workers 1). Requires --step-vus and, if --step-max-vus is not "
            "set, at least one --fail-on-* threshold as the stopping condition."
        ),
    );
    parser.add_argument("--step-vus", dest="step_vus", type=_int, default=None, help="VUs added at each step in --step-load mode");
    parser.add_argument("--step-duration", dest="step_duration", default=None, help="How long to hold each step before evaluating thresholds and advancing (default: 30s)");
    parser.add_argument("--step-max-vus", dest="step_max_vus", type=_int, default=None, help="Ceiling on total VUs during --step-load ramp (0 = no ceiling; requires a --fail-on-* threshold instead)");
    parser.add_argument("--max-samples", dest="max_samples", type=_int, default=None, help="Max raw request records kept in memory for percentile calc");
    parser.add_argument("--services-map", dest="services_map", default=None, help='JSON map of service name to URL e.g. \'{"svc":"http://host:port"}\'');
    parser.add_argument(
        "--slo", dest="slo", default=None,
        help=(
            'Per-endpoint latency SLO overrides as JSON, e.g. '
            '\'{"/walker/chat": {"p95": {"good": 2000, "bad": 8000}}}\'. '
            "Endpoints or metrics not listed fall back to the built-in global "
            "thresholds (p50/p95/p99/p999 good/bad in ms) used for report ratings."
        ),
    );
    parser.add_argument(
        "--assert-json", dest="assert_json", action="append", default=None,
        metavar="PATH=VALUE",
        help=(
            "Require a JSON response-body field to equal a value for a request "
            "to count as successful (in addition to the status code), e.g. "
            "--assert-json 'ok=true'. Dotted path traverses objects/arrays, e.g. "
            "'reports.0.success'. Repeatable — all given assertions must pass. "
            "VALUE is parsed as JSON when possible (true/false/null/numbers), "
            "else compared as a literal string. Applies globally to every "
            "response in the run, not per-endpoint."
        ),
    );
    parser.add_argument(
        "--param", dest="param", action="append", default=None,
        metavar="RULE",
        help=(
            "Feed a request field from a file of values instead of replaying the "
            "recorded one: '<endpoint>.<target>=<file>', e.g. "
            "--param 'AddTodo.body.title=titles.csv'. Target is body.<json-path>, "
            "query.<name> or header.<name>. The file is one value per line, or "
            "'file.csv:column' to pick a named column from a CSV with a header. "
            "Rows advance with (vu_id, iteration), so a VU sees different data each "
            "pass and two VUs in the same pass differ. Repeatable. Without this, "
            "every VU replays identical bodies \u2014 which warms caches a real workload "
            "would miss and collides on unique fields."
        ),
    );
    parser.add_argument(
        "--correlate", dest="correlate", action="append", default=None,
        metavar="RULE",
        help=(
            "Thread a value from one response into a later request, per VU: "
            "'Producer.response.<path> -> Consumer.body.<path>'. Example: "
            "--correlate 'AddTodo.response.reports.0.id -> ToggleTodo.body.nd'. "
            "Endpoints may be named by walker ('AddTodo') or full path "
            "('/walker/AddTodo'). Source also accepts 'header.<name>'; target "
            "also accepts 'query.<name>' and 'path'. Repeatable. Use this for "
            "correlations the automatic scan cannot see — typically a value the "
            "recording uses only once, so there is no second occurrence to match."
        ),
    );
    parser.add_argument(
        "--no-auto-correlate", dest="auto_correlate", action="store_false", default=None,
        help=(
            "Disable automatic correlation detection. By default the recorded HAR "
            "is scanned at startup for values that a response hands to a later "
            "request (a server-generated id the browser copied forward) and those "
            "are threaded per-VU, so mixed create/update/delete workflows stop "
            "failing ownership checks on replay. The scan reads the file only — no "
            "extra requests. Turn it off to replay request bodies exactly as recorded."
        ),
    );
    parser.add_argument(
        "--infra-block-threshold", dest="infra_block_threshold", type=_int, default=None,
        metavar="N",
        help=(
            "How many distinct endpoints must return a byte-identical non-JSON body "
            "in the same time window before those responses are classified as "
            "INFRA_BLOCK_SUSPECTED rather than application errors (default 3). A WAF "
            "or rate limiter returns one canned deny page regardless of what was "
            "asked; an application failure is specific to the request. Blocked "
            "responses are counted separately and kept out of the headline error "
            "rate. Set below 2 to disable."
        ),
    );
    parser.add_argument(
        "--proxy-pool", dest="proxy_pool", default=None, metavar="FILE",
        help=(
            "File of proxy URLs (one per line, http:// or socks5://) to spread "
            "egress across, assigned per VU so each keeps one address and "
            "keep-alive still works. A partial mitigation for per-IP rate limits; "
            "real multi-IP comes from distributed workers."
        ),
    );
    parser.add_argument(
        "--no-body-check", dest="body_check", action="store_false", default=None,
        help=(
            "Stop treating a 200 that carries a jac-scale error envelope as a "
            "failure. By default a 200 is flagged APP_ERROR_IN_200 when it has an "
            "error/errors key, an inner status >= 400, or an empty 'reports' array "
            "where the recording for that endpoint had results \u2014 because on "
            "jac-scale a walker reports failure inside a 200, so status checking "
            "alone can report a 0 percent error rate while nothing works."
        ),
    );
    parser.add_argument(
        "--check-shape", dest="check_shape", action="store_true", default=None,
        help=(
            "Also flag SHAPE_DRIFT when a response is missing top-level keys the "
            "recording had. Softer than the body check \u2014 the response did not say "
            "it failed, it just looks different \u2014 so it is off by default and does "
            "not fail the run unless --fail-on-shape-drift is given."
        ),
    );
    parser.add_argument(
        "--fail-on-shape-drift", dest="fail_on_shape_drift", action="store_true", default=None,
        help="Exit non-zero when --check-shape finds structural divergence.",
    );
    parser.add_argument("--csrf", action="store_true", default=None, help="Detect a CSRF cookie (csrftoken or _csrf) in responses and inject it as an X-CSRFToken header on subsequent non-GET requests, per VU. Off by default.");
    parser.add_argument("--fail-on-error-rate", dest="fail_on_error_rate", type=_float, default=None, help="Exit 1 if error rate exceeds N percent");
    parser.add_argument(
        "--fail-on-p95", dest="fail_on_p95_values", action="append", default=None,
        metavar="MS or ENDPOINT:MS",
        help=(
            "Exit 1 if p95 latency exceeds N milliseconds. Repeatable. A bare "
            "number ('500') sets the global threshold, checked against all "
            "traffic combined -- unchanged from before this could be scoped. "
            "'ENDPOINT:MS' (e.g. '/healthz/live:100') instead scopes the "
            "threshold to that one endpoint's own p95 -- most useful for a "
            "side-channel endpoint added via --health-check, so it can be "
            "gated without diluting, or being diluted by, the rest of the "
            "traffic mix. At most one bare (global) value is allowed; any "
            "number of scoped ones can be combined with it or with each other."
        ),
    );
    parser.add_argument(
        "--fail-on-p99", dest="fail_on_p99_values", action="append", default=None,
        metavar="MS or ENDPOINT:MS",
        help=(
            "Exit 1 if p99 latency exceeds N milliseconds. See --fail-on-p95 "
            "for the repeatable bare-value / 'ENDPOINT:MS' scoped form."
        ),
    );
    parser.add_argument("--abort-on-fail", dest="abort_on_fail", action="store_true", default=None, help="Stop test immediately when any threshold is breached");
    parser.add_argument("--threshold-start-delay", dest="threshold_start_delay", default=None, help="Delay threshold evaluation N seconds from test start");
    parser.add_argument("--report-format", dest="report_format", default=None, help="Output format: console, json, or html");
    parser.add_argument("--report-out", dest="report_out", default=None, help="Output file path for json/html reports");
    parser.add_argument("--debug", action="store_true", default=None, help="Print each request and response status to stderr during run");
    parser.add_argument("--apdex-t", dest="apdex_t", type=_float, default=None, help="Apdex satisfaction threshold in ms (default: 500). Satisfied <= T, Tolerating <= 4T, Frustrated > 4T or error");
    return parser;
}

def main {
    import from .cli { run, run_from_spec }
    # `from-spec` is its own subcommand with a different shape (spec source +
    # --out, no load-test flags) — dispatched before build_parser() sees it so
    # the flat `jac x loadtest <har_file> ...` parser stays untouched.
    if len(sys.argv) > 1 and sys.argv[1] == "from-spec" {
        run_from_spec(sys.argv[2:]);
        return;
    }
    parser = build_parser();
    args = parser.parse_args(sys.argv[1:]);
    run(args);
}
