"""Unit tests for core/metrics.jac — no network, no I/O."""

import time;
import from jac_loadtest_cli.core.metrics {
    RequestResult,
    MetricsCollector,
    percentile,
    normalize_path,
    extract_trace_id
}


def _result(
    endpoint: str = "POST /walker/search",
    status: int = 200,
    latency_ms: float = 50.0,
    error_type: str | None = None,
    vu_id: int = 0,
    service: str = "monolith",
    ttfb_ms: float = 0.0,
    trace_id: str | None = None,
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
        trace_id=trace_id,
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
# extract_trace_id
# ---------------------------------------------------------------------------

test "extract trace id from w3c traceparent header" {
    headers = {"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"};
    assert extract_trace_id(headers) == "4bf92f3577b34da6a3ce929d0e0e4736";
}

test "extract trace id falls back to x-request-id" {
    headers = {"x-request-id": "req-abc-123"};
    assert extract_trace_id(headers) == "req-abc-123";
}

test "extract trace id prefers traceparent over other headers" {
    headers = {
        "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "x-request-id": "req-abc-123",
    };
    assert extract_trace_id(headers) == "4bf92f3577b34da6a3ce929d0e0e4736";
}

test "extract trace id is case insensitive on header name" {
    import from multidict { CIMultiDict }
    # Mirrors resp.headers in engine.jac, which is a real CIMultiDictProxy —
    # a plain dict wouldn't exercise case-insensitive lookup at all.
    headers = CIMultiDict();
    headers["X-Request-Id"] = "req-abc-123";
    assert extract_trace_id(headers) == "req-abc-123";
}

test "extract trace id returns none when no known header present" {
    headers = {"content-type": "application/json"};
    assert extract_trace_id(headers) is None;
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


# ---------------------------------------------------------------------------
# B3 — eviction is counted and warned about, not silent
# ---------------------------------------------------------------------------

test "samples evicted stays zero below the buffer limit" {
    collector = MetricsCollector(max_samples=5);
    for _ in range(5) {
        collector.record(_result());
    }
    assert collector.samples_evicted == 0;
}

test "samples evicted counts every record past the buffer limit" {
    collector = MetricsCollector(max_samples=5);
    for _ in range(20) {
        collector.record(_result());
    }
    assert collector.samples_evicted == 15;
}

test "eviction warning printed once on stderr when eviction begins" {
    import io;
    import from contextlib { redirect_stderr }
    collector = MetricsCollector(max_samples=3);
    buf = io.StringIO();
    with redirect_stderr(buf) {
        for _ in range(10) {
            collector.record(_result());
        }
    }
    stderr_text = buf.getvalue();
    assert stderr_text.count("Warning:") == 1;
    assert "evicted" in stderr_text;
}

test "no eviction warning printed when run stays within the buffer" {
    import io;
    import from contextlib { redirect_stderr }
    collector = MetricsCollector(max_samples=100);
    buf = io.StringIO();
    with redirect_stderr(buf) {
        for _ in range(10) {
            collector.record(_result());
        }
    }
    assert buf.getvalue() == "";
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

test "generate interval timeseries reports per-bucket counts, not running totals" {
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
    cumulative = collector.generate_timeseries(t_start, interval=10.0);
    interval = collector.generate_interval_timeseries(t_start, interval=10.0);
    assert len(interval) == len(cumulative);
    # 10 requests spread evenly across 2 buckets of 10s -> 5 per bucket.
    # Cumulative keeps growing; interval resets each bucket.
    assert interval[0].total_requests == 5;
    assert interval[1].total_requests == 5;
    assert cumulative[0].total_requests == 5;
    assert cumulative[1].total_requests == 10;
}

test "generate interval timeseries isolates a burst confined to the final bucket" {
    collector = MetricsCollector();
    t_start = time.time();
    # Bucket 0 (0-10s): 10 quiet, fast requests.
    for i in range(10) {
        collector.record(RequestResult(
            endpoint="GET /health", service="monolith", status=200,
            latency_ms=10.0, bytes_received=100,
            timestamp=t_start + i, vu_id=0, error_type=None,
        ));
    }
    # Bucket 1 (10-20s): a burst of slow requests only.
    for i in range(10) {
        collector.record(RequestResult(
            endpoint="GET /health", service="monolith", status=200,
            latency_ms=5000.0, bytes_received=100,
            timestamp=t_start + 10 + i, vu_id=0, error_type=None,
        ));
    }
    cumulative = collector.generate_timeseries(t_start, interval=10.0);
    interval = collector.generate_interval_timeseries(t_start, interval=10.0);
    # Cumulative p50 over all 20 samples is diluted by the quiet first bucket
    # (half the history is still the fast 10ms requests).
    assert cumulative[1].p50_ms < 5000.0;
    # The windowed view isolates the burst: p50 for bucket 1 alone is the
    # burst's own latency, not blended with the earlier quiet traffic.
    assert interval[1].p50_ms == 5000.0;
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

test "error samples collect trace ids for failed requests" {
    collector = MetricsCollector();
    collector.record(_result(status=500, error_type=None, trace_id="trace-a"));
    collector.record(_result(status=500, error_type=None, trace_id="trace-b"));
    collector.record(_result(status=200, error_type=None, trace_id="trace-ok"));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_samples == {"expected 200 got 500": ["trace-a", "trace-b"]};
}

test "error samples omit requests with no trace id" {
    collector = MetricsCollector();
    collector.record(_result(status=500, error_type=None, trace_id=None));
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"expected 200 got 500": 1};
    assert stats[0].error_samples == {};
}

test "error samples capped at a small number per error class" {
    collector = MetricsCollector();
    for i in range(10) {
        collector.record(_result(status=500, error_type=None, trace_id=f"trace-{i}"));
    }
    stats = collector.compute_endpoint_stats();
    assert stats[0].error_breakdown["expected 200 got 500"] == 10;
    assert len(stats[0].error_samples["expected 200 got 500"]) == 3;
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

test "endpoint stats exclude fabricated zero latency of connection refused" {
    collector = MetricsCollector();
    collector.record(RequestResult(
        endpoint="GET /health",
        service="monolith",
        status=0,
        latency_ms=0.0,
        bytes_received=0,
        timestamp=time.time(),
        vu_id=0,
        error_type="CONNECTION_REFUSED",
        latency_valid=False,
    ));
    collector.record(RequestResult(
        endpoint="GET /health",
        service="monolith",
        status=200,
        latency_ms=50.0,
        bytes_received=100,
        timestamp=time.time(),
        vu_id=0,
        error_type=None,
    ));
    stats = collector.compute_endpoint_stats();
    assert stats[0].total_requests == 2;
    assert stats[0].error_count == 1;
    assert stats[0].p50_ms == 50.0;
    assert stats[0].min_ms == 50.0;
    assert stats[0].max_ms == 50.0;
}

test "all-failure run has empty latency pool, not a fabricated zero" {
    collector = MetricsCollector();
    for _ in range(5) {
        collector.record(RequestResult(
            endpoint="GET /health",
            service="monolith",
            status=0,
            latency_ms=0.0,
            bytes_received=0,
            timestamp=time.time(),
            vu_id=0,
            error_type="CONNECTION_REFUSED",
            latency_valid=False,
        ));
    }
    stats = collector.compute_endpoint_stats();
    assert stats[0].total_requests == 5;
    assert stats[0].error_count == 5;
    assert stats[0].p50_ms == 0.0;  # percentile() of an empty list, not a real measurement
    assert stats[0].latencies == [];
}


# ---------------------------------------------------------------------------
# Phase 9 — protocol field / (protocol, endpoint) grouping
# ---------------------------------------------------------------------------

test "request result protocol defaults to http" {
    result = _result();
    assert result.protocol == "http";
}

test "endpoint stats protocol defaults to http and matches the samples" {
    collector = MetricsCollector();
    collector.record(_result());
    stats = collector.compute_endpoint_stats();
    assert stats[0].protocol == "http";
}

test "compute endpoint stats groups by protocol and endpoint separately" {
    collector = MetricsCollector();
    collector.record(_result(endpoint="/api/data", latency_ms=10.0));
    collector.record(_result(endpoint="/api/data", latency_ms=20.0));
    ws_result = _result(endpoint="/api/data", latency_ms=500.0);
    ws_result.protocol = "ws";
    collector.record(ws_result);
    stats = collector.compute_endpoint_stats();
    # Same endpoint string, two protocols -> two separate rows, not one
    # blended row averaging an HTTP p50 with a WS p50.
    assert len(stats) == 2;
    by_protocol = {s.protocol: s for s in stats};
    assert by_protocol["http"].total_requests == 2;
    assert by_protocol["ws"].total_requests == 1;
    assert by_protocol["ws"].p50_ms == 500.0;
}

test "compute endpoint stats keeps identical endpoints under different protocols independent" {
    collector = MetricsCollector();
    for _ in range(3) {
        r = _result(endpoint="/subscribe", status=200);
        r.protocol = "graphql";
        collector.record(r);
    }
    for _ in range(2) {
        r = _result(endpoint="/subscribe", status=500);
        r.protocol = "graphql";
        collector.record(r);
    }
    http_result = _result(endpoint="/subscribe", status=200);
    collector.record(http_result);
    stats = collector.compute_endpoint_stats();
    by_protocol = {s.protocol: s for s in stats};
    assert by_protocol["graphql"].total_requests == 5;
    assert by_protocol["graphql"].error_count == 2;
    assert by_protocol["http"].total_requests == 1;
    assert by_protocol["http"].error_count == 0;
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
