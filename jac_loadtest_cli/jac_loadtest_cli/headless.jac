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
import from .core.engine { run_all_vus }
import from .core.metrics { MetricsCollector }
import from .core.process_runner { run_multiprocess }
import from .output.reporter { render_json }
import from .bridge.auth { AuthProvider }
import from .bridge.topology { TopologyRouter }

def run_test_headless(config: LoadTestConfig, on_snapshot: object | None = None) -> dict {
    if config.mode == "monolith" and not config.url {
        raise ValueError("url is required for monolith mode");
    }
    if not config.har_file {
        raise ValueError("har_file is required");
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

    t_start = time.time();
    if config.workers > 1 {
        metrics = run_multiprocess(
            entries, config, topology, auth_provider,
            stream_metrics_callback=on_snapshot,
            t_start=t_start,
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
            )
        );
    }

    duration_s = time.time() - t_start;
    stats = metrics.compute_endpoint_stats(
        t_start=t_start, apdex_t=config.apdex_t, actual_duration_s=duration_s
    );
    snapshots = metrics.generate_timeseries(t_start);
    completion = metrics.completion_percentiles(t_start);

    result_json = render_json(
        stats, config,
        actual_duration_s=duration_s,
        total_rps=metrics.global_rps(duration_s),
        snapshots=snapshots,
        completion_p50_s=completion[0],
        completion_p95_s=completion[1],
        completion_p99_s=completion[2],
    );
    return json.loads(result_json);
}
