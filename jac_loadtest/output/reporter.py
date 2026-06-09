"""Console (Rich), JSON, and HTML report rendering.

stdout: machine-readable output (json).
stderr: all human-readable output (console table, progress bar, warnings).
"""
from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from jac_loadtest.core.metrics import EndpointStats
    from jac_loadtest.config import LoadTestConfig


def render_console(stats: list[EndpointStats], config: LoadTestConfig, actual_duration_s: float | None = None, total_rps: float = 0.0) -> None:
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


def render_json(stats: list[EndpointStats], config: LoadTestConfig) -> str:
    raise NotImplementedError("JSON reporter is implemented in Phase 5.")


def render_html(stats: list[EndpointStats], config: LoadTestConfig) -> str:
    raise NotImplementedError("HTML reporter is implemented in Phase 5.")
