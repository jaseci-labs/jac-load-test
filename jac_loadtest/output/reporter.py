"""Console (Rich), JSON, and HTML report rendering.

stdout: machine-readable output (json).
stderr: all human-readable output (console table, progress bar, warnings).
"""
from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from jac_loadtest.core.metrics import EndpointStats, StatsSnapshot
    from jac_loadtest.config import LoadTestConfig


def render_console(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) -> None:
    """Print a Rich summary table to stderr."""
    from rich.console import Console
    from rich.table import Table
    from rich import box
    from jac_loadtest.config import parse_duration

    console = Console(stderr=True, highlight=False)

    is_microservice = config.mode == "microservice"

    table = Table(box=box.SIMPLE_HEAVY, show_footer=False)
    if is_microservice:
        table.add_column("Service", style="green", no_wrap=True, max_width=30)
    table.add_column("Endpoint", style="cyan", no_wrap=True, max_width=60)
    table.add_column("Reqs", justify="right")
    table.add_column("OK%", justify="right")
    table.add_column("p50", justify="right")
    table.add_column("p95", justify="right")
    table.add_column("p99", justify="right")
    table.add_column("Errs", justify="right")

    for s in stats:
        row: list[str] = []
        if is_microservice:
            row.append(s.service)
        row.extend([
            s.endpoint,
            str(s.total_requests),
            f"{s.success_rate_pct:.1f}",
            f"{s.p50_ms:.0f}ms",
            f"{s.p95_ms:.0f}ms",
            f"{s.p99_ms:.0f}ms",
            str(s.error_count),
        ])
        table.add_row(*row)

    # TOTAL footer row aggregated across all endpoints
    if stats:
        total_reqs = sum(s.total_requests for s in stats)
        total_success = sum(s.success_count for s in stats)
        total_errors = sum(s.error_count for s in stats)
        overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0

        all_latencies: list[float] = []
        for s in stats:
            # Approximate from p50/p95/p99 — real latencies live in MetricsCollector.
            # For the TOTAL row we compute a weighted mean of percentile values.
            all_latencies.extend([s.p50_ms] * s.total_requests)

        from jac_loadtest.core.metrics import percentile as pct
        all_p50 = pct(all_latencies, 50)
        all_p95 = pct(all_latencies, 95)
        all_p99 = pct(all_latencies, 99)

        table.add_section()
        total_row: list[str] = []
        if is_microservice:
            total_row.append("[bold]-[/bold]")
        total_row.extend([
            "[bold]TOTAL[/bold]",
            f"[bold]{total_reqs}[/bold]",
            f"[bold]{overall_ok_pct:.1f}[/bold]",
            f"[bold]{all_p50:.0f}ms[/bold]",
            f"[bold]{all_p95:.0f}ms[/bold]",
            f"[bold]{all_p99:.0f}ms[/bold]",
            f"[bold]{total_errors}[/bold]",
        ])
        table.add_row(*total_row)

    console.print(table)

    # Error breakdown — only shown when there are errors
    endpoints_with_errors = [s for s in stats if s.error_breakdown]
    if endpoints_with_errors:
        console.print("[bold]Error breakdown:[/bold]")
        for s in endpoints_with_errors:
            breakdown_str = "  ".join(
                f"{key}: {count}" for key, count in sorted(s.error_breakdown.items())
            )
            label = (f"{s.service}{s.endpoint}" if s.endpoint.startswith("/") else f"{s.service}/{s.endpoint}") if is_microservice else s.endpoint
            console.print(f"  {label}  →  {breakdown_str}")
        console.print("")

    display_duration = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration)
    console.print(
        f"Duration: {display_duration:.0f}s   VUs: {config.vus}   "
        f"Ramp-up: {config.ramp_up}   Mode: {config.mode}   Workers: {config.workers}   "
        f"RPS: {total_rps:.1f}"
    )
    console.print(
        f"Completion time — "
        f"p50: {completion_p50_s:.1f}s   "
        f"p95: {completion_p95_s:.1f}s   "
        f"p99: {completion_p99_s:.1f}s"
    )


def render_json(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list[StatsSnapshot] | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) -> str:
    """Return a JSON string with the full test report.

    Schema:
      meta       — run parameters
      endpoints  — per-endpoint stats
      summary    — aggregated totals
      timeseries — StatsSnapshot list (empty when no snapshots were collected)
    """
    import json
    from jac_loadtest.config import parse_duration

    duration_s = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration)

    total_reqs = sum(s.total_requests for s in stats)
    total_success = sum(s.success_count for s in stats)
    total_errors = sum(s.error_count for s in stats)
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0

    from jac_loadtest.core.metrics import percentile as pct
    all_latencies: list[float] = []
    for s in stats:
        all_latencies.extend([s.p50_ms] * s.total_requests)

    report = {
        "meta": {
            "har_file": config.har_file,
            "url": config.url,
            "mode": config.mode,
            "vus": config.vus,
            "workers": config.workers,
            "duration": config.duration,
            "ramp_up": config.ramp_up,
            "actual_duration_s": round(duration_s, 3),
            "total_rps": round(total_rps, 2),
        },
        "endpoints": [
            {
                "endpoint": s.endpoint,
                "service": s.service,
                "total_requests": s.total_requests,
                "success_count": s.success_count,
                "error_count": s.error_count,
                "success_rate_pct": s.success_rate_pct,
                "min_ms": round(s.min_ms, 2),
                "max_ms": round(s.max_ms, 2),
                "mean_ms": round(s.mean_ms, 2),
                "p50_ms": round(s.p50_ms, 2),
                "p95_ms": round(s.p95_ms, 2),
                "p99_ms": round(s.p99_ms, 2),
                "error_breakdown": s.error_breakdown,
            }
            for s in stats
        ],
        "summary": {
            "total_requests": total_reqs,
            "success_count": total_success,
            "error_count": total_errors,
            "success_rate_pct": round(overall_ok_pct, 1),
            "p50_ms": round(pct(all_latencies, 50), 2),
            "p95_ms": round(pct(all_latencies, 95), 2),
            "p99_ms": round(pct(all_latencies, 99), 2),
            "total_rps": round(total_rps, 2),
            "completion_p50_s": round(completion_p50_s, 3),
            "completion_p95_s": round(completion_p95_s, 3),
            "completion_p99_s": round(completion_p99_s, 3),
        },
        "timeseries": [
            {
                "timestamp": round(snap.timestamp, 3),
                "total_requests": snap.total_requests,
                "p50_ms": round(snap.p50_ms, 2),
                "p95_ms": round(snap.p95_ms, 2),
                "p99_ms": round(snap.p99_ms, 2),
                "rps": round(snap.rps, 2),
                "error_rate_pct": round(snap.error_rate_pct, 2),
            }
            for snap in (snapshots or [])
        ],
    }

    return json.dumps(report, indent=2)


