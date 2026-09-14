"""Canonical headless entry point into the engine — no CLI context required.

Unlike cli.jac (argparse, Rich console, sys.exit), this module raises plain
exceptions and returns plain data. It exists so an embedder such as the sv
walker can run a full load test and get a JSON-serialisable result back
without importing anything CLI-shaped.
"""

import time;
import asyncio;
import json;
import from .config { LoadTestConfig, parse_duration }
import from .core.har_parser { parse_har, HarEntry }
import from .core.engine { run_all_vus, parse_assert_json }
import from .core.metrics { MetricsCollector }
import from .core.process_runner { run_multiprocess }
import from .core.ws_engine { parse_ws_scenarios, run_ws_scenarios, WsScenarioConfig, scenarios_from_har_entries as _ws_scenarios_from_har }
import from .core.graphql_engine { parse_graphql_scenarios, run_graphql_scenarios, GraphQLScenarioConfig, scenarios_from_har_entries as _graphql_scenarios_from_har }
import from .output.reporter { render_json, render_html, parse_slo_map }
import from .bridge.auth { AuthProvider }
import from .bridge.topology { TopologyRouter }
# Re-exported: run_all_protocols moved to core/ in Phase 8d so worker processes
# could reach it without importing this module back. Callers that already import
# it from here keep working.
import from .core.protocols { run_all_protocols }
import from .core.correlation { build_rules }
import from .core.parameterize { parse_param_rules }
import from .core.infra_block { classify as classify_infra_blocks }

