"""Load-test run walkers.

Runs the CLI engine (jac_loadtest_cli) in-process via run_test_headless().
Per-run bookkeeping (the SSE snapshot queue and the stop signal) lives in
module-level globs keyed by run_id — fine for a single-process dev/small
deployment; a multi-replica production deployment would need a shared
store (Redis) instead.
"""

import os;
import json;
import queue;
import tempfile;
import multiprocessing;
import from datetime { datetime, UTC }
import from jaclang.jac0core.constructs { Root }
import from models.run { LoadTestRun }
import from models.workspace { Workspace }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.headless { run_test_headless }

# run_id -> queue.Queue of snapshot dicts (consumed by stream_metrics's SSE loop).
# A plain thread-safe queue.Queue rather than asyncio.Queue: jac-scale runs each
# walker ability via asyncio.to_thread(), so the ability body executing here has
# no event loop of its own to bind an asyncio.Queue (or call_soon_threadsafe) to.
glob _stream_queues: dict[str, object] = {};
# run_id -> multiprocessing.Event, flipped by stop_run to request early shutdown
glob _stop_events: dict[str, object] = {};
# run_id -> flow future; kept alive purely so the background task isn't GC'd early
glob _background_futures: dict[str, object] = {};

# jobj() resolves regardless of ownership — it would let any authenticated user
# reach another user's run/workspace by guessing an id. Both node types hang
# directly off `root`, so scoping the search to [root --> ] is both correct and
# an ownership check for free.
def _find_run(run_id: str) -> LoadTestRun | None {
    for r in [root --> ][?:LoadTestRun] {
        if jid(r) == run_id {
            return r;
        }
    }
    return None;
}

def _find_workspace(workspace_id: str) -> Workspace | None {
    for w in [root --> ][?:Workspace] {
        if jid(w) == workspace_id {
            return w;
        }
    }
    return None;
}

# stop_run needs to reach into whatever context `flow` actually executes
# _execute_run in — which may not share plain Python object state with the
# request-handling process. A raw multiprocessing.Event alone was observed to
# never actually halt a run (stop_run confirmed it found and .set() the same
# object, yet the run kept going indefinitely), so this backs the signal with
# the persisted LoadTestRun.status too: _execute_run already proves node
# writes/reads cross whatever boundary `flow` uses (that's how "running" ->
# "completed"/"failed" gets observed by later walker calls), so is_set() also
# treats any non-"running" status as a stop request. The multiprocessing.Event
# is kept for the true OS-subprocess path (run_multiprocess/_worker_fn, when
# workers > 1) where jobj() has no graph context to call into.
obj _RunStopSignal {
    has run_id: str;
    has _event: object = None;

    def __post_init__() {
        self._event = multiprocessing.get_context("spawn").Event();
    }

    def is_set() -> bool {
        if self._event.is_set() {
            return True;
        }
        try {
            run = jobj(self.run_id);
            return run is None or run.status != "running";
        } except Exception {
            return False;
        }
    }

    def set() {
        self._event.set();
        try {
            run = jobj(self.run_id);
            if run is not None and run.status == "running" {
                run.status = "stopped";
            }
        } except Exception {

        }
    }
}

def _run_view(run: LoadTestRun) -> dict {
    return {
        "id": jid(run),
        "label": run.label,
        "workspace_id": run.workspace_id,
        "vus": run.vus,
        "iterations": run.iterations,
        "ramp_up": run.ramp_up,
        "workers": run.workers,
        "rps": run.rps,
        "think_time": run.think_time,
        "think_time_scale": run.think_time_scale,
        "timeout": run.timeout,
        "fail_on_error_rate": run.fail_on_error_rate,
        "fail_on_p95": run.fail_on_p95,
        "fail_on_p99": run.fail_on_p99,
        "abort_on_fail": run.abort_on_fail,
        "threshold_start_delay": run.threshold_start_delay,
        "status": run.status,
        "started_at": run.started_at,
        "completed_at": run.completed_at,
        "passed_thresholds": run.passed_thresholds,
        "results_json": run.results_json,
        "error_message": run.error_message,
    };
}

# Re-derives the enabled subset of the workspace's recorded HAR (the wizard lets
# a user disable individual requests) and writes it to a temp file, since
# jac_loadtest_cli.core.har_parser.parse_har() only reads from a file path.
def _write_filtered_har(ws: Workspace) -> str {
    har_data = json.loads(ws.har_raw_json);
    if ws.har_entries_json {
        selected = json.loads(ws.har_entries_json);
        entries = har_data.get("log", {}).get("entries", []);
        keep = [];
        for i in range(len(entries)) {
            flag = selected[i].get("enabled", True) if i < len(selected) else True;
            if flag {
                keep.append(entries[i]);
            }
        }
        har_data["log"]["entries"] = keep;
    }
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".har", encoding="utf-8", delete=False);
    with tmp as f {
        json.dump(har_data, f);
    }
    return tmp.name;
}

