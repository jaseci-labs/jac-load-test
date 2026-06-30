"""Load-test run walkers.

Phase 6 walkers to implement:
  - create_run(workspace_id, vus, duration, iterations, ramp_up,
               workers, rps, think_time, think_time_scale, timeout,
               fail_on_error_rate?, fail_on_p95?, fail_on_p99?,
               abort_on_fail, threshold_start_delay, label?) -> LoadTestRun
  - start_run(run_id) -> {stream_url}
        Builds LoadTestConfig via LoadTestConfig.from_dict() — no jac.toml
        lookup. Runs engine in a background asyncio task. Sets status = "running".
  - stop_run(run_id) -> {ok}
        Triggers graceful two-signal shutdown. Sets status = "stopped".
        Partial report is rendered from collected metrics.
  - get_run(run_id) -> LoadTestRun
  - list_runs(workspace_id) -> list[LoadTestRun]
"""
