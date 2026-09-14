"""Unit tests for core/process_runner.jac — slice math and merge logic only.

Real multiprocess execution (actually spawning worker processes) is
deliberately not exercised here: multiprocessing's "spawn" context pickles
_worker_fn by module reference, and that lookup is fragile under jaclang +
pytest-xdist when the full test tree is collected together. _worker_fn and
_merge_snapshots are instead exercised directly (in-process, no real Process
spawn) so the wiring is still covered without that fragility. The full
run_multiprocess() orchestration (real spawn, real queue, real join) is
verified manually — see docs/ARCHITECTURE.md.
"""

import time;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.process_runner { _compute_slices, _worker_fn, _merge_snapshots, _merge_worker_results, _snapshot_breached }
import from jac_loadtest_cli.core.metrics { MetricsCollector, RequestResult, StatsSnapshot, build_histogram, histogram_percentile, histogram_total, percentile }

obj _FakeQueue {
    has items: list = None;

    def __post_init__() {
        self.items = [];
    }

    def put(item: object) {
        self.items.append(item);
    }
}


def _make_result(endpoint: str, status: int, vu_id: int) -> RequestResult {
    return RequestResult(
        endpoint=endpoint,
        service="monolith",
        status=status,
        latency_ms=10.0,
        bytes_received=100,
        timestamp=time.time(),
        vu_id=vu_id,
        error_type=None,
    );
}


# ---------------------------------------------------------------------------
# _compute_slices — VU distribution
# ---------------------------------------------------------------------------

test "slices exact division" {
    slices = _compute_slices(total_vus=100, workers=4);
    assert len(slices) == 4;
    assert all(count == 25 for (_, count) in slices);
}

test "slices with remainder" {
    slices = _compute_slices(total_vus=10, workers=3);
    counts = [count for (_, count) in slices];
    assert counts == [4, 3, 3];
}

test "slices offsets are contiguous" {
    slices = _compute_slices(total_vus=10, workers=3);
    offsets = [offset for (offset, _) in slices];
    counts  = [count  for (_, count) in slices];
    assert offsets[0] == 0;
    for i in range(1, len(slices)) {
        assert offsets[i] == offsets[i - 1] + counts[i - 1];
    }
}

test "slices cover all vus" {
    for pair in [(1, 1), (7, 3), (1000, 4), (1, 8)] {
        total_vus = pair[0];
        workers   = pair[1];
        slices = _compute_slices(total_vus=total_vus, workers=workers);
        assert sum(count for (_, count) in slices) == total_vus;
    }
}

test "slices capped at vus" {
    slices = _compute_slices(total_vus=3, workers=8);
    assert len(slices) == 3;
    assert all(count > 0 for (_, count) in slices);
}

test "slices single worker" {
    slices = _compute_slices(total_vus=50, workers=1);
    assert slices == [(0, 50)];
}


# ---------------------------------------------------------------------------
# Metrics merge — coordinator behaviour without spawning processes
# ---------------------------------------------------------------------------

test "merge samples from two workers" {
    worker_a = [_make_result("/a", 200, vu_id=i)     for i in range(3)];
    worker_b = [_make_result("/a", 200, vu_id=i + 3) for i in range(3)];

    merged = MetricsCollector(max_samples=1_000_000);
    for result in worker_a + worker_b {
        merged.record(result);
    }

    stats = merged.compute_endpoint_stats();
    assert stats[0].total_requests == 6;
}

test "merge preserves vu id uniqueness" {
    slices = _compute_slices(total_vus=6, workers=2);
    all_ids: list[int] = [];
    for pair in slices {
        offset = pair[0];
        count  = pair[1];
        for vid in range(offset, offset + count) {
            all_ids.append(vid);
        }
    }
    assert len(all_ids) == len(set(all_ids)) , "VU IDs must be unique across workers";
}

test "merge worker results carries no eviction when no worker evicted" {
    worker_a = [_make_result("/a", 200, vu_id=i) for i in range(3)];
    worker_b = [_make_result("/a", 200, vu_id=i + 3) for i in range(3)];
    raw_results = [
        ("ok", 0, worker_a, 0),
        ("ok", 3, worker_b, 0),
    ];
    merged = _merge_worker_results(raw_results, max_samples=1_000_000);
    assert merged.samples_evicted == 0;
    assert merged.compute_endpoint_stats()[0].total_requests == 6;
}

