"""Canonical headless entry point into the engine — no CLI context required.

Unlike cli.jac (argparse, Rich console, sys.exit), this module raises plain
exceptions and returns plain data. It exists so an embedder such as the sv
walker can run a full load test and get a JSON-serialisable result back
without importing anything CLI-shaped.
"""

import time;
import asyncio;
import json;
import from .config { LoadTestConfig }
import from .core.har_parser { parse_har }
import from .core.engine { run_all_vus, parse_assert_json }
import from .core.metrics { MetricsCollector }
import from .core.process_runner { run_multiprocess }
import from .output.reporter { render_json, render_html, parse_slo_map }
import from .bridge.auth { AuthProvider }
import from .bridge.topology { TopologyRouter }

def run_test_headless(
    config: LoadTestConfig,
    on_snapshot: object | None = None,
    stop_event: object | None = None,
    on_html_report: object | None = None,
) -> dict {
    if config.mode == "monolith" and not config.url {
        raise ValueError("url is required for monolith mode");
    }
    if not config.har_file {
        raise ValueError("har_file is required");
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

    entries = parse_har(
        config.har_file,
        target_url=config.url if config.mode == "monolith" else None,
        include_static=config.include_static,
        login_path=config.login_path,
    );
    if not entries {
        raise ValueError(
            "no API entries found in HAR file after filtering; "
            "set include_static=True to include static assets"
        );
    }

    auth_provider = AuthProvider.from_config(config);
    if config.mode == "microservice" and auth_provider is not None and not config.url {
        raise ValueError(
            "url (gateway URL) is required when using authentication in microservice mode"
        );
    }

    topology = TopologyRouter.from_config(config);
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
        );
    } else {
        metrics = MetricsCollector(max_samples=config.max_samples);
        asyncio.run(
            run_all_vus(
                entries, config, metrics,
                topology=topology,
                auth_provider=auth_provider,
                stream_metrics_callback=on_snapshot,
                t_start=t_start,
                stop_requested=stop_event,
            )
        );
    }

    wall_duration_s = time.time() - t_start;
    duration_s = metrics.measured_duration_s();
    if duration_s <= 0.0 {
        duration_s = wall_duration_s;
    }
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
