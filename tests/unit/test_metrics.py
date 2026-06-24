"""Unit tests for core/metrics.py — no network, no I/O."""
from __future__ import annotations

import time
import pytest

from jac_loadtest_cli.core.metrics import (
    RequestResult,
    MetricsCollector,
    percentile,
    normalize_path,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _result(
    endpoint: str = "POST /walker/search",
    status: int = 200,
    latency_ms: float = 50.0,
    error_type: str | None = None,
    vu_id: int = 0,
    service: str = "monolith",
) -> RequestResult:
    return RequestResult(
        endpoint=endpoint,
        service=service,
        status=status,
        latency_ms=latency_ms,
        bytes_received=100,
        timestamp=time.time(),
        vu_id=vu_id,
        error_type=error_type,
    )


# ---------------------------------------------------------------------------
# percentile()
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_percentile_p50():
    assert percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == 3.0


@pytest.mark.unit
def test_percentile_p95_p99():
    data = [float(i) for i in range(1, 101)]  # 1..100
    p95 = percentile(data, 95)
    p99 = percentile(data, 99)
    assert p95 == 95.0
    assert p99 == 99.0


@pytest.mark.unit
def test_percentile_single_element():
    assert percentile([42.0], 50) == 42.0
    assert percentile([42.0], 95) == 42.0
    assert percentile([42.0], 99) == 42.0


@pytest.mark.unit
def test_percentile_empty():
    assert percentile([], 50) == 0.0
    assert percentile([], 99) == 0.0


# ---------------------------------------------------------------------------
# normalize_path()
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_normalize_path_integer():
    assert normalize_path("http://host/walker/user/123") == "/walker/user/{id}"


@pytest.mark.unit
def test_normalize_path_uuid_with_hyphens():
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    result = normalize_path(f"http://host/walker/order/{uuid}")
    assert result == "/walker/order/{id}"


@pytest.mark.unit
def test_normalize_path_uuid_no_hyphens():
    uuid = "550e8400e29b41d4a716446655440000"
    result = normalize_path(f"http://host/walker/order/{uuid}")
    assert result == "/walker/order/{id}"


@pytest.mark.unit
def test_normalize_path_unchanged():
    result = normalize_path("http://host/walker/search")
    assert result == "/walker/search"


@pytest.mark.unit
def test_normalize_path_multiple_ids():
    result = normalize_path("http://host/a/123/b/456")
    assert result == "/a/{id}/b/{id}"


# ---------------------------------------------------------------------------
# MetricsCollector — storage behaviour
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_total_count_never_drops():
    collector = MetricsCollector(max_samples=10)
    for _ in range(50):
        collector.record(_result())
    assert collector.total_count == 50
    assert len(collector._samples) == 10  # deque bounded


@pytest.mark.unit
def test_deque_bounded():
    collector = MetricsCollector(max_samples=5)
    for i in range(20):
        collector.record(_result(latency_ms=float(i)))
    assert collector.total_count == 20
    assert len(collector._samples) == 5
    # Oldest entries dropped — only last 5 remain
    latencies = [r.latency_ms for r in collector._samples]
    assert latencies == [15.0, 16.0, 17.0, 18.0, 19.0]


@pytest.mark.unit
def test_generate_timeseries_produces_snapshots():
    collector = MetricsCollector()
    t_start = time.time()
    # Record 10 requests spread across two 10-second buckets
    for i in range(10):
        r = RequestResult(
            endpoint="GET /health",
            service="monolith",
            status=200,
            latency_ms=10.0,
            bytes_received=100,
            timestamp=t_start + (i * 2),  # 0s, 2s, 4s … 18s → spans two 10s buckets
            vu_id=0,
            error_type=None,
        )
        collector.record(r)
    snapshots = collector.generate_timeseries(t_start, interval=10.0)
    assert len(snapshots) == 2
    assert snapshots[0].total_requests > 0
    assert snapshots[1].total_requests > 0


# ---------------------------------------------------------------------------
# MetricsCollector — compute_endpoint_stats()
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_error_breakdown_http():
    collector = MetricsCollector()
    collector.record(_result(status=500, error_type=None))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"expected 200 got 500": 1}


