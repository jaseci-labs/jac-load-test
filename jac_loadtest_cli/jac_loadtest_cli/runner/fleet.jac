"""Carrying run state from worker processes to the master (--workers N).

Locust already merges request statistics: every worker reports its stats to the
master, which holds the fleet-wide totals. What it cannot merge is the state our
own code keeps on the RunContext, because each worker builds and fills its own
copy and the master's copy stays empty:

  - suspects         WAF/gateway fingerprints, for the INFRA_BLOCK_SUSPECTED pass
  - auth_failures    accounts that could not log in
  - correlation      per-rule capture / apply / miss counts

When a worker's test stops it sends this state to the master as one custom Locust
message. The master files it by worker id (so a repeated message replaces rather
than double-counts) and folds it into its own context once the run is over, which
is what the report builder reads.

Everything on the wire is plain lists and dicts: Locust serialises messages with
msgpack, which would drop tuples and cannot carry our objects.

No Locust import here: the runner and environment objects are passed in.
"""

import from .context { RunContext }
import from .infra { Suspect }

glob STATE_MESSAGE: str = "jac_loadtest_state";

def pack_state(ctx: RunContext) -> dict[str, any] {
    return {
        "suspects": [[s.timestamp, s.endpoint, s.fingerprint] for s in ctx.suspects],
        "auth_failures": [[account, reason] for (account, reason) in ctx.auth_failures],
        "correlation": ctx.correlation.counts,
    };
}

def absorb_state(ctx: RunContext, state: dict[str, any]) -> None {
    for item in state.get("suspects", []) {
        ctx.suspects.append(
            Suspect(timestamp=float(item[0]), endpoint=str(item[1]), fingerprint=str(item[2]))
        );
    }
    for item in state.get("auth_failures", []) {
        ctx.auth_failures.append((str(item[0]), str(item[1])));
    }
    ctx.correlation.absorb(state.get("correlation", {}));
}

def register_worker(environment: any, ctx: RunContext) -> None {
    # Worker side: ship this process's state to the master when the test stops.
    sent: list[bool] = [False];
    def on_stop(environment: any, **kwargs: any) -> None {
        if sent[0] {
            return;
        }
        sent[0] = True;
        environment.runner.send_message(STATE_MESSAGE, pack_state(ctx));
    }
    environment.events.test_stop.add_listener(on_stop);
}

def register_master(runner: any, ctx: RunContext) -> None {
    # Master side: keep the latest state from each worker, keyed by worker id.
    def on_state(environment: any, msg: any, **kwargs: any) -> None {
        ctx.fleet[str(msg.node_id)] = msg.data;
    }
    runner.register_message(STATE_MESSAGE, on_state);
}

def merge_fleet(ctx: RunContext) -> None {
    # Fold every worker's state into the master's context, once, after the run.
    for state in ctx.fleet.values() {
        absorb_state(ctx, state);
    }
    ctx.fleet.clear();
}
