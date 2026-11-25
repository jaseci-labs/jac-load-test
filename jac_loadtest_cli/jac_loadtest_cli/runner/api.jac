"""One call that runs a load test and returns every report.

execute() is what the CLI, the headless embedder and the subprocess child all
share. It imports Locust (through environment.jac), so importing this module
monkey-patches the standard library with gevent: only import it in a process
that is meant to be a load-test process.
"""

import from locust.html { get_html_report }
import from ..config { LoadTestConfig }
import from ..output.json_report { build_report }
import from ..output.thresholds { evaluate }
import from .environment { run_locust, RunHandle }

obj Outcome {
    has result: dict[str, any];
    has html: str = "";
    has breaches: list[str] = [];
    has ended_by: str = "";
}

def execute(
    config: LoadTestConfig,
    stop_event: any = None,
    on_snapshot: any = None,
    want_html: bool = False,
) -> Outcome {
    h = run_locust(config, stop_event=stop_event, on_snapshot=on_snapshot);
    result = build_report(
        h.env, config, h.wall_s, h.snapshots, h.context.auth_failures,
        h.context.suspects, h.started_at, h.steps,
    );
    html = "";
    if want_html {
        html = str(get_html_report(h.env, show_download_link=False));
    }
    return Outcome(
        result=result,
        html=html,
        breaches=evaluate(config, result),
        ended_by=h.ended_by,
    );
}