_TEMPLATE_PATH = (
    __import__("pathlib").Path(__file__).parent.parent / "templates" / "reporter_template.html"
)


def render_html(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list[StatsSnapshot] | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) -> str:
    """Return a self-contained HTML report rendered from reporter_template.html."""
    import json
    import string
    from jac_loadtest.config import parse_duration

    duration_s = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration)

    total_reqs = sum(s.total_requests for s in stats)
    total_success = sum(s.success_count for s in stats)
    total_errors = sum(s.error_count for s in stats)
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0

    from jac_loadtest.core.metrics import percentile as pct
    all_latencies: list[float] = []
    for s in stats:
        all_latencies.extend([s.p50_ms] * s.total_requests)

    summary_p50 = pct(all_latencies, 50)
    summary_p95 = pct(all_latencies, 95)
    summary_p99 = pct(all_latencies, 99)

    is_microservice = config.mode == "microservice"
    snaps = snapshots or []

    # Build endpoint table rows
    service_col = "<th>Service</th>" if is_microservice else ""
    endpoint_rows = ""
    for s in stats:
        ok_class = "ok" if s.success_rate_pct >= 99 else ("warn" if s.success_rate_pct >= 95 else "err")
        svc_cell = f"<td>{s.service}</td>" if is_microservice else ""
        endpoint_rows += (
            f"<tr>"
            f"{svc_cell}"
            f"<td class='mono'>{s.endpoint}</td>"
            f"<td class='num'>{s.total_requests}</td>"
            f"<td class='num {ok_class}'>{s.success_rate_pct:.1f}%</td>"
            f"<td class='num'>{s.p50_ms:.0f}</td>"
            f"<td class='num'>{s.p95_ms:.0f}</td>"
            f"<td class='num'>{s.p99_ms:.0f}</td>"
            f"<td class='num'>{s.error_count}</td>"
            f"</tr>\n"
        )

    template = string.Template(_TEMPLATE_PATH.read_text(encoding="utf-8"))
    return template.substitute(
        har_file=config.har_file,
        mode=config.mode,
        vus=config.vus,
        duration_s=f"{duration_s:.0f}",
        total_reqs=total_reqs,
        summary_ok_class="ok" if overall_ok_pct >= 99 else ("warn" if overall_ok_pct >= 95 else "err"),
        overall_ok_pct=f"{overall_ok_pct:.1f}",
        summary_p50=f"{summary_p50:.0f}",
        summary_p95=f"{summary_p95:.0f}",
        summary_p99=f"{summary_p99:.0f}",
        total_rps=f"{total_rps:.1f}",
        completion_p50_s=f"{completion_p50_s:.1f}",
        completion_p95_s=f"{completion_p95_s:.1f}",
        completion_p99_s=f"{completion_p99_s:.1f}",
        service_col=service_col,
        endpoint_rows=endpoint_rows,
        total_service_cell="<td>-</td>" if is_microservice else "",
        total_ok_class="ok" if overall_ok_pct >= 99 else ("warn" if overall_ok_pct >= 95 else "err"),
        total_errors=total_errors,
        workers=config.workers,
        ramp_up=config.ramp_up,
        timeout=config.timeout,
        url_meta=f"<span>URL: {config.url}</span>" if config.url else "",
        has_timeseries="true" if snaps else "false",
        ts_labels=json.dumps([f"{snap.timestamp:.0f}s" for snap in snaps]),
        ts_p50=json.dumps([round(snap.p50_ms, 1) for snap in snaps]),
        ts_p95=json.dumps([round(snap.p95_ms, 1) for snap in snaps]),
        ts_p99=json.dumps([round(snap.p99_ms, 1) for snap in snaps]),
        ts_rps=json.dumps([round(snap.rps, 2) for snap in snaps]),
        ep_labels=json.dumps([s.endpoint for s in stats]),
        ep_p50=json.dumps([round(s.p50_ms, 1) for s in stats]),
        ep_p95=json.dumps([round(s.p95_ms, 1) for s in stats]),
        ep_p99=json.dumps([round(s.p99_ms, 1) for s in stats]),
    )