def _build_config(run: LoadTestRun, ws: Workspace, har_path: str) -> LoadTestConfig {
    d: dict = {
        "vus": run.vus,
        "iterations": run.iterations,
        "ramp_up": run.ramp_up,
        "timeout": run.timeout,
        "mode": ws.mode,
        "think_time": run.think_time,
        "think_time_scale": run.think_time_scale,
        "rps": run.rps,
        "include_static": ws.include_static,
        "login_path": ws.login_path,
        "fail_on_error_rate": run.fail_on_error_rate,
        "fail_on_p95": run.fail_on_p95,
        "fail_on_p99": run.fail_on_p99,
        "abort_on_fail": run.abort_on_fail,
        "threshold_start_delay": run.threshold_start_delay,
        "max_samples": run.max_samples,
        "har_file": har_path,
        "url": ws.target_url,
        "username": ws.username,
        "password": ws.password,
        "services_map": ws.services_map_json,
    };
    if run.workers > 0 {
        d["workers"] = run.workers;
    }
    return LoadTestConfig.from_dict(d);
}

# Mirrors cli.jac's own pass/fail semantics (strictly-greater-than the limit);
# None means "no thresholds were configured for this run".
def _passed_thresholds(run: LoadTestRun, result: dict) -> bool | None {
    if run.fail_on_error_rate is None and run.fail_on_p95 is None and run.fail_on_p99 is None {
        return None;
    }
    summary = result.get("summary", {});
    if summary.get("total_requests", 0) == 0 {
        return None;
    }
    error_rate = 100.0 - summary.get("success_rate_pct", 100.0);
    if run.fail_on_error_rate is not None and error_rate > run.fail_on_error_rate {
        return False;
    }
    if run.fail_on_p95 is not None and summary.get("p95_ms", 0.0) > run.fail_on_p95 {
        return False;
    }
    if run.fail_on_p99 is not None and summary.get("p99_ms", 0.0) > run.fail_on_p99 {
        return False;
    }
    return True;
}

# Runs on a thread-pool thread (via `flow`, launched from start_run) so the
# request that triggered it returns immediately. `run_id` lets it push
# snapshots into the queue.Queue the SSE endpoint polls — queue.Queue.put()
# is itself thread-safe, no event loop needed on this side.
def _execute_run(run_jid: str, config: LoadTestConfig, har_path: str, stop_event: object, run_id: str) {
    def on_snapshot(snap: object) {
        item = {
            "elapsed_s": snap.timestamp,
            "rps": snap.rps,
            "error_rate": snap.error_rate_pct,
            "p50_ms": snap.p50_ms,
            "p95_ms": snap.p95_ms,
            "p99_ms": snap.p99_ms,
            "total_requests": snap.total_requests,
        };
        snap_queue = _stream_queues.get(run_id);
        if snap_queue is not None {
            snap_queue.put(item);
        }
    }

    html_holder: list = [];
    def on_html(html: str) {
        html_holder.append(html);
    }

    try {
        result = run_test_headless(
            config, on_snapshot=on_snapshot, stop_event=stop_event, on_html_report=on_html
        );
        run = jobj(run_jid);
        run.status = "stopped" if stop_event.is_set() else "completed";
        run.completed_at = datetime.now(UTC).isoformat();
        run.results_json = json.dumps(result);
        run.results_html = html_holder[0] if html_holder else None;
        run.passed_thresholds = _passed_thresholds(run, result);
    } except Exception as e {
        run = jobj(run_jid);
        run.status = "failed";
        run.completed_at = datetime.now(UTC).isoformat();
        run.error_message = str(e);
    } finally {
        try {
            os.remove(har_path);
        } except Exception {

        }
        snap_queue = _stream_queues.pop(run_id, None);
        if snap_queue is not None {
            snap_queue.put(None);
        }
        _stop_events.pop(run_id, None);
        _background_futures.pop(run_id, None);
    }
}

