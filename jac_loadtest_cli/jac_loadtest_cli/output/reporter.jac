import json;
import from rich.console { Console }
import from rich.table { Table }
import from rich { box }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { EndpointStats}
import from ..core.metrics { percentile as pct }

glob _LATENCY_THRESHOLDS: dict[str, dict[str, int]] = {
    "p50": {"good": 100,  "bad": 500},
    "p95": {"good": 500,  "bad": 2000},
    "p99": {"good": 1000, "bad": 5000},
};

glob _TEMPLATE_PATH: object = __import__("pathlib").Path(__file__).parent.parent / "templates" / "reporter_template.html";

def _latency_rating(value_ms: float, metric: str) -> tuple[str, str] {
    t = _LATENCY_THRESHOLDS[metric];
    if value_ms < t["good"] {
        return ("lat-good", "Good");
    } elif value_ms < t["bad"] {
        return ("lat-ok", "Acceptable");
    } else {
        return ("lat-bad", "Bad");
    }
}

def render_console(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) {

    console = Console(stderr=True, highlight=False);

    is_microservice = config.mode == "microservice";

    table = Table(box=box.SIMPLE_HEAVY, show_footer=False);
    if is_microservice {
        table.add_column("Service", style="green", no_wrap=True, max_width=30);
    }
    table.add_column("Endpoint", style="cyan", no_wrap=True, max_width=60);
    table.add_column("Reqs", justify="right");
    table.add_column("OK%", justify="right");
    table.add_column("p50", justify="right");
    table.add_column("p95", justify="right");
    table.add_column("p99", justify="right");
    table.add_column("Errs", justify="right");

    for s in stats {
        row = [];
        if is_microservice {
            row.append(s.service);
        }
        row.extend([
            s.endpoint,
            str(s.total_requests),
            f"{s.success_rate_pct:.1f}",
            f"{s.p50_ms:.0f}ms",
            f"{s.p95_ms:.0f}ms",
            f"{s.p99_ms:.0f}ms",
            str(s.error_count),
        ]);
        table.add_row(*row);
    }

    if stats {
        total_reqs = sum(s.total_requests for s in stats);
        total_success = sum(s.success_count for s in stats);
        total_errors = sum(s.error_count for s in stats);
        overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;

        all_latencies = [lat for s in stats for lat in s.latencies];
        all_p50 = pct(all_latencies, 50);
        all_p95 = pct(all_latencies, 95);
        all_p99 = pct(all_latencies, 99);

        table.add_section();
        total_row = [];
        if is_microservice {
            total_row.append("[bold]-[/bold]");
        }
        total_row.extend([
            "[bold]TOTAL[/bold]",
            f"[bold]{total_reqs}[/bold]",
            f"[bold]{overall_ok_pct:.1f}[/bold]",
            f"[bold]{all_p50:.0f}ms[/bold]",
            f"[bold]{all_p95:.0f}ms[/bold]",
            f"[bold]{all_p99:.0f}ms[/bold]",
            f"[bold]{total_errors}[/bold]",
        ]);
        table.add_row(*total_row);
    }

    console.print(table);

    endpoints_with_errors = [s for s in stats if s.error_breakdown];
    if endpoints_with_errors {
        console.print("[bold]Error breakdown:[/bold]");
        for s in endpoints_with_errors {
            breakdown_str = "  ".join(
                [f"{item[0]}: {item[1]}" for item in sorted(s.error_breakdown.items())]
            );
            label = (f"{s.service}{s.endpoint}" if s.endpoint.startswith("/") else f"{s.service}/{s.endpoint}") if is_microservice else s.endpoint;
            console.print(f"  {label}  →  {breakdown_str}");
        }
        console.print("");
    }

    display_duration = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration);
    console.print(
        f"Duration: {display_duration:.0f}s   VUs: {config.vus}   "
        f"Ramp-up: {config.ramp_up}   Mode: {config.mode}   Workers: {config.workers}   "
        f"RPS: {total_rps:.1f}"
    );
    console.print(
        "Completion time — "
        f"p50: {completion_p50_s:.1f}s   "
        f"p95: {completion_p95_s:.1f}s   "
        f"p99: {completion_p99_s:.1f}s"
    );
}

def render_json(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) -> str {

    duration_s = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration);

    total_reqs = sum(s.total_requests for s in stats);
    total_success = sum(s.success_count for s in stats);
    total_errors = sum(s.error_count for s in stats);
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;

    all_latencies = [lat for s in stats for lat in s.latencies];

    json_report = {
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
        "latency_benchmarks": {
            "p50": {"good_ms": 100,  "bad_ms": 500},
            "p95": {"good_ms": 500,  "bad_ms": 2000},
            "p99": {"good_ms": 1000, "bad_ms": 5000},
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
                "p50_rating": _latency_rating(s.p50_ms, "p50")[1].lower(),
                "p95_ms": round(s.p95_ms, 2),
                "p95_rating": _latency_rating(s.p95_ms, "p95")[1].lower(),
                "p99_ms": round(s.p99_ms, 2),
                "p99_rating": _latency_rating(s.p99_ms, "p99")[1].lower(),
                "completion_p50_s": round(s.completion_p50_s, 3),
                "completion_p95_s": round(s.completion_p95_s, 3),
                "completion_p99_s": round(s.completion_p99_s, 3),
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
            "p50_rating": _latency_rating(pct(all_latencies, 50), "p50")[1].lower(),
            "p95_ms": round(pct(all_latencies, 95), 2),
            "p95_rating": _latency_rating(pct(all_latencies, 95), "p95")[1].lower(),
            "p99_ms": round(pct(all_latencies, 99), 2),
            "p99_rating": _latency_rating(pct(all_latencies, 99), "p99")[1].lower(),
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
    };

    return json.dumps(json_report, indent=2);
}

