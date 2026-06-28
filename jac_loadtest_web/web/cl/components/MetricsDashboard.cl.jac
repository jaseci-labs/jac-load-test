"""MetricsDashboard component.

Phase 6: subscribes to the SSE stream from stream_metrics(run_id) on mount,
unsubscribes when run status becomes terminal or the component unmounts.

Contains:
  - LatencyChart (p50/p95/p99 over time, live)
  - RPS-over-time line chart (live)
  - Per-endpoint latency bar chart (updates every 10s)
  - Error rate gauge
"""

cl def:pub MetricsDashboard(
    run_id: str,
    stream_url: str
) -> JsxElement {
    return <div>MetricsDashboard — TODO</div>;
}
