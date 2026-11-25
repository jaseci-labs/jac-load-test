"""`jac x loadtest` command: flags in, Locust run, reports and exit code out.

Locust does the load generation, scheduling, statistics and the console and HTML
reports. This module only parses flags, runs the test, writes our JSON report and
turns threshold breaches into the exit code.

Locust is imported only when a run starts (inside run()), never at module load:
importing it monkey-patches the standard library, and every other `jac` command
would pay for that.
"""

import sys;
import json;
import from .config { from_args, LoadTestConfig }

def _fail(message: str) -> None {
    print(f"Error: {message}", file=sys.stderr);
    sys.exit(2);
}

def run(args: object) {
    try {
        config: LoadTestConfig = from_args(args);
    } except ValueError as exc {
        _fail(str(exc));
    }

    if config.mode == "monolith" and not config.url {
        _fail("--url is required for monolith mode");
    }
    if not config.har_file {
        _fail("har_file positional argument is required");
    }
    if config.health_check {
        if not config.url {
            _fail("--health-check requires --url");
        }
        if not config.health_check.startswith("/") {
            _fail(
                f"--health-check '{config.health_check}' must start with '/', "
                "e.g. '/healthz/live'"
            );
        }
    }
    fmt = config.report_format;
    if fmt == "html" and not config.report_out {
        _fail("--report-out <path> is required for --report-format html");
    }

    import from .runner.api { execute, print_console_report }
    try {
        out = execute(config, want_html=(fmt == "html"));
    } except (FileNotFoundError, OSError, ValueError) as exc {
        _fail(str(exc));
    }

    if out.auth_failures and not config.skip_failed_accounts {
        for (account, reason) in out.auth_failures {
            print(f"Error: {reason}", file=sys.stderr);
        }
        sys.exit(2);
    }

    if fmt == "json" {
        text = json.dumps(out.result, indent=2);
        if config.report_out {
            with open(config.report_out, "w", encoding="utf-8") as fh {
                fh.write(text);
            }
            print(f"JSON report written to {config.report_out}");
        } else {
            print(text);
        }
    } elif fmt == "html" {
        with open(str(config.report_out), "w", encoding="utf-8") as fh {
            fh.write(out.html);
        }
        print(f"HTML report written to {config.report_out}", file=sys.stderr);
    } else {
        print_console_report(out.env);
        summary = out.result["summary"];
        print(
            f"\nTotal: {summary['total_requests']} requests, "
            f"{summary['error_count']} errors, "
            f"{summary['infra_block_count']} infra-blocked, "
            f"p95 {summary['p95_ms']} ms"
        );
        if out.result["capacity_knee_vus"] is not None {
            print(f"Capacity knee: {out.result['capacity_knee_vus']} VUs");
        }
    }

    if out.breaches {
        for msg in out.breaches {
            print(f"THRESHOLD FAILED: {msg}", file=sys.stderr);
        }
        sys.exit(1);
    }
}