test "merge worker results sums eviction counts reported by each worker" {
    # A worker evicts internally against its own max_samples window before its
    # results ever reach this process (see _worker_fn) — that loss must not
    # be lost on the way into the final report.
    worker_a = [_make_result("/a", 200, vu_id=i) for i in range(3)];
    worker_b = [_make_result("/a", 200, vu_id=i + 3) for i in range(3)];
    raw_results = [
        ("ok", 0, worker_a, 400),
        ("ok", 3, worker_b, 250),
    ];
    merged = _merge_worker_results(raw_results, max_samples=1_000_000);
    assert merged.samples_evicted == 650;
}

test "merge worker results adds merge-time eviction on top of worker-reported eviction" {
    worker_a = [_make_result("/a", 200, vu_id=i) for i in range(5)];
    worker_b = [_make_result("/a", 200, vu_id=i + 5) for i in range(5)];
    raw_results = [
        ("ok", 0, worker_a, 100),
        ("ok", 5, worker_b, 0),
    ];
    # max_samples=6 forces the merge step itself to evict 4 of the 10 merged
    # samples, on top of the 100 the worker already reported.
    merged = _merge_worker_results(raw_results, max_samples=6);
    assert merged.samples_evicted == 104;
}

test "merge worker results tolerates messages without an eviction count" {
    worker_a = [_make_result("/a", 200, vu_id=0)];
    raw_results = [("ok", 0, worker_a)];
    merged = _merge_worker_results(raw_results, max_samples=1_000_000);
    assert merged.samples_evicted == 0;
    assert merged.compute_endpoint_stats()[0].total_requests == 1;
}

test "merge error breakdown aggregated" {
    merged = MetricsCollector(max_samples=1_000_000);
    merged.record(RequestResult(
        endpoint="/walker/chat", service="monolith", status=422,
        latency_ms=5.0, bytes_received=0, timestamp=0.0,
        vu_id=0, error_type=None, occurrence=1, total_occurrences=2,
    ));
    merged.record(RequestResult(
        endpoint="/walker/chat", service="monolith", status=422,
        latency_ms=5.0, bytes_received=0, timestamp=0.0,
        vu_id=1, error_type=None, occurrence=1, total_occurrences=2,
    ));
    stats = merged.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 422 (call #1 of 2)": 2};
}


# ---------------------------------------------------------------------------
# _merge_snapshots — cross-worker aggregation (pure function)
# ---------------------------------------------------------------------------

test "_merge_snapshots combines totals rps and weighted percentiles" {
    snaps = [
        StatsSnapshot(timestamp=10.0, p50_ms=40.0, p95_ms=100.0, p99_ms=200.0, rps=5.0, error_rate_pct=0.0, total_requests=50),
        StatsSnapshot(timestamp=10.0, p50_ms=60.0, p95_ms=140.0, p99_ms=260.0, rps=5.0, error_rate_pct=20.0, total_requests=50),
    ];
    merged = _merge_snapshots(snaps);
    assert merged.total_requests == 100;
    assert merged.rps == 10.0;
    assert merged.error_rate_pct == 10.0;
    assert merged.p50_ms == 50.0;
}

test "_merge_snapshots empty list yields zeroed snapshot" {
    merged = _merge_snapshots([]);
    assert merged.total_requests == 0;
    assert merged.rps == 0.0;
    assert merged.error_rate_pct == 0.0;
}


# ---------------------------------------------------------------------------
# _worker_fn — stream_metrics_callback wiring (no real process spawn)
# ---------------------------------------------------------------------------

def _dead_url() -> str {
    import socket as _socket;
    s = _socket.socket();
    s.bind(("127.0.0.1", 0));
    port = s.getsockname()[1];
    s.close();
    return f"http://127.0.0.1:{port}";
}

test "_worker_fn always reports ok on completion" {
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=dead_url);
    queue = _FakeQueue();

    _worker_fn(
        vu_id_offset=0, worker_vus=1, total_vus=1, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=time.time(), stream_enabled=False, stream_interval=10.0,
    );

    kinds = [msg[0] for msg in queue.items];
    assert "ok" in kinds;
    assert "worker_snapshot" not in kinds;

    ok_msg = next(msg for msg in queue.items if msg[0] == "ok");
    assert len(ok_msg) == 4;
    assert isinstance(ok_msg[3], int);
}