walker create_run {
    has workspace_id: str;
    has vus: int = 10;
    has iterations: int = 100;
    has ramp_up: int = 0;
    has workers: int = 0;
    has rps: int = 0;
    has think_time: str = "none";
    has think_time_scale: float = 1.0;
    has timeout: int = 30;
    has fail_on_error_rate: float | None = None;
    has fail_on_p95: float | None = None;
    has fail_on_p99: float | None = None;
    has abort_on_fail: bool = False;
    has threshold_start_delay: int = 0;
    has label: str = "";

    can create with Root entry {
        ws = _find_workspace(self.workspace_id);
        if ws is None {
            report {"error": "Workspace not found"};
            return;
        }
        if not self.label.strip() {
            report {"error": "Run label is required"};
            return;
        }
        if self.vus < 1 {
            report {"error": "VUs must be at least 1"};
            return;
        }
        if self.iterations < 1 {
            report {"error": "Iterations must be at least 1"};
            return;
        }

        run = root ++> LoadTestRun(
            label=self.label.strip(),
            workspace_id=self.workspace_id,
            vus=self.vus,
            iterations=self.iterations,
            ramp_up=str(self.ramp_up),
            workers=self.workers,
            rps=self.rps,
            think_time=self.think_time,
            think_time_scale=self.think_time_scale,
            timeout=str(self.timeout),
            fail_on_error_rate=self.fail_on_error_rate,
            fail_on_p95=self.fail_on_p95,
            fail_on_p99=self.fail_on_p99,
            abort_on_fail=self.abort_on_fail,
            threshold_start_delay=str(self.threshold_start_delay),
        );
        report _run_view(run);
    }
}

walker start_run {
    has run_id: str;

    can start with Root entry {
        run = _find_run(self.run_id);
        if run is None {
            report {"error": "Run not found"};
            return;
        }
        if run.status == "running" {
            report {"error": "Run is already running"};
            return;
        }
        ws = _find_workspace(run.workspace_id);
        if ws is None {
            report {"error": "Workspace not found"};
            return;
        }
        if not ws.har_raw_json {
            report {"error": "Workspace has no HAR recording — upload one before starting a run"};
            return;
        }

        har_path = _write_filtered_har(ws);
        config = _build_config(run, ws, har_path);

        snap_queue = queue.Queue();
        _stream_queues[self.run_id] = snap_queue;
        stop_event = _RunStopSignal(run_id=self.run_id);
        _stop_events[self.run_id] = stop_event;

        run.status = "running";
        run.started_at = datetime.now(UTC).isoformat();
        run.error_message = None;

        run_jid = jid(run);
        future = flow _execute_run(run_jid, config, har_path, stop_event, self.run_id);
        _background_futures[self.run_id] = future;

        report {"ok": True, "stream_url": "/function/stream_metrics?run_id=" + self.run_id};
    }
}

walker stop_run {
    has run_id: str;

    can stop with Root entry {
        run = _find_run(self.run_id);
        if run is None {
            report {"error": "Run not found"};
            return;
        }
        if run.status != "running" {
            report {"ok": True};
            return;
        }
        # Flip the persisted status immediately — this is the channel proven to
        # reliably cross whatever execution context `flow` runs _execute_run in,
        # so the UI/API reflect "stopped" right away even in the worst case
        # where the in-memory stop_event never reaches the running VU loop
        # (e.g. a stale/orphaned entry after a server restart).
        run.status = "stopped";
        stop_event = _stop_events.get(self.run_id);
        if stop_event is not None {
            stop_event.set();
        }
        report {"ok": True};
    }
}

walker get_run {
    has run_id: str;

    can get with Root entry {
        run = _find_run(self.run_id);
        if run is None {
            report {"error": "Run not found"};
            return;
        }
        report _run_view(run);
    }
}

walker list_runs {
    has workspace_id: str;

    can list with Root entry {
        runs = [root --> ][?:LoadTestRun][?workspace_id == self.workspace_id];
        report [_run_view(r) for r in runs];
    }
}

walker delete_run {
    has run_id: str;

    can delete with Root entry {
        run = _find_run(self.run_id);
        if run is None {
            report {"error": "Run not found"};
            return;
        }
        if run.status == "running" {
            report {"error": "Cannot delete a running run — stop it first"};
            return;
        }
        _stream_queues.pop(self.run_id, None);
        _stop_events.pop(self.run_id, None);
        _background_futures.pop(self.run_id, None);
        del run;
        report {"ok": True};
    }
}

walker get_run_html {
    has run_id: str;

    can get with Root entry {
        run = _find_run(self.run_id);
        if run is None {
            report {"error": "Run not found"};
            return;
        }
        report {"html": run.results_html or ""};
    }
}
