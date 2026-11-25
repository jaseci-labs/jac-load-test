"""Child-process entry: run one load test and hand the result back through files.

The parent (runner/subproc.jac) starts this in its own interpreter so Locust's
gevent monkey-patching never touches the parent. Protocol, all under <dir>:
  config.json   in   the run configuration
  stop          in   its existence asks the run to stop
  report.json   out  the JSON report
  report.html   out  Locust's HTML report
  stdout        out  one `SNAP {json}` line per live snapshot
"""

import os;
import sys;
import json;
import from .configio { load_config }
import from .api { execute }

obj FileStop {
    has path: str;

    def is_set() -> bool {
        return os.path.exists(self.path);
    }
}

def _emit(snap: any) -> None {
    print("SNAP " + json.dumps({k: getattr(snap, k) for k in ("timestamp", "total_requests", "p50_ms", "p95_ms", "p99_ms", "rps", "error_rate_pct")}), flush=True);
}

def child_main(workdir: str) -> int {
    cfg = load_config(os.path.join(workdir, "config.json"));
    out = execute(
        cfg,
        stop_event=FileStop(path=os.path.join(workdir, "stop")),
        on_snapshot=_emit,
        want_html=True,
    );
    with open(os.path.join(workdir, "report.json"), "w") as f {
        json.dump({"report": out.result, "breaches": out.breaches, "ended_by": out.ended_by}, f);
    }
    with open(os.path.join(workdir, "report.html"), "w") as f {
        f.write(out.html);
    }
    return 0;
}

with entry {
    if len(sys.argv) > 1 and __name__ == "__main__" {
        sys.exit(child_main(sys.argv[1]));
    }
}
