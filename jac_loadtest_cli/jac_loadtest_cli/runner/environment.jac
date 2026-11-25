"""Builds and drives a Locust run in-process.

This is the only module that creates a Locust Environment. It parses the HAR,
builds the RunContext, starts a local runner, waits for the run to end (every
user finished its iterations, the duration elapsed, or the stop signal fired),
and returns the Environment so the output layer can read Locust's own stats.

Locust monkey-patches the standard library with gevent when it is imported, so
this package must never be imported by code that has to stay on plain asyncio.
"""

import time;
import gevent;
import from urllib.parse { urlparse }
import from locust.env { Environment }
import from ..config { LoadTestConfig, parse_duration }
import from ..core.har_parser { parse_har, HarEntry }
import from ..core.correlation { build_rules }
import from ..core.parameterize { parse_param_rules }
import from ..bridge.auth { parse_accounts, Credential }
import from ..bridge.body_check { baseline_shapes }
import from ..bridge.topology { TopologyRouter }
import from ..core.ws_engine { parse_ws_scenarios }
import from ..core.graphql_engine { parse_graphql_scenarios }
import from .context { RunContext, set_context }
import from .users { HarUser }
import from .checks { parse_poll_rules, parse_assert_json }
import from .live { Snapshot, take_snapshot, breached, aggregate }
import from .steps { StepResult, Mark, mark_of, judge_step, next_vus, validate_step_config }

obj RunHandle {
    has env: any;
    has context: RunContext;
    has wall_s: float = 0.0;
    has started_at: float = 0.0;
    has steps: list[StepResult] = [];
    has snapshots: list[Snapshot] = [];
    # Why the run ended early, if it did: "duration" | "stopped" | "threshold" | "".
    has ended_by: str = "";
}

def _origin(url: str) -> str {
    p = urlparse(url);
    return f"{p.scheme}://{p.netloc}";
}

def build_context(config: LoadTestConfig) -> RunContext {
    if config.har_file and config.mode == "monolith" and not config.url {
        raise ValueError("url is required for monolith mode");
    }
    all_entries: list[HarEntry] = [];
    if config.har_file {
        all_entries = parse_har(
            config.har_file,
            target_url=config.url if config.mode == "monolith" else None,
            include_static=config.include_static,
            login_path=config.login_path,
        );
        if not all_entries {
            raise ValueError(
                "no API entries found after filtering; "
                "set include_static=True to include static assets"
            );
        }
    }
    # Fail fast on malformed assertions before any user starts.
    parse_assert_json(config.assert_json);
    entries = list(all_entries);
    # Explicitly configured scenarios run after the recorded flow on each
    # iteration, as extra entries; their per-scenario `vus` no longer applies
    # because every Locust user replays the whole flow.
    for sc in parse_ws_scenarios(config.ws_scenarios) {
        entries.append(HarEntry(
            method="GET", url=sc.url, headers=dict(sc.headers), body=None, body_mime=None,
            think_time_ms=sc.think_time_ms, is_login=False, original_url=sc.url,
            protocol="ws", ws_messages=list(sc.messages),
        ));
    }
    for sc in parse_graphql_scenarios(config.graphql_scenarios) {
        entries.append(HarEntry(
            method="GET", url=sc.url, headers=dict(sc.headers), body=None, body_mime=None,
            think_time_ms=0.0, is_login=False, original_url=sc.url, protocol="graphql_ws",
            graphql_query=sc.query, graphql_variables=sc.variables,
            graphql_operation_name=sc.operation_name,
        ));
    }
    if not entries {
        raise ValueError("har_file (or ws_scenarios / graphql_scenarios) is required");
    }
    accounts = parse_accounts(config.accounts);
    if not accounts and config.username and config.password {
        accounts = [Credential(username=config.username, password=config.password)];
    }
    if config.mode == "microservice" and accounts and not config.url {
        raise ValueError(
            "url (gateway URL) is required when using authentication in microservice mode"
        );
    }
    return RunContext(
        config=config,
        entries=entries,
        accounts=accounts,
        rules=build_rules(all_entries, config.correlate, config.auto_correlate, announce=False),
        param_rules=parse_param_rules(config.param),
        baseline=baseline_shapes(entries),
        topology=TopologyRouter.from_config(config),
        poll_rules=parse_poll_rules(config.poll_until, config.poll_error_until),
    );
}

def run_locust(
    config: LoadTestConfig,
    stop_event: any = None,
    on_snapshot: any = None,
    snapshot_interval_s: float = 10.0,
) -> RunHandle {
    validate_step_config(config);
    ctx = build_context(config);
    set_context(ctx);

    timeout_s = parse_duration(config.timeout);
    setattr(HarUser, "network_timeout", timeout_s);
    setattr(HarUser, "connection_timeout", timeout_s);

    host = config.url or _origin(ctx.entries[0].url);
    env = Environment(user_classes=[HarUser], host=host);
    runner = env.create_local_runner();

    ramp_s = parse_duration(config.ramp_up) if config.ramp_up else 0.0;
    spawn_rate = float(config.vus) / ramp_s if ramp_s > 0 else float(config.vus);

    t0 = time.time();
    runner.start(config.vus, spawn_rate=spawn_rate);
    deadline = t0 + parse_duration(config.duration) if config.duration else None;
    grace_s = parse_duration(config.threshold_start_delay) if config.threshold_start_delay else 0.0;
    snapshots: list[Snapshot] = [];
    steps: list[StepResult] = [];
    step_len = parse_duration(config.step_duration) if config.step_load else 0.0;
    step_no = 1;
    step_vus_now = config.vus;
    step_t = t0;
    step_mark = Mark();
    next_snap = t0 + snapshot_interval_s;
    ended_by = "";

    # Give the spawner a moment to create the first users before watching
    # user_count; "spawning" covers the ramp.
    gevent.sleep(0.2);
    while runner.state == "spawning" or runner.user_count > 0 {
        now = time.time();
        if deadline is not None and now >= deadline {
            ended_by = "duration";
            break;
        }
        if stop_event is not None and stop_event.is_set() {
            ended_by = "stopped";
            break;
        }
        if now >= next_snap {
            snap = take_snapshot(env, now - t0);
            snapshots.append(snap);
            if on_snapshot is not None {
                on_snapshot(snap);
            }
            next_snap = now + snapshot_interval_s;
        }
        if config.step_load and now - step_t >= step_len {
            mark_now = mark_of(aggregate(env));
            res = judge_step(config, step_no, step_vus_now, step_t - t0, now - t0, step_mark, mark_now);
            steps.append(res);
            if res.breached {
                print(f"Step-load: threshold breached at {step_vus_now} VUs (step {step_no}) -- stopping ramp and test.");
                ended_by = "threshold";
                break;
            }
            bigger = next_vus(config, step_vus_now);
            if bigger > step_vus_now {
                step_vus_now = bigger;
                runner.start(step_vus_now, spawn_rate=float(step_vus_now));
            }
            step_no += 1;
            step_t = now;
            step_mark = mark_now;
        }
        if config.abort_on_fail and not config.step_load and now - t0 >= grace_s and breached(config, env) {
            print("Threshold breached -- stopping test early (--abort-on-fail).");
            ended_by = "threshold";
            break;
        }
        gevent.sleep(0.1);
    }
    runner.quit();
    wall = time.time() - t0;
    # Always end with a final point so short runs still have a time series.
    snapshots.append(take_snapshot(env, wall));
    return RunHandle(env=env, context=ctx, wall_s=wall, started_at=t0, steps=steps, snapshots=snapshots, ended_by=ended_by);
}
