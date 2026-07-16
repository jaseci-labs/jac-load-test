import sys;
import asyncio;
import time;
import from .config { from_args, LoadTestConfig }
import from .core.har_parser { parse_har, HarEntry }
import from .core.engine { run_all_vus }
import from .core.metrics { MetricsCollector, percentile }
import from .core.process_runner { run_multiprocess }
import from .output.reporter { render_console, render_json, render_html }
import from .bridge.auth { AuthProvider, AuthenticationError }
import from .bridge.topology { TopologyRouter }
import from rich.console { Console as _Console }

def run(args: object) {
    config: LoadTestConfig = from_args(args);

    if config.mode == "monolith" and not config.url {
        print("Error: --url is required for monolith mode", file=sys.stderr);
        sys.exit(2);
    }

    if not config.har_file {
        print("Error: har_file positional argument is required", file=sys.stderr);
        sys.exit(2);
    }

    entries: list[HarEntry] = [];
    try {
        entries = parse_har(
            config.har_file,
            target_url=config.url if config.mode == "monolith" else None,
            include_static=config.include_static,
            login_path=config.login_path,
        );
    } except (FileNotFoundError, ValueError) as exc {
        print(f"Error: {exc}", file=sys.stderr);
        sys.exit(2);
    }

    if not entries {
        print(
            "Error: no API entries found in HAR file after filtering. "
            "Use --include-static to include static assets.",
            file=sys.stderr,
        );
        sys.exit(2);
    }

    auth_provider: AuthProvider | None = AuthProvider.from_config(config);

    if config.mode == "microservice" and auth_provider is not None and not config.url {
        print(
            "Error: --url (gateway URL) is required when using authentication "
            "in microservice mode",
            file=sys.stderr,
        );
        sys.exit(2);
    }

    try {
        topology = TopologyRouter.from_config(config);
    } except ValueError as exc {
        print(f"Error: {exc}", file=sys.stderr);
        sys.exit(2);
    }

    _console = _Console(stderr=True);

    t_start = time.time();

    try {
        with _console.status(f"Running load test — {config.vus} VUs...") {
            if config.workers > 1 {
                metrics = run_multiprocess(entries, config, topology, auth_provider);
            } else {
                metrics = MetricsCollector(max_samples=config.max_samples);
                asyncio.run(
                    run_all_vus(
                        entries, config, metrics,
                        topology=topology,
                        auth_provider=auth_provider,
                    )
                );
            }
        }
    } except AuthenticationError as exc {
        print(f"Error: {exc}", file=sys.stderr);
        sys.exit(2);
    }

    wall_duration_s = time.time() - t_start;
    duration_s = metrics.measured_duration_s();
    if duration_s <= 0.0 {
        duration_s = wall_duration_s;
    }
    stats = metrics.compute_endpoint_stats(t_start=t_start, apdex_t=config.apdex_t, actual_duration_s=duration_s);
    snapshots = metrics.generate_timeseries(t_start);
    _comp = metrics.completion_percentiles(t_start);
    completion_p50 = _comp[0];
    completion_p95 = _comp[1];
    completion_p99 = _comp[2];

    fmt = config.report_format;

    if fmt == "json" {
        output = render_json(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            snapshots=snapshots,
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        );
        if config.report_out {
            with open(config.report_out, "w", encoding="utf-8") as fh {
                fh.write(output);
            }
            print(f"JSON report written to {config.report_out}");
        } else {
            print(output);
        }
    } elif fmt == "html" {
        if not config.report_out {
            print(
                "Error: --report-out <path> is required for --report-format html",
                file=sys.stderr,
            );
            sys.exit(2);
        }
        output = render_html(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            snapshots=snapshots,
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        );
        with open(config.report_out, "w", encoding="utf-8") as fh {
            fh.write(output);
        }
        print(f"HTML report written to {config.report_out}", file=sys.stderr);
    } else {
        render_console(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        );
    }

    threshold_failures: list[str] = [];
    if metrics.total_count > 0 {
        if config.fail_on_error_rate is not None {
            actual_rate = metrics.error_count / metrics.total_count * 100.0;
            if actual_rate > config.fail_on_error_rate {
                threshold_failures.append(
                    f"error_rate {actual_rate:.1f}% > limit {config.fail_on_error_rate:.1f}%"
                );
            }
        }
        # Transport failures (connection refused, DNS/SSL errors) carry a
        # fabricated 0ms latency and must not enter the percentile pool — a
        # dead target would otherwise report a "perfect" p95/p99 of 0ms and
        # pass the gate. Only samples with a real measured latency count.
        all_latencies = [r.latency_ms for r in metrics._samples if r.latency_valid];
        if (config.fail_on_p95 is not None or config.fail_on_p99 is not None) and not all_latencies {
            threshold_failures.append(
                "no successful requests with measured latency "
                "(all requests failed before a response was received)"
            );
        } elif all_latencies {
            if config.fail_on_p95 is not None {
                p95_val = percentile(all_latencies, 95);
                if p95_val > config.fail_on_p95 {
                    threshold_failures.append(
                        f"p95 {p95_val:.1f}ms > limit {config.fail_on_p95:.1f}ms"
                    );
                }
            }
            if config.fail_on_p99 is not None {
                p99_val = percentile(all_latencies, 99);
                if p99_val > config.fail_on_p99 {
                    threshold_failures.append(
                        f"p99 {p99_val:.1f}ms > limit {config.fail_on_p99:.1f}ms"
                    );
                }
            }
        }
    }
    if threshold_failures {
        for msg in threshold_failures {
            print(f"THRESHOLD FAILED: {msg}", file=sys.stderr);
        }
        sys.exit(1);
    }
}


