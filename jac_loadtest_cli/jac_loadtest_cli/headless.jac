"""Canonical headless entry point -- no CLI context required.

Unlike cli.jac (argparse, console output, sys.exit), this module raises plain
exceptions and returns plain data. It exists so an embedder such as the web app
can run a full load test and get a JSON-serialisable report back.

The test runs in a child process (runner/subproc.jac): Locust patches the
standard library with gevent when imported, which an embedding process must not
have done to it. This module therefore never imports Locust itself.
"""

import from .config { LoadTestConfig }
import from .runner.subproc { run_in_subprocess }

def run_test_headless(
    config: LoadTestConfig,
    on_snapshot: any = None,
    stop_event: any = None,
    on_html_report: any = None,
) -> dict[str, any] {
    # Returns the JSON report (meta, summary, endpoints, step_load, ...). The
    # threshold verdict is under "breaches" in the subprocess payload, so embedders
    # that want it can call run_in_subprocess directly.
    data = run_in_subprocess(
        config, on_snapshot=on_snapshot, stop_event=stop_event, on_html_report=on_html_report
    );
    return data["report"];
}
