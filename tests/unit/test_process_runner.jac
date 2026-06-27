"""Unit tests for core/process_runner.jac — slice math and merge logic only.

Actual multiprocess execution is covered by the integration test suite;
spawning real child processes in unit tests is slow and environment-sensitive.
"""

import time;
import from jac_loadtest_cli.core.process_runner { _compute_slices }
import from jac_loadtest_cli.core.metrics { MetricsCollector, RequestResult }


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
