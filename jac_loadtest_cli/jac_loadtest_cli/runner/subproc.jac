"""Run a Locust load test in a child process; safe to call from a web server.

Locust patches the standard library with gevent at import time, which a host
process (the web app's worker threads, an asyncio service) must not have done to
it. So the host calls run_in_subprocess(), which keeps the same
(config, on_snapshot, stop_event, on_html_report) shape run_test_headless had
and never imports Locust itself.
"""

import os;
import sys;
import json;
import time;
import shutil;
import tempfile;
import subprocess;
import from ..config { LoadTestConfig }
import from .configio { dump_config }

# `import jaclang` installs the import hook that makes .jac modules importable.
glob _BOOT: str = "import jaclang, sys; from jac_loadtest_cli.runner.child import child_main; sys.exit(child_main(sys.argv[1]))";

def run_in_subprocess(
    config: LoadTestConfig,
    on_snapshot: any = None,
    stop_event: any = None,
    on_html_report: any = None,
) -> dict[str, any] {
    workdir = tempfile.mkdtemp(prefix="jac-loadtest-");
    try {
        dump_config(config, os.path.join(workdir, "config.json"));
        proc = subprocess.Popen(
            [sys.executable, "-c", _BOOT, workdir],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        );
        tail: list[str] = [];
        stop_file = os.path.join(workdir, "stop");
        # Stop requests are polled from a thread-free loop: readline blocks only
        # until the child's next line, and snapshots arrive every few seconds, so
        # also check between lines. A child with nothing to say still exits on
        # its own duration/iterations.
        import threading;
        def _watch_stop() -> None {
            while proc.poll() is None {
                if stop_event is not None and stop_event.is_set() {
                    open(stop_file, "w").close();
                    return;
                }
                time.sleep(0.2);
            }
        }
        watcher = threading.Thread(target=_watch_stop, daemon=True);
        watcher.start();
        for line in proc.stdout {
            if line.startswith("SNAP ") {
                if on_snapshot is not None {
                    d = json.loads(line[5:]);
                    from_snap = _SnapView(d);
                    on_snapshot(from_snap);
                }
            } else {
                tail.append(line.rstrip());
                tail = tail[-30:];
            }
        }
        code = proc.wait();
        report_path = os.path.join(workdir, "report.json");
        if code != 0 or not os.path.exists(report_path) {
            raise RuntimeError(
                f"load-test process exited with {code}: " + " | ".join(tail[-8:])
            );
        }
        data = json.load(open(report_path));
        if on_html_report is not None {
            html_path = os.path.join(workdir, "report.html");
            if os.path.exists(html_path) {
                on_html_report(open(html_path).read());
            }
        }
        return data;
    } finally {
        shutil.rmtree(workdir, ignore_errors=True);
    }
}

class _SnapView {
    def init(self: _SnapView, d: dict[str, any]) {
        for (k, v) in d.items() {
            setattr(self, k, v);
        }
    }
}
