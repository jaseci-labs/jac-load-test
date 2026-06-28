"""LatencyChart component.

Phase 6: renders a Chart.js line chart showing p50/p95/p99 latency over time.
Used in MetricsDashboard (live SSE) and in ReportViewer (post-run timeseries).
"""

cl def:pub LatencyChart(
    snapshots: list,
    title: str = "Latency over time"
) -> JsxElement {
    return <div>LatencyChart — TODO</div>;
}
