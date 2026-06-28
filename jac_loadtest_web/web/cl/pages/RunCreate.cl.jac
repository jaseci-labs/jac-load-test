"""Run creation page  (/workspaces/:id/runs/new).

Shows workspace-inherited settings (read-only) and run-specific settings:
  Required:  VUs, stop condition (duration or iterations)
  Advanced:  ramp-up, workers, RPS cap, think time, timeout
  Thresholds: fail-on-error-rate, fail-on-p95, fail-on-p99,
              abort-on-fail, threshold-start-delay
  Label: optional freetext

On "Start Run": create_run → start_run → redirect to /workspaces/:id/runs/:run_id.
"""

cl def:pub RunCreate() -> JsxElement {
    return <div>RunCreate — TODO</div>;
}