test "_worker_fn propagates open_loop config through to the run" {
    # worker_config is built internally from `config` field by field (see
    # _worker_fn) — this exercises that open_loop actually reaches the worker's
    # run_all_vus call rather than being dropped, by running the open-loop path
    # (which requires rps > 0) inside a real worker invocation.
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(vus=1, iterations=2, mode="monolith", url=dead_url, open_loop=True, rps=20);
    queue = _FakeQueue();

    _worker_fn(
        vu_id_offset=0, worker_vus=1, total_vus=1, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=time.time(), stream_enabled=False, stream_interval=10.0,
    );

    kinds = [msg[0] for msg in queue.items];
    assert "ok" in kinds;
    ok_msg = next(msg for msg in queue.items if msg[0] == "ok");
    assert len(ok_msg[2]) == 2;
}

test "_worker_fn propagates duration config through to the run" {
    # worker_config is built internally from `config` field by field (see
    # _worker_fn) — duration was previously omitted there, so a --duration run
    # under the default multi-worker mode never stopped. This exercises the
    # duration watcher inside an actual worker invocation: iterations=None
    # (duration-driven) with a short duration against a connection-refused URL
    # (near-instant failures) should still be cut off promptly, and should run
    # well past a single iteration since nothing else bounds it.
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(vus=1, iterations=None, mode="monolith", url=dead_url, duration="0.2s");
    queue = _FakeQueue();

    t0 = time.monotonic();
    _worker_fn(
        vu_id_offset=0, worker_vus=1, total_vus=1, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=time.time(), stream_enabled=False, stream_interval=10.0,
    );
    elapsed = time.monotonic() - t0;

    assert elapsed < 3.0;
    kinds = [msg[0] for msg in queue.items];
    assert "ok" in kinds;
    ok_msg = next(msg for msg in queue.items if msg[0] == "ok");
    assert len(ok_msg[2]) > 1;
}

test "_worker_fn streams worker_snapshot messages when streaming enabled" {
    dead_url = _dead_url();
    # think_time paces iterations so the run reliably outlasts a couple of
    # stream ticks, regardless of how fast the (refused) connection fails.
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=20.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(vus=1, iterations=10, mode="monolith", url=dead_url, think_time="real");
    queue = _FakeQueue();

    _worker_fn(
        vu_id_offset=3, worker_vus=1, total_vus=1, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=time.time(), stream_enabled=True, stream_interval=0.03,
    );

    kinds = [msg[0] for msg in queue.items];
    assert "ok" in kinds;
    assert "worker_snapshot" in kinds;
    for msg in queue.items {
        if msg[0] == "worker_snapshot" {
            assert msg[1] == 3;
            assert isinstance(msg[2], StatsSnapshot);
        }
    }
}


# ---------------------------------------------------------------------------
# _merge_snapshots — histogram path (Phase 8d)
#
# The two tests above cover the legacy fallback: snapshots with no histogram
# still merge, using the old request-weighted average. These cover the path
# workers actually take now.
# ---------------------------------------------------------------------------

def _snap_from(latencies: list, rps: float = 5.0, error_rate_pct: float = 0.0) -> StatsSnapshot {
    hist = build_histogram(latencies);
    return StatsSnapshot(
        timestamp=10.0,
        p50_ms=histogram_percentile(hist, 50),
        p95_ms=histogram_percentile(hist, 95),
        p99_ms=histogram_percentile(hist, 99),
        rps=rps,
        error_rate_pct=error_rate_pct,
        total_requests=len(latencies),
        latency_buckets=hist,
    );
}

test "_merge_snapshots reads percentiles off the summed distribution" {
    # One worker fast, one slow, equal request counts. The request-weighted
    # average would land near the midpoint of the two p95s; the true p95 of the
    # combined traffic sits up in the slow worker's range. The merge must report
    # the latter -- this is the whole reason workers ship buckets.
    fast = [float(v) for v in range(1, 101)];
    slow = [float(v) for v in range(900, 1000)];
    merged = _merge_snapshots([_snap_from(fast), _snap_from(slow)]);

    assert merged.total_requests == 200;
    assert merged.rps == 10.0;
    assert histogram_total(merged.latency_buckets) == 200;

    pooled_exact = percentile(fast + slow, 95);
    assert merged.p95_ms >= pooled_exact;
    midpoint = (percentile(fast, 95) + percentile(slow, 95)) / 2.0;
    assert merged.p95_ms > midpoint;
}

