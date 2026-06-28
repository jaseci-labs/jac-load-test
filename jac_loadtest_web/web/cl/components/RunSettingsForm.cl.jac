"""RunSettingsForm component.

Phase 6: renders the run configuration form used in RunCreate page.
Sections:
  - VUs (required)
  - Stop condition: Duration or Iterations (required)
  - Advanced (collapsible): ramp-up, workers, RPS cap, think time, timeout
  - Thresholds (collapsible): fail-on-error-rate, fail-on-p95, fail-on-p99,
    abort-on-fail, threshold-start-delay
  - Label (optional)
"""

cl def:pub RunSettingsForm(
    on_submit: object
) -> JsxElement {
    return <div>RunSettingsForm — TODO</div>;
}
