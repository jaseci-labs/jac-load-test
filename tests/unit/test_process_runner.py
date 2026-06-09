"""Unit tests for core/process_runner.py — slice math and merge logic only.

Actual multiprocess execution is covered by the integration test suite;
spawning real child processes in unit tests is slow and environment-sensitive.
"""
from __future__ import annotations

import time
import pytest

from jac_loadtest.core.process_runner import _compute_slices
from jac_loadtest.core.metrics import MetricsCollector, RequestResult


# ---------------------------------------------------------------------------
# _compute_slices — VU distribution
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_slices_exact_division():
    """VUs divide evenly: each worker gets vus // workers."""
    slices = _compute_slices(total_vus=100, workers=4)
    assert len(slices) == 4
    assert all(count == 25 for _, count in slices)


@pytest.mark.unit
def test_slices_with_remainder():
    """Remainder VUs are distributed one extra to the first workers."""
    slices = _compute_slices(total_vus=10, workers=3)
    counts = [count for _, count in slices]
    assert counts == [4, 3, 3]


@pytest.mark.unit
def test_slices_offsets_are_contiguous():
    """VU ID offsets must form a contiguous, non-overlapping sequence."""
    slices = _compute_slices(total_vus=10, workers=3)
    offsets = [offset for offset, _ in slices]
    counts = [count for _, count in slices]
    assert offsets[0] == 0
    for i in range(1, len(slices)):
        assert offsets[i] == offsets[i - 1] + counts[i - 1]


@pytest.mark.unit
def test_slices_cover_all_vus():
    """Sum of worker VU counts must equal total_vus."""
    for total_vus, workers in [(1, 1), (7, 3), (1000, 4), (1, 8)]:
        slices = _compute_slices(total_vus=total_vus, workers=workers)
        assert sum(count for _, count in slices) == total_vus


@pytest.mark.unit
def test_slices_capped_at_vus():
    """When workers > vus, only as many slices as VUs are produced (no zero-count slices)."""
    slices = _compute_slices(total_vus=3, workers=8)
    assert len(slices) == 3
    assert all(count > 0 for _, count in slices)


@pytest.mark.unit
def test_slices_single_worker():
    """Single worker gets all VUs starting at offset 0."""
    slices = _compute_slices(total_vus=50, workers=1)
    assert slices == [(0, 50)]


# ---------------------------------------------------------------------------
# Metrics merge — coordinator behaviour without spawning processes
# ---------------------------------------------------------------------------

def _make_result(endpoint: str, status: int, vu_id: int) -> RequestResult:
    return RequestResult(
        endpoint=endpoint,
        service="monolith",
        status=status,
        latency_ms=10.0,
        bytes_received=100,
        timestamp=time.time(),
        vu_id=vu_id,
        error_type=None,
    )


@pytest.mark.unit
def test_merge_samples_from_two_workers():
    """Merging two worker sample lists produces a collector with all records."""
    worker_a = [_make_result("/a", 200, vu_id=i) for i in range(3)]
    worker_b = [_make_result("/a", 200, vu_id=i + 3) for i in range(3)]

    merged = MetricsCollector(max_samples=1_000_000)
    for result in worker_a + worker_b:
        merged.record(result)

    stats = merged.compute_endpoint_stats()
    assert stats[0].total_requests == 6


@pytest.mark.unit
def test_merge_preserves_vu_id_uniqueness():
    """VU IDs from different workers must not collide (offset ensures this)."""
    slices = _compute_slices(total_vus=6, workers=2)
    vu_ids_per_worker = [
        list(range(offset, offset + count)) for offset, count in slices
    ]
    all_ids = [vid for worker in vu_ids_per_worker for vid in worker]
    assert len(all_ids) == len(set(all_ids)), "VU IDs must be unique across workers"


@pytest.mark.unit
def test_merge_error_breakdown_aggregated():
    """Error breakdown from two workers for the same endpoint aggregates correctly."""
    merged = MetricsCollector(max_samples=1_000_000)
    # Worker 0: one 422 on call #1 of 2
    merged.record(RequestResult(
        endpoint="/walker/chat", service="monolith", status=422,
        latency_ms=5.0, bytes_received=0, timestamp=0.0,
        vu_id=0, error_type=None, occurrence=1, total_occurrences=2,
    ))
    # Worker 1: same failure
    merged.record(RequestResult(
        endpoint="/walker/chat", service="monolith", status=422,
        latency_ms=5.0, bytes_received=0, timestamp=0.0,
        vu_id=1, error_type=None, occurrence=1, total_occurrences=2,
    ))
    stats = merged.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"422 (call #1 of 2)": 2}
