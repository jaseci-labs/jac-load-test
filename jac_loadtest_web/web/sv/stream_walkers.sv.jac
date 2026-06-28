"""SSE streaming walker for live metrics during a load-test run.

Phase 6 walkers to implement:
  - stream_metrics(run_id) -> SSE stream
        Keeps an SSE connection open while run status == "running".
        The on_snapshot callback registered in run_test_headless() writes
        each StatsSnapshot into an asyncio queue. This walker reads from
        the queue and sends  data: {json}\n\n  events every second.
        Connection closes when run status becomes terminal
        (completed / failed / stopped).

SSE event schema (one per tick):
  {
    "rps": float,
    "error_rate": float,
    "active_vus": int,
    "p50_ms": float,
    "p95_ms": float,
    "p99_ms": float,
    "elapsed_s": float,
    "endpoints": [{"path": str, "p95_ms": float, "rps": float}]
  }
"""
