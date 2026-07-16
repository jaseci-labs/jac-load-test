"""Unit tests for core/metrics.jac — no network, no I/O."""

import time;
import from jac_loadtest_cli.core.metrics {
    RequestResult,
    MetricsCollector,
    percentile,
    normalize_path
}


def _result(
    endpoint: str = "POST /walker/search",
    status: int = 200,
    latency_ms: float = 50.0,
    error_type: str | None = None,
    vu_id: int = 0,
    service: str = "monolith",
    ttfb_ms: float = 0.0,
) -> RequestResult {
    return RequestResult(
        endpoint=endpoint,
        service=service,
        status=status,
        latency_ms=latency_ms,
        bytes_received=100,
        timestamp=time.time(),
        vu_id=vu_id,
        error_type=error_type,
        ttfb_ms=ttfb_ms,
    );
}

def _result_with_occurrence(
    status: int = 422,
    error_type: str | None = None,
    occurrence: int = 1,
    total_occurrences: int = 1,
) -> RequestResult {
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
    );
}


# ---------------------------------------------------------------------------
# percentile()
# ---------------------------------------------------------------------------

test "percentile p50" {
    assert percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == 3.0;
}

test "percentile p95 and p99" {
    data = [float(i) for i in range(1, 101)];
    assert percentile(data, 95) == 95.0;
    assert percentile(data, 99) == 99.0;
}

test "percentile single element" {
    assert percentile([42.0], 50) == 42.0;
    assert percentile([42.0], 95) == 42.0;
    assert percentile([42.0], 99) == 42.0;
}

test "percentile empty" {
    assert percentile([], 50) == 0.0;
    assert percentile([], 99) == 0.0;
}


# ---------------------------------------------------------------------------
# normalize_path()
# ---------------------------------------------------------------------------

test "normalize path integer" {
    assert normalize_path("http://host/walker/user/123") == "/walker/user/{id}";
}

test "normalize path uuid with hyphens" {
    uuid = "550e8400-e29b-41d4-a716-446655440000";
    result = normalize_path(f"http://host/walker/order/{uuid}");
    assert result == "/walker/order/{id}";
}

test "normalize path uuid no hyphens" {
    uuid = "550e8400e29b41d4a716446655440000";
    result = normalize_path(f"http://host/walker/order/{uuid}");
    assert result == "/walker/order/{id}";
}

test "normalize path unchanged" {
    result = normalize_path("http://host/walker/search");
    assert result == "/walker/search";
}

test "normalize path multiple ids" {
    result = normalize_path("http://host/a/123/b/456");
    assert result == "/a/{id}/b/{id}";
}


# ---------------------------------------------------------------------------
# MetricsCollector — storage behaviour
# ---------------------------------------------------------------------------

test "total count never drops" {
    collector = MetricsCollector(max_samples=10);
    for _ in range(50) {
        collector.record(_result());
    }
    assert collector.total_count == 50;
    assert len(collector._samples) == 10;
}

test "deque bounded" {
    collector = MetricsCollector(max_samples=5);
    for i in range(20) {
        collector.record(_result(latency_ms=float(i)));
    }
    assert collector.total_count == 20;
    assert len(collector._samples) == 5;
    latencies = [r.latency_ms for r in collector._samples];
    assert latencies == [15.0, 16.0, 17.0, 18.0, 19.0];
}

test "generate timeseries produces snapshots" {
    collector = MetricsCollector();
    t_start = time.time();
    for i in range(10) {
        r = RequestResult(
            endpoint="GET /health",
            service="monolith",
            status=200,
            latency_ms=10.0,
            bytes_received=100,
            timestamp=t_start + (i * 2),
            vu_id=0,
            error_type=None,
        );
        collector.record(r);
    }
    snapshots = collector.generate_timeseries(t_start, interval=10.0);
    assert len(snapshots) == 2;
    assert snapshots[0].total_requests > 0;
    assert snapshots[1].total_requests > 0;
}


# ---------------------------------------------------------------------------
# MetricsCollector — compute_endpoint_stats()
# ---------------------------------------------------------------------------

test "error breakdown http" {
    collector = MetricsCollector();
    collector.record(_result(status=500, error_type=None));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 500": 1};
}

test "error breakdown network" {
    collector = MetricsCollector();
    collector.record(_result(status=0, error_type="TIMEOUT"));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"TIMEOUT": 1};
}

test "success rate calculation" {
    collector = MetricsCollector();
    for _ in range(9) {
        collector.record(_result(status=200));
    }
    collector.record(_result(status=500));
    stats = collector.compute_endpoint_stats();
    assert stats[0].success_rate_pct == 90.0;
}

