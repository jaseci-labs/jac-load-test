"""RunControl component.

Phase 6: displayed at the top of RunDetail during an active run.
Contains:
  - RUNNING status badge + elapsed time counter
  - Ramp-up progress ring (live VU count via SSE)
  - Live RPS counter
  - Live error rate badge (green < 1%, yellow 1-5%, red > 5%)
  - Stop button → stop_run sv walker
"""

cl def:pub RunControl(
    run_id: str,
    status: str,
    elapsed_s: float = 0.0,
    active_vus: int = 0,
    rps: float = 0.0,
    error_rate: float = 0.0,
    on_stop: object = None
) -> JsxElement {
    return <div>RunControl ({status}) — TODO</div>;
}
