"""Concurrent multi-protocol run: HTTP entries plus WebSocket/GraphQL scenarios.

Lives in core/ rather than headless.jac so core/process_runner.jac can reach it
without importing the headless entry point back (headless.jac already imports
run_multiprocess from process_runner, so the reverse would be a cycle). Phase 9
put this in headless.jac when only the single-process path needed it; Phase 8d
gave worker processes the same job, so it moves down here and headless.jac
re-exports it.
"""

import asyncio;
import from ..config { LoadTestConfig, parse_duration }
import from .har_parser { HarEntry }
import from .engine { run_all_vus }
import from .correlation { CorrelationRule }
import from .metrics { MetricsCollector }
import from .ws_engine { WsScenarioConfig, run_ws_scenarios }
import from .graphql_engine { GraphQLScenarioConfig, run_graphql_scenarios }
import from ..bridge.auth { AuthProvider }
import from ..bridge.topology { TopologyRouter }

async def _duration_watcher_standalone(duration_s: float, stop_requested: asyncio.Event) {
    # Only used when a run has protocol scenarios (ws/graphql) but no HTTP
    # entries — run_all_vus() already owns duration enforcement whenever it's
    # part of the run (see core/engine.jac: _duration_watcher), and that
    # single stop_requested event is shared with the protocol scenarios too,
    # so this only needs to fire when run_all_vus isn't in the mix at all.
    await asyncio.sleep(duration_s);
    stop_requested.set();
}

async def run_all_protocols(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: TopologyRouter | None,
    auth_provider: AuthProvider | None,
    ws_scenarios: list[WsScenarioConfig],
    graphql_scenarios: list[GraphQLScenarioConfig],
    stop_requested: asyncio.Event,
    t_start: float,
    on_snapshot: object | None,
    vu_id_offset: int = 0,
    pre_authed_tokens: dict[int, str] | None = None,
    pre_resolved_hosts: dict[str, str] | None = None,
    stream_interval: float = 10.0,
    correlation_rules: list[CorrelationRule] | None = None,
) {
    # vu_id_offset / pre_authed_tokens / pre_resolved_hosts / stream_interval are
    # the worker-process path (Phase 8d): the controller slices VUs, pre-resolves
    # DNS and pre-authenticates once, then hands each worker its slice. They keep
    # their single-process defaults so the direct callers (cli.jac, headless.jac)
    # are unaffected.
    tasks = [];
    if entries {
        tasks.append(
            run_all_vus(
                entries, config, metrics,
                topology=topology,
                auth_provider=auth_provider,
                vu_id_offset=vu_id_offset,
                pre_authed_tokens=pre_authed_tokens,
                pre_resolved_hosts=pre_resolved_hosts,
                stream_metrics_callback=on_snapshot,
                t_start=t_start,
                stream_interval=stream_interval,
                stop_requested=stop_requested,
                correlation_rules=correlation_rules,
            )
        );
    }
    # Protocol VUs are numbered above this worker's HTTP VUs so a mixed run can
    # still attribute a sample to the process that produced it. config.vus is
    # this worker's own slice size, not the global total.
    protocol_vu_offset = vu_id_offset + config.vus;
    if ws_scenarios {
        tasks.append(
            run_ws_scenarios(ws_scenarios, metrics, stop_requested, vu_id_offset=protocol_vu_offset)
        );
        protocol_vu_offset += sum(s.vus for s in ws_scenarios);
    }
    if graphql_scenarios {
        tasks.append(
            run_graphql_scenarios(
                graphql_scenarios, metrics, stop_requested, vu_id_offset=protocol_vu_offset
            )
        );
    }

    duration_task: object | None = None;
    if config.duration and not entries {
        # entries present -> run_all_vus already enforces --duration on the
        # shared stop_requested event; standalone protocol runs need their own.
        duration_task = asyncio.create_task(
            _duration_watcher_standalone(parse_duration(config.duration), stop_requested)
        );
    }

    try {
        await asyncio.gather(*tasks);
    } finally {
        if duration_task is not None and not duration_task.done() {
            duration_task.cancel();
            try {
                await duration_task;
            } except asyncio.CancelledError {

            }
        }
    }
}