@pytest.mark.unit
def test_error_breakdown_network():
    collector = MetricsCollector()
    collector.record(_result(status=0, error_type="TIMEOUT"))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"TIMEOUT": 1}


@pytest.mark.unit
def test_success_rate_calculation():
    collector = MetricsCollector()
    for _ in range(9):
        collector.record(_result(status=200))
    collector.record(_result(status=500))
    stats = collector.compute_endpoint_stats()
    assert stats[0].success_rate_pct == 90.0


@pytest.mark.unit
def test_error_type_http_vs_network():
    """4xx/5xx have error_type=None; network failures have error_type set."""
    collector = MetricsCollector()
    collector.record(_result(status=404, error_type=None))
    collector.record(_result(status=0, error_type="CONNECTION_REFUSED"))
    stats = collector.compute_endpoint_stats()
    breakdown = stats[0].error_breakdown
    assert "expected 200 got 404" in breakdown
    assert "CONNECTION_REFUSED" in breakdown
    assert breakdown["expected 200 got 404"] == 1
    assert breakdown["CONNECTION_REFUSED"] == 1


# ---------------------------------------------------------------------------
# error_breakdown — occurrence labelling
# ---------------------------------------------------------------------------

def _result_with_occurrence(
    status: int = 422,
    error_type: str | None = None,
    occurrence: int = 1,
    total_occurrences: int = 1,
) -> RequestResult:
    return RequestResult(
        endpoint="/walker/ai_chat",
        service="monolith",
        status=status,
        latency_ms=50.0,
        bytes_received=100,
        timestamp=0.0,
        vu_id=0,
        error_type=error_type,
        occurrence=occurrence,
        total_occurrences=total_occurrences,
    )


@pytest.mark.unit
def test_error_breakdown_no_occurrence_label_when_single():
    """When total_occurrences=1 the breakdown key is just the status code, no call label."""
    collector = MetricsCollector()
    collector.record(_result_with_occurrence(status=500, occurrence=1, total_occurrences=1))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"expected 200 got 500": 1}


@pytest.mark.unit
def test_error_breakdown_occurrence_label_when_repeated():
    """When total_occurrences>1 the breakdown key includes '(call #N of M)'."""
    collector = MetricsCollector()
    collector.record(_result_with_occurrence(status=422, occurrence=3, total_occurrences=4))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"expected 200 got 422 (call #3 of 4)": 1}


@pytest.mark.unit
def test_error_breakdown_occurrence_aggregates_across_vus():
    """The same failing occurrence across multiple VUs/iterations aggregates its count."""
    collector = MetricsCollector()
    for _ in range(5):
        collector.record(_result_with_occurrence(status=422, occurrence=3, total_occurrences=4))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"expected 200 got 422 (call #3 of 4)": 5}


@pytest.mark.unit
def test_error_breakdown_different_occurrences_listed_separately():
    """Different failing occurrences of the same endpoint produce separate keys."""
    collector = MetricsCollector()
    collector.record(_result_with_occurrence(status=422, occurrence=2, total_occurrences=4))
    collector.record(_result_with_occurrence(status=500, occurrence=4, total_occurrences=4))
    stats = collector.compute_endpoint_stats()
    breakdown = stats[0].error_breakdown
    assert breakdown == {
        "expected 200 got 422 (call #2 of 4)": 1,
        "expected 200 got 500 (call #4 of 4)": 1,
    }


@pytest.mark.unit
def test_error_breakdown_network_error_with_occurrence():
    """Network error types also get the occurrence label when total_occurrences>1."""
    collector = MetricsCollector()
    collector.record(_result_with_occurrence(
        status=0, error_type="TIMEOUT", occurrence=2, total_occurrences=3
    ))
    stats = collector.compute_endpoint_stats()
    assert stats[0].error_breakdown == {"TIMEOUT (call #2 of 3)": 1}
