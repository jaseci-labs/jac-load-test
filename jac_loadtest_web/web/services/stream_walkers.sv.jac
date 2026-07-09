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
import from queue { Empty }
import from typing { Generator }
import from jac_loadtest_cli.config { parse_duration }
import from services.run_walkers { _find_run, _stream_queues }

def _active_vus(run: object, elapsed_s: float) -> int {
    ramp_s = parse_duration(run.ramp_up);
    if ramp_s <= 0 {
        return run.vus;
    }
    frac = min(1.0, elapsed_s / ramp_s);
    return int(round(run.vus * frac));
}

def stream_metrics(run_id: str) -> Generator {
    async def stream() -> Generator[dict, None, None] {
        run = _find_run(run_id);
        if run is None {
            yield {"error": "Run not found"};
            return;
        }
        if run.status != "running" {
            yield {"done": True, "status": run.status};
            return;
        }
        snap_queue = _stream_queues.get(run_id);
        if snap_queue is None {
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
            item["active_vus"] = _active_vus(run, item["elapsed_s"]);
            yield item;
        }
        final = _find_run(run_id);
        yield {"done": True, "status": final.status if final is not None else "unknown"};
    }
    report stream();
}
