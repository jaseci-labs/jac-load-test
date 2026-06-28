"""Run detail page  (/workspaces/:id/runs/:run_id).

During run:
  - Status bar: RUNNING badge + elapsed counter
  - Stop button
  - Live RPS counter and error rate badge (SSE)
  - Ramp-up progress ring
  - RPS-over-time chart (live SSE, via MetricsDashboard)
  - p50/p95/p99 latency-over-time chart (live SSE)
  - Per-endpoint latency bar chart (updates every 10s)
  - Error rate gauge

After run completes / stops:
  - Status badge (COMPLETED / STOPPED / FAILED)
  - Threshold pass/fail summary banner
  - Full report (ReportViewer)
  - Download JSON / Download HTML buttons
  - "Re-run with same settings" button
"""

cl def:pub RunDetail() -> JsxElement {
    return <div>RunDetail — TODO</div>;
}
