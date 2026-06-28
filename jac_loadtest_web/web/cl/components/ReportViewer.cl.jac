"""ReportViewer component.

Phase 6: renders the completed run report inline from results_json.
Contains:
  - Summary table: total requests, RPS, error rate, p50/p95/p99
  - Per-endpoint latency bar chart (Chart.js)
  - RPS-over-time chart (post-run timeseries)
  - Error breakdown table
  - Threshold pass/fail summary banner
  - Download JSON button (browser Blob)
  - Download HTML button (sv walker returns HTML string, browser saves file)
"""

cl def:pub ReportViewer(
    results_json: str,
    passed_thresholds: bool | None = None
) -> JsxElement {
    return <div>ReportViewer — TODO</div>;
}