test "_merge_snapshots keeps error rate request-weighted" {
    a = _snap_from([10.0] * 90, rps=9.0, error_rate_pct=0.0);
    b = _snap_from([10.0] * 10, rps=1.0, error_rate_pct=50.0);
    merged = _merge_snapshots([a, b]);
    assert merged.total_requests == 100;
    # 0% over 90 requests and 50% over 10 -> 5 errors in 100.
    assert abs(merged.error_rate_pct - 5.0) < 1e-9;
}

test "_merge_snapshots merges a mix of histogram and legacy snapshots" {
    # generate_timeseries() output and hand-built fixtures carry no buckets;
    # they must still contribute their counts rather than being dropped.
    legacy = StatsSnapshot(
        timestamp=10.0, p50_ms=40.0, p95_ms=100.0, p99_ms=200.0,
        rps=5.0, error_rate_pct=0.0, total_requests=50,
    );
    merged = _merge_snapshots([_snap_from([20.0] * 50), legacy]);
    assert merged.total_requests == 100;
    assert histogram_total(merged.latency_buckets) == 50;
}


# ---------------------------------------------------------------------------
# _snapshot_breached — the controller's --abort-on-fail decision (Phase 8d)
#
# Mirrors engine._breach_check, but reads the merged histogram because raw
# samples stay inside their worker until the run ends.
# ---------------------------------------------------------------------------

def _threshold_config(
    error_rate: float | None = None, p95: float | None = None, p99: float | None = None
) -> LoadTestConfig {
    return LoadTestConfig(
        vus=4, iterations=1, mode="monolith", url="http://localhost:1",
        abort_on_fail=True,
        fail_on_error_rate=error_rate, fail_on_p95=p95, fail_on_p99=p99,
    );
}

test "_snapshot_breached ignores an empty snapshot" {
    snap = _merge_snapshots([]);
    assert not _snapshot_breached(_threshold_config(error_rate=1.0), snap);
}

test "_snapshot_breached trips on merged error rate" {
    config = _threshold_config(error_rate=5.0);
    clean = _snap_from([10.0] * 100, error_rate_pct=0.0);
    dirty = _snap_from([10.0] * 100, error_rate_pct=20.0);
    # Either worker alone is below the limit on its own slice; together they are
    # at 10% and must trip. This is exactly the case per-worker watchers missed.
    assert not _snapshot_breached(config, _merge_snapshots([clean]));
    assert _snapshot_breached(config, _merge_snapshots([clean, dirty]));
}

test "_snapshot_breached trips on merged p95" {
    config = _threshold_config(p95=500.0);
    fast = _snap_from([float(v) for v in range(1, 101)]);
    slow = _snap_from([float(v) for v in range(900, 1000)]);
    assert not _snapshot_breached(config, _merge_snapshots([fast]));
    assert _snapshot_breached(config, _merge_snapshots([fast, slow]));
}

test "_snapshot_breached treats a fully dead target as a breach" {
    # Requests recorded but no measured latency anywhere: every one failed before
    # a response arrived. A p95 gate must not read that as passing (mirrors
    # engine._breach_check's same guard).
    config = _threshold_config(p95=500.0);
    dead = StatsSnapshot(
        timestamp=5.0, p50_ms=0.0, p95_ms=0.0, p99_ms=0.0,
        rps=10.0, error_rate_pct=100.0, total_requests=40,
        latency_buckets=build_histogram([]),
    );
    assert _snapshot_breached(config, dead);
}

test "_snapshot_breached stays quiet with no thresholds configured" {
    config = LoadTestConfig(
        vus=4, iterations=1, mode="monolith", url="http://localhost:1", abort_on_fail=True
    );
    assert not _snapshot_breached(config, _merge_snapshots([_snap_from([9000.0] * 50, error_rate_pct=100.0)]));
}


# ---------------------------------------------------------------------------
# _worker_fn — controller-owned abort wiring (Phase 8d)
#
# Exercised in-process (no real spawn), matching this file's existing approach.
# ---------------------------------------------------------------------------