test "error type http vs network" {
    collector = MetricsCollector();
    collector.record(_result(status=404, error_type=None));
    collector.record(_result(status=0, error_type="CONNECTION_REFUSED"));
    stats = collector.compute_endpoint_stats();
    breakdown = stats[0].error_breakdown;
    assert "expected 200 got 404" in breakdown;
    assert "CONNECTION_REFUSED" in breakdown;
    assert breakdown["expected 200 got 404"] == 1;
    assert breakdown["CONNECTION_REFUSED"] == 1;
}


# ---------------------------------------------------------------------------
# error_breakdown — occurrence labelling
# ---------------------------------------------------------------------------

test "error breakdown no occurrence label when single" {
    collector = MetricsCollector();
    collector.record(_result_with_occurrence(status=500, occurrence=1, total_occurrences=1));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 500": 1};
}

test "error breakdown occurrence label when repeated" {
    collector = MetricsCollector();
    collector.record(_result_with_occurrence(status=422, occurrence=3, total_occurrences=4));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 422 (call #3 of 4)": 1};
}

test "error breakdown occurrence aggregates across vus" {
    collector = MetricsCollector();
    for _ in range(5) {
        collector.record(_result_with_occurrence(status=422, occurrence=3, total_occurrences=4));
    }
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 422 (call #3 of 4)": 5};
}

test "error breakdown different occurrences listed separately" {
    collector = MetricsCollector();
    collector.record(_result_with_occurrence(status=422, occurrence=2, total_occurrences=4));
    collector.record(_result_with_occurrence(status=500, occurrence=4, total_occurrences=4));
    stats = collector.compute_endpoint_stats();
    breakdown = stats[0].error_breakdown;
    assert breakdown == {
        "expected 200 got 422 (call #2 of 4)": 1,
        "expected 200 got 500 (call #4 of 4)": 1,
    };
}

test "error breakdown network error with occurrence" {
    collector = MetricsCollector();
    collector.record(_result_with_occurrence(
        status=0, error_type="TIMEOUT", occurrence=2, total_occurrences=3
    ));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"TIMEOUT (call #2 of 3)": 1};
}


# ---------------------------------------------------------------------------
# ttfb_ms — aggregation
# ---------------------------------------------------------------------------

test "ttfb_ms defaults to zero when not provided" {
    result = _result();
    assert result.ttfb_ms == 0.0;
}

test "endpoint stats averages ttfb_ms across samples" {
    collector = MetricsCollector();
    collector.record(_result(ttfb_ms=10.0));
    collector.record(_result(ttfb_ms=20.0));
    collector.record(_result(ttfb_ms=30.0));
    stats = collector.compute_endpoint_stats();
    assert stats[0].ttfb_ms == 20.0;
}

test "endpoint stats ttfb_ms zero when no samples" {
    collector = MetricsCollector();
    collector.record(_result(status=0, error_type="TIMEOUT", ttfb_ms=0.0));
    stats = collector.compute_endpoint_stats();
    assert stats[0].ttfb_ms == 0.0;
}


# ---------------------------------------------------------------------------
# measured_duration_s() — window derived from samples, not harness clock
# ---------------------------------------------------------------------------

test "measured duration zero when no samples" {
    collector = MetricsCollector();
    assert collector.measured_duration_s() == 0.0;
}

test "measured duration spans first request to last response" {
    collector = MetricsCollector();
    t0 = 1000.0;
    # Requests fired at t0, t0+1, t0+2, each taking 500ms to respond.
    for i in range(3) {
        collector.record(RequestResult(
            endpoint="GET /health",
            service="monolith",
            status=200,
            latency_ms=500.0,
            bytes_received=100,
            timestamp=t0 + i,
            vu_id=0,
            error_type=None,
        ));
    }
    # Window is [t0, (t0+2)+0.5] = 2.5s, independent of any pre-test setup time.
    assert abs(collector.measured_duration_s() - 2.5) < 1e-9;
}

test "measured duration ignores time before the first sample" {
    collector = MetricsCollector();
    # Simulate a large gap (e.g. multiprocess worker spawn/import overhead)
    # between harness start and the first request actually being sent —
    # that gap must not be billed against the measured window.
    t_start = time.time();
    t_first_request = t_start + 5.0;
    collector.record(RequestResult(
        endpoint="GET /health",
        service="monolith",
        status=200,
        latency_ms=100.0,
        bytes_received=100,
        timestamp=t_first_request,
        vu_id=0,
        error_type=None,
    ));
    assert abs(collector.measured_duration_s() - 0.1) < 1e-6;
}
