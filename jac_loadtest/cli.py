# JacMetaImporter must be registered before any jac_scale import.
# jac-scale's microservice modules are compiled Jac; without this the import fails.
from jaclang.meta_importer import JacMetaImporter
import sys

if not any(isinstance(f, JacMetaImporter) for f in sys.meta_path):
    sys.meta_path.insert(0, JacMetaImporter())


def run(args: object) -> None:
    import asyncio
    import time

    from jac_loadtest.config import from_args
    from jac_loadtest.core.har_parser import parse_har
    from jac_loadtest.core.engine import run_all_vus
    from jac_loadtest.core.metrics import MetricsCollector
    from jac_loadtest.output.reporter import render_console, render_json, render_html

    config = from_args(args)

    # --url required for monolith mode; optional for microservice (becomes fallback)
    if config.mode == "monolith" and not config.url:
        print("Error: --url is required for monolith mode", file=sys.stderr)
        sys.exit(2)

    if not config.har_file:
        print("Error: har_file positional argument is required", file=sys.stderr)
        sys.exit(2)

    # Parse HAR — monolith rewrites all URLs to config.url; microservice keeps originals
    try:
        entries = parse_har(
            config.har_file,
            target_url=config.url if config.mode == "monolith" else None,
            include_static=config.include_static,
            login_path=config.login_path,
        )
    except (FileNotFoundError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)

    if not entries:
        print(
            "Error: no API entries found in HAR file after filtering. "
            "Use --include-static to include static assets.",
            file=sys.stderr,
        )
        sys.exit(2)

    from jac_loadtest.bridge.auth import AuthProvider, AuthenticationError

    auth_provider = AuthProvider.from_config(config)

    # In microservice mode, auth still goes to the gateway (--url); require it when set
    if config.mode == "microservice" and auth_provider is not None and not config.url:
        print(
            "Error: --url (gateway URL) is required when using authentication "
            "in microservice mode",
            file=sys.stderr,
        )
        sys.exit(2)

    # Build topology router — validates service map JSON and service URL availability
    from jac_loadtest.bridge.topology import TopologyRouter

    try:
        topology = TopologyRouter.from_config(config)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)

    from rich.console import Console as _Console
    _console = _Console(stderr=True)

    t_start = time.time()

    try:
        with _console.status(f"Running load test — {config.vus} VUs..."):
            if config.workers > 1:
                from jac_loadtest.core.process_runner import run_multiprocess
                metrics = run_multiprocess(entries, config, topology, auth_provider)
            else:
                metrics = MetricsCollector(max_samples=config.max_samples)
                asyncio.run(
                    run_all_vus(entries, config, metrics, topology=topology, auth_provider=auth_provider)
                )
    except AuthenticationError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)

    duration_s = time.time() - t_start
    stats = metrics.compute_endpoint_stats()
    snapshots = metrics.generate_timeseries(t_start)
    completion_p50, completion_p95, completion_p99 = metrics.completion_percentiles(t_start)

    fmt = config.report_format

    if fmt == "json":
        output = render_json(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            snapshots=snapshots,
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        )
        if config.report_out:
            with open(config.report_out, "w", encoding="utf-8") as fh:
                fh.write(output)
            print(f"JSON report written to {config.report_out}")
        else:
            print(output)

    elif fmt == "html":
        if not config.report_out:
            print("Error: --report-out <path> is required for --report-format html", file=sys.stderr)
            sys.exit(2)
        output = render_html(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            snapshots=snapshots,
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        )
        with open(config.report_out, "w", encoding="utf-8") as fh:
            fh.write(output)
        print(f"HTML report written to {config.report_out}", file=sys.stderr)

    else:
        render_console(
            stats, config,
            actual_duration_s=duration_s,
            total_rps=metrics.global_rps(duration_s),
            completion_p50_s=completion_p50,
            completion_p95_s=completion_p95,
            completion_p99_s=completion_p99,
        )