test "_worker_fn stops promptly when the controller abort event is already set" {
    import multiprocessing as _mp;
    dead_url = _dead_url();
    # think_time keeps each iteration slow enough that an un-honoured stop signal
    # would leave the worker running well past the assertion window below.
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=200.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(
        vus=2, iterations=1000, mode="monolith", url=dead_url, think_time="real",
    );
    queue = _FakeQueue();
    abort = _mp.get_context("spawn").Event();
    abort.set();

    started = time.time();
    _worker_fn(
        vu_id_offset=0, worker_vus=2, total_vus=2, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=started, stream_enabled=False, stream_interval=10.0,
        controller_abort=abort, controller_owns_abort=True,
    );
    elapsed = time.time() - started;

    kinds = [msg[0] for msg in queue.items];
    assert "ok" in kinds;
    assert "error" not in kinds;
    # 1000 iterations x 200ms of think time would run for minutes; the stop
    # bridge polls at 10Hz, so this must return in a fraction of that.
    assert elapsed < 20.0;
}

test "_worker_fn honours an externally supplied stop signal" {
    # The embedder path (the web app's stop button) must keep working alongside
    # the controller's own abort event.
    import multiprocessing as _mp;
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=200.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(
        vus=2, iterations=1000, mode="monolith", url=dead_url, think_time="real",
    );
    queue = _FakeQueue();
    external_stop = _mp.get_context("spawn").Event();
    external_stop.set();

    started = time.time();
    _worker_fn(
        vu_id_offset=0, worker_vus=2, total_vus=2, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=started, stream_enabled=False, stream_interval=10.0,
        stop_requested=external_stop,
    );
    elapsed = time.time() - started;

    assert "ok" in [msg[0] for msg in queue.items];
    assert elapsed < 20.0;
}

test "_worker_fn streams snapshots carrying a histogram" {
    # The controller needs buckets, not just finished percentiles, to make the
    # merged abort decision -- assert workers actually ship them.
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=20.0, is_login=False, original_url="/api",
    )];
    config = LoadTestConfig(vus=1, iterations=10, mode="monolith", url=dead_url, think_time="real");
    queue = _FakeQueue();

    _worker_fn(
        vu_id_offset=3, worker_vus=1, total_vus=1, entries=entries, config=config,
        topology=None, token_by_vu=None, pre_resolved_hosts={},
        queue=queue, t_start=time.time(), stream_enabled=True, stream_interval=0.03,
    );

    snaps = [msg[2] for msg in queue.items if msg[0] == "worker_snapshot"];
    assert snaps;
    for snap in snaps {
        assert isinstance(snap, StatsSnapshot);
        assert len(snap.latency_buckets) > 0;
    }
}

test "_worker_fn leaves the abort decision to the controller when it owns it" {
    # Against a dead target every request fails, so a per-worker threshold
    # watcher would trip within ~1s and cut the run short. When the controller
    # owns the decision the worker must NOT do that -- it keeps generating load
    # until told otherwise, because its own slice is not the evidence the
    # decision should be made on. Compared head-to-head with the legacy
    # self-aborting path to show the difference is real and not just timing.
    dead_url = _dead_url();
    entries = [HarEntry(
        method="POST", url=f"{dead_url}/api", headers={}, body=None, body_mime=None,
        think_time_ms=100.0, is_login=False, original_url="/api",
    )];

    def _run(controller_owns: bool) -> int {
        config = LoadTestConfig(
            vus=1, iterations=30, mode="monolith", url=dead_url, think_time="real",
            abort_on_fail=True, fail_on_error_rate=1.0,
        );
        queue = _FakeQueue();
        _worker_fn(
            vu_id_offset=0, worker_vus=1, total_vus=1, entries=entries, config=config,
            topology=None, token_by_vu=None, pre_resolved_hosts={},
            queue=queue, t_start=time.time(), stream_enabled=False, stream_interval=10.0,
            controller_owns_abort=controller_owns,
        );
        ok = next(msg for msg in queue.items if msg[0] == "ok");
        return len(ok[2]);
    }

    self_aborting = _run(False);
    controller_owned = _run(True);

    # The self-aborting worker stops ~1s in; the controller-owned one runs its
    # full 30 iterations of 100ms think time.
    assert controller_owned == 30;
    assert self_aborting < controller_owned;
}