def run_test_headless(
    config: LoadTestConfig,
    on_snapshot: object | None = None,
    stop_event: object | None = None,
    on_html_report: object | None = None,
) -> dict {
    ws_scenarios = parse_ws_scenarios(config.ws_scenarios);
    graphql_scenarios = parse_graphql_scenarios(config.graphql_scenarios);

    if not config.har_file and not ws_scenarios and not graphql_scenarios {
        raise ValueError("har_file is required");
    }
    if config.har_file and config.mode == "monolith" and not config.url {
        raise ValueError("url is required for monolith mode");
    }
    if config.open_loop and config.rps <= 0 {
        raise ValueError(
            "open_loop requires rps to be set to a positive value (fixed arrival rate)"
        );
    }
    if config.step_load {
        if config.open_loop {
            raise ValueError("step_load cannot be combined with open_loop");
        }
        if config.workers > 1 {
            raise ValueError(
                "step_load only supports workers=1 — per-worker VU ramps cannot "
                "currently be merged into one step-by-step report"
            );
        }
        if config.step_vus <= 0 {
            raise ValueError("step_load requires step_vus to be set to a positive value");
        }
        has_threshold = (
            config.fail_on_error_rate is not None
            or config.fail_on_p95 is not None
            or config.fail_on_p99 is not None
        );
        if config.step_max_vus <= 0 and not has_threshold {
            raise ValueError(
                "step_load requires step_max_vus or at least one of "
                "fail_on_error_rate/fail_on_p95/fail_on_p99 — otherwise the ramp "
                "has no stopping condition"
            );
        }
    }

    entries: list[HarEntry] = [];
    auth_provider = None;
    topology = None;
    if config.har_file {
        all_entries = parse_har(
            config.har_file,
            target_url=config.url if config.mode == "monolith" else None,
            include_static=config.include_static,
            login_path=config.login_path,
        );
        if not all_entries {
            raise ValueError(
                "no API entries found in HAR file after filtering; "
                "set include_static=True to include static assets"
            );
        }

        # Phase 9 — core/har_parser.jac tags each entry with the protocol it
        # was recorded over (http_parser.jac: HarEntry.protocol). WebSocket
        # connections ("ws") and GraphQL subscriptions ("graphql_ws") are
        # pulled out here and auto-converted into scenario configs replayed
        # by ws_engine/graphql_engine instead of core/engine.jac; plain HTTP
        # and GraphQL-over-HTTP ("http"/"graphql") entries still replay
        # through run_all_vus exactly as before. Auto-detected scenarios are
        # merged ahead of any explicitly-configured ones — vus/iterations
        # mirror the main run's shape (config.vus/config.iterations) since
        # there's no per-scenario config to read them from.
        entries = [e for e in all_entries if e.protocol in ("http", "graphql")];
        auto_ws = _ws_scenarios_from_har(all_entries, vus=config.vus, iterations=config.iterations);
        auto_graphql = _graphql_scenarios_from_har(all_entries, vus=config.vus, iterations=config.iterations);
        ws_scenarios = auto_ws + ws_scenarios;
        graphql_scenarios = auto_graphql + graphql_scenarios;

        if entries {
            auth_provider = AuthProvider.from_config(config);
            if config.mode == "microservice" and auth_provider is not None and not config.url {
                raise ValueError(
                    "url (gateway URL) is required when using authentication in microservice mode"
                );
            }

            topology = TopologyRouter.from_config(config);
        }
    }

    # announce=False: an embedder gets the rules back in the result rather than
    # on the controller's stderr.
    correlation_rules = build_rules(
        all_entries if config.har_file else [],
        config.correlate, config.auto_correlate, announce=False,
    );

    param_rules = parse_param_rules(config.param);

    slo_overrides = parse_slo_map(config.slo_map);
    # Parsed only to fail fast on malformed assert_json before the run
    # starts; core/engine.jac re-parses config.assert_json per-request.
    parse_assert_json(config.assert_json);

    t_start = time.time();
    if config.workers > 1 {
        metrics = run_multiprocess(
            entries, config, topology, auth_provider,
            stream_metrics_callback=on_snapshot,
            t_start=t_start,
            stop_requested=stop_event,
            ws_scenarios=ws_scenarios,
            graphql_scenarios=graphql_scenarios,
            correlation_rules=correlation_rules,
            param_rules=param_rules,
        );
    } else {
        metrics = MetricsCollector(max_samples=config.max_samples);
        stop_requested = stop_event if stop_event is not None else asyncio.Event();
        asyncio.run(
            run_all_protocols(
                entries, config, metrics,
                topology=topology,
                auth_provider=auth_provider,
                ws_scenarios=ws_scenarios,
                graphql_scenarios=graphql_scenarios,
                stop_requested=stop_requested,
                t_start=t_start,
                on_snapshot=on_snapshot,
                correlation_rules=correlation_rules,
                param_rules=param_rules,
            )
        );
    }

    wall_duration_s = time.time() - t_start;
    duration_s = metrics.measured_duration_s();
    if duration_s <= 0.0 {
        duration_s = wall_duration_s;
    }
    # Phase 8a — reclassify infrastructure blocks before any statistic is
    # computed. It cannot be decided per request: the evidence is one canned body
    # appearing across unrelated endpoints, which only exists once the run is
    # over. Nothing is discarded; the samples are relabelled and counted
    # separately so they stop inflating the application error rate.
    infra_blocked = classify_infra_blocks(
        list(metrics._samples), config.infra_block_threshold, t_start
    );

    stats = metrics.compute_endpoint_stats(
        t_start=t_start, apdex_t=config.apdex_t, actual_duration_s=duration_s
    );
    snapshots = metrics.generate_timeseries(t_start, actual_duration_s=duration_s);
    interval_snapshots = metrics.generate_interval_timeseries(t_start, actual_duration_s=duration_s);
    completion = metrics.completion_percentiles(t_start);

    result_json = render_json(
        stats, config,
        actual_duration_s=duration_s,
        total_rps=metrics.global_rps(duration_s),
        snapshots=snapshots,
        interval_snapshots=interval_snapshots,
        completion_p50_s=completion[0],
        completion_p95_s=completion[1],
        completion_p99_s=completion[2],
        samples_evicted=metrics.samples_evicted,
        step_results=metrics.step_results,
        slo_overrides=slo_overrides,
    );

    if on_html_report is not None {
        html_report = render_html(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            snapshots=snapshots,
            interval_snapshots=interval_snapshots,
            completion_p50_s=completion[0],
            completion_p95_s=completion[1],
            completion_p99_s=completion[2],
            samples_evicted=metrics.samples_evicted,
        step_results=metrics.step_results,
        slo_overrides=slo_overrides,
        );
        on_html_report(html_report);
    }

    return json.loads(result_json);
}
