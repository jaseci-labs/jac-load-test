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
import from jac_loadtest_cli.core.process_runner { _compute_slices, _worker_fn, _merge_snapshots }
import from jac_loadtest_cli.core.metrics { MetricsCollector, RequestResult, StatsSnapshot }

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
