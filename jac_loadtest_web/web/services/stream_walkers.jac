"""SSE streaming endpoint for live metrics during a load-test run.

A plain (authenticated) `def` returning a Generator — not a walker, since
streaming needs `report stream();` (see jac-sv-streaming). Consumed via a
raw `fetch("/function/stream_metrics", ...)` + manual SSE frame parsing on
the client (RPC stubs can't consume streams, and EventSource can't carry
an Authorization header or a POST body).

Auth note: this reads run/queue state keyed by run_id directly rather than
through [root --> ], so it explicitly re-checks that the run belongs to the
caller's own root (via the same _find_run ownership scoping run_walkers
uses) before streaming anything — a bare id lookup would otherwise leak
another user's live metrics to anyone who guessed their run_id.

SSE event schema (one frame per snapshot tick, ~10s apart — see
jac_loadtest_cli.core.engine's default stream_interval):
  {
    "elapsed_s": float,
    "rps": float,
    "error_rate": float,
    "active_vus": int,      # linear-ramp estimate from vus/ramp_up, not measured
    "p50_ms": float,
    "p95_ms": float,
    "p99_ms": float,
    "total_requests": int
  }
Final frame: {"done": true, "status": "completed"|"stopped"|"failed"}
"""

import asyncio;
import logging;
import from queue { Empty }
import from typing { Generator }
import from services.run_walkers { _find_run, _stream_queues }

def stream_metrics(run_id: str) -> Generator {
    async def stream() -> Generator[dict, None, None] {
        run = _find_run(run_id);
        if run is None {
            logging.getLogger("jac_loadtest_web.stream").info(
                f"stream_metrics for run {run_id}: run not found at connection start"
            );
            yield {"error": "Run not found"};
            return;
        }
        if run.status != "running" {
            # TEMP DIAGNOSTIC: this fires immediately on connection if the run
            # somehow already looks non-"running" the instant the SSE request
            # is handled — before any ticks, before the true completion path.
            logging.getLogger("jac_loadtest_web.stream").info(
                f"stream_metrics for run {run_id}: EARLY EXIT (status check) — "
                f"run.status={run.status} at connection start"
            );
            yield {"done": True, "status": run.status};
            return;
        }
        snap_queue = _stream_queues.get(run_id);
        if snap_queue is None {
            # TEMP DIAGNOSTIC: this fires if _stream_queues has no entry for
            # this run_id even though run.status == "running" — i.e. either
            # start_run never populated it, or something cleared it early.
            logging.getLogger("jac_loadtest_web.stream").info(
                f"stream_metrics for run {run_id}: EARLY EXIT (no queue) — "
                f"run.status={run.status}, _stream_queues keys={list(_stream_queues.keys())}"
            );
            yield {"done": True, "status": run.status};
            return;
        }
        while True {
            try {
                item = snap_queue.get_nowait();
            } except Empty {
                await asyncio.sleep(0.3);
                continue;
            }
            if item is None {
                break;
            }
            yield item;
        }
        final = _find_run(run_id);
        final_status = final.status if final is not None else "unknown";
        # TEMP DIAGNOSTIC: confirming whether this long-lived generator's own
        # execution context re-reads the anchor fresh (sees the background
        # thread's committed status) or returns a stale copy it already
        # cached from the first _find_run call at the top of this function.
        logging.getLogger("jac_loadtest_web.stream").info(
            f"stream_metrics done-frame for run {run_id}: final_status={final_status}"
        );
        yield {"done": True, "status": final_status};
    }
    report stream();
}