def render_html(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
) -> str {
    import json;
    import string;
    import from ..config { parse_duration }

    duration_s = actual_duration_s if actual_duration_s is not None else parse_duration(config.duration);

    total_reqs = sum(s.total_requests for s in stats);
    total_success = sum(s.success_count for s in stats);
    total_errors = sum(s.error_count for s in stats);
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;

    all_latencies = [lat for s in stats for lat in s.latencies];

    summary_p50 = pct(all_latencies, 50);
    summary_p95 = pct(all_latencies, 95);
    summary_p99 = pct(all_latencies, 99);

    is_microservice = config.mode == "microservice";
    snaps = snapshots or [];

    service_col = "<th>Service</th>" if is_microservice else "";
    endpoint_rows = "";
    for s in stats {
        ok_class = "ok" if s.success_rate_pct >= 99 else ("warn" if s.success_rate_pct >= 95 else "err");
        svc_cell = f"<td>{s.service}</td>" if is_microservice else "";
        _p50r = _latency_rating(s.p50_ms, "p50");
        p50_cls = _p50r[0];
        p50_lbl = _p50r[1];
        _p95r = _latency_rating(s.p95_ms, "p95");
        p95_cls = _p95r[0];
        p95_lbl = _p95r[1];
        _p99r = _latency_rating(s.p99_ms, "p99");
        p99_cls = _p99r[0];
        p99_lbl = _p99r[1];
        endpoint_rows += (
            "<tr>"
            f"{svc_cell}"
            f"<td class='mono'>{s.endpoint}</td>"
            f"<td class='num'>{s.total_requests}</td>"
            f"<td class='num {ok_class}'>{s.success_rate_pct:.1f}%</td>"
            f"<td class='num {p50_cls}'>{s.p50_ms:.0f} <span class='lat-badge-sm'>{p50_lbl}</span></td>"
            f"<td class='num {p95_cls}'>{s.p95_ms:.0f} <span class='lat-badge-sm'>{p95_lbl}</span></td>"
            f"<td class='num {p99_cls}'>{s.p99_ms:.0f} <span class='lat-badge-sm'>{p99_lbl}</span></td>"
            f"<td class='num'>{s.completion_p50_s:.2f}s</td>"
            f"<td class='num'>{s.completion_p95_s:.2f}s</td>"
            f"<td class='num'>{s.completion_p99_s:.2f}s</td>"
            f"<td class='num'>{s.error_count}</td>"
            "</tr>\n"
        );
    }

    endpoints_with_errors = [s for s in stats if s.error_breakdown];
    if endpoints_with_errors {
        error_rows = "";
        for s in endpoints_with_errors {
            label = (
                f"{s.service}{s.endpoint}" if s.endpoint.startswith("/") else f"{s.service}/{s.endpoint}"
            ) if is_microservice else s.endpoint;
            _bd_parts = [];
            for _bd in s.error_breakdown.items() {
                _bd_parts.append(f"<span class='err-tag'>{_bd[0]}: {_bd[1]}</span>");
            }
            breakdown_cells = "".join(_bd_parts);
            error_rows += f"<tr><td class='mono'>{label}</td><td>{breakdown_cells}</td></tr>\n";
        }
        error_section = (
            "<section><h2>Error Breakdown</h2>"
            "<table><thead><tr><th>Endpoint</th><th>Errors</th></tr></thead>"
            f"<tbody>{error_rows}</tbody></table></section>"
        );
    } else {
        error_section = "";
    }

    _sp50r = _latency_rating(summary_p50, "p50");
    p50_cls = _sp50r[0];
    p50_lbl = _sp50r[1];
    _sp95r = _latency_rating(summary_p95, "p95");
    p95_cls = _sp95r[0];
    p95_lbl = _sp95r[1];
    _sp99r = _latency_rating(summary_p99, "p99");
    p99_cls = _sp99r[0];
    p99_lbl = _sp99r[1];

    template = string.Template(_TEMPLATE_PATH.read_text(encoding="utf-8"));
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
        summary_p50_class=p50_cls,
        summary_p50_rating=p50_lbl,
        summary_p95_class=p95_cls,
        summary_p95_rating=p95_lbl,
        summary_p99_class=p99_cls,
        summary_p99_rating=p99_lbl,
        total_rps=f"{total_rps:.1f}",
        completion_p50_s=f"{completion_p50_s:.1f}",
        completion_p95_s=f"{completion_p95_s:.1f}",
        completion_p99_s=f"{completion_p99_s:.1f}",
        service_col=service_col,
        endpoint_rows=endpoint_rows,
        error_section=error_section,
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
    );
}
