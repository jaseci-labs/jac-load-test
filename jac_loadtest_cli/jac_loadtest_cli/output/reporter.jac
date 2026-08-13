import json;
import from rich.console { Console }
import from rich.table { Table }
import from rich { box }
import from ..config { LoadTestConfig }
import from ..core.metrics { EndpointStats, StepResult }
import from ..core.metrics { percentile as pct }

glob _LATENCY_THRESHOLDS: dict[str, dict[str, int]] = {
    "p50":  {"good": 100,  "bad": 500},
    "p95":  {"good": 500,  "bad": 2000},
    "p99":  {"good": 1000, "bad": 5000},
    "p999": {"good": 2000, "bad": 10000},
};

glob _RATING_COLOR: dict[str, str] = {"lat-good": "green", "lat-ok": "yellow", "lat-bad": "red"};

glob _TEMPLATE_PATH: object = __import__("pathlib").Path(__file__).parent.parent / "templates" / "reporter_template.html";
glob _CHARTJS_VENDOR_PATH: object = __import__("pathlib").Path(__file__).parent.parent / "templates" / "vendor" / "chart.umd.min.js";

# H9 — a single global p95 bar rates a 50ms health-check endpoint and a
# multi-second LLM-backed endpoint the same way, so one of the two is always
# "wrong": either the fast endpoint never earns a real signal, or the slow
# one is permanently red. --slo lets an endpoint override the good/bad bar
# for one or more metrics; anything not listed keeps the global default.
def parse_slo_map(raw: str | None) -> dict[str, dict[str, dict[str, int]]] {
    if not raw {
        return {};
    }
    try {
        parsed = json.loads(raw);
    } except json.JSONDecodeError as exc {
        raise ValueError(f"--slo is not valid JSON: {exc}") from exc;
    }
    if not isinstance(parsed, dict) {
        raise ValueError(
            "--slo must be a JSON object mapping endpoint -> "
            '{metric: {"good": N, "bad": N}}'
        );
    }
    for endpoint_item in parsed.items() {
        endpoint = endpoint_item[0];
        metrics = endpoint_item[1];
        if not isinstance(metrics, dict) {
            raise ValueError(f"--slo entry for '{endpoint}' must be a JSON object of metrics");
        }
        for metric_item in metrics.items() {
            metric = metric_item[0];
            bounds = metric_item[1];
            if metric not in _LATENCY_THRESHOLDS {
                raise ValueError(
                    f"--slo entry for '{endpoint}' has unknown metric '{metric}' — "
                    f"expected one of {sorted(_LATENCY_THRESHOLDS.keys())}"
                );
            }
            if not isinstance(bounds, dict) or "good" not in bounds or "bad" not in bounds {
                raise ValueError(
                    f"--slo entry for '{endpoint}.{metric}' must be an object with "
                    '"good" and "bad" numeric values'
                );
            }
            good = bounds["good"];
            bad = bounds["bad"];
            if not isinstance(good, (int, float)) or not isinstance(bad, (int, float)) {
                raise ValueError(f"--slo entry for '{endpoint}.{metric}' good/bad must be numeric");
            }
            if good >= bad {
                raise ValueError(
                    f"--slo entry for '{endpoint}.{metric}' must have good < bad "
                    f"(got good={good}, bad={bad})"
                );
            }
        }
    }
    return parsed;
}

def _resolve_threshold(endpoint: str, metric: str, slo_overrides: dict) -> dict[str, int] {
    return slo_overrides.get(endpoint, {}).get(metric, _LATENCY_THRESHOLDS[metric]);
}

def _latency_rating(
    value_ms: float, metric: str, endpoint: str = "", slo_overrides: dict | None = None
) -> tuple[str, str] {
    t = _resolve_threshold(endpoint, metric, slo_overrides or {});
    if value_ms < t["good"] {
        return ("lat-good", "Good");
    } elif value_ms < t["bad"] {
        return ("lat-ok", "Acceptable");
    } else {
        return ("lat-bad", "Bad");
    }
}

def _apdex_class(score: float) -> str {
    if score >= 0.85 {
        return "lat-good";
    } elif score >= 0.70 {
        return "lat-ok";
    } else {
        return "lat-bad";
    }
}

def _fmt_bytes(b: int) -> str {
    if b < 1024 {
        return f"{b}B";
    } elif b < 1024 * 1024 {
        return f"{b // 1024}KB";
    } else {
        return f"{b / 1024 / 1024:.1f}MB";
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
    samples_evicted: int = 0,
    step_results: list[StepResult] | None = None,
    slo_overrides: dict | None = None,
) {

    console = Console(stderr=True, highlight=False);
    slo_overrides = slo_overrides or {};

    is_microservice = config.mode == "microservice";

    table = Table(box=box.SIMPLE_HEAVY, show_footer=False);
    if is_microservice {
        table.add_column("Service", style="green", no_wrap=True, max_width=30);
    }
    table.add_column("Endpoint", style="cyan", no_wrap=True, max_width=55);
    table.add_column("Reqs",  justify="right");
    table.add_column("RPS",   justify="right");
    table.add_column("OK%",   justify="right");
    table.add_column("p50",   justify="right");
    table.add_column("p95",   justify="right");
    table.add_column("p99",   justify="right");
    table.add_column("p99.9", justify="right");
    table.add_column("Apdex", justify="right");
    table.add_column("Bytes", justify="right");
    table.add_column("Errs",  justify="right");

    for s in stats {
        row = [];
        if is_microservice {
            row.append(s.service);
        }
        rps_str = f"{s.rps:.1f}" if s.rps > 0 else "-";
        _p50c = _RATING_COLOR[_latency_rating(s.p50_ms, "p50", s.endpoint, slo_overrides)[0]];
        _p95c = _RATING_COLOR[_latency_rating(s.p95_ms, "p95", s.endpoint, slo_overrides)[0]];
        _p99c = _RATING_COLOR[_latency_rating(s.p99_ms, "p99", s.endpoint, slo_overrides)[0]];
        _p999c = _RATING_COLOR[_latency_rating(s.p999_ms, "p999", s.endpoint, slo_overrides)[0]];
        row.extend([
            s.endpoint,
            str(s.total_requests),
            rps_str,
            f"{s.success_rate_pct:.1f}",
            f"[{_p50c}]{s.p50_ms:.0f}ms[/{_p50c}]",
            f"[{_p95c}]{s.p95_ms:.0f}ms[/{_p95c}]",
            f"[{_p99c}]{s.p99_ms:.0f}ms[/{_p99c}]",
            f"[{_p999c}]{s.p999_ms:.0f}ms[/{_p999c}]",
            f"{s.apdex:.2f}",
            _fmt_bytes(s.bytes_received),
            str(s.error_count),
        ]);
        table.add_row(*row);
    }

    if stats {
        total_reqs = sum(s.total_requests for s in stats);
        total_success = sum(s.success_count for s in stats);
        total_errors = sum(s.error_count for s in stats);
        overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;
        total_bytes = sum(s.bytes_received for s in stats);

        all_latencies = [lat for s in stats for lat in s.latencies];
        all_p50  = pct(all_latencies, 50);
        all_p95  = pct(all_latencies, 95);
        all_p99  = pct(all_latencies, 99);
        all_p999 = pct(all_latencies, 99.9);

        total_satisfied   = sum(s.satisfied_count for s in stats);
        total_tolerating  = sum(s.tolerating_count for s in stats);
        global_apdex = (total_satisfied + 0.5 * total_tolerating) / total_reqs if total_reqs else 0.0;

        table.add_section();
        total_row = [];
        if is_microservice {
            total_row.append("[bold]-[/bold]");
        }
        total_row.extend([
            "[bold]TOTAL[/bold]",
            f"[bold]{total_reqs}[/bold]",
            f"[bold]{total_rps:.1f}[/bold]",
            f"[bold]{overall_ok_pct:.1f}[/bold]",
            f"[bold]{all_p50:.0f}ms[/bold]",
            f"[bold]{all_p95:.0f}ms[/bold]",
            f"[bold]{all_p99:.0f}ms[/bold]",
            f"[bold]{all_p999:.0f}ms[/bold]",
            f"[bold]{global_apdex:.2f}[/bold]",
            f"[bold]{_fmt_bytes(total_bytes)}[/bold]",
            f"[bold]{total_errors}[/bold]",
        ]);
        table.add_row(*total_row);
    }

    console.print(table);

    endpoints_with_errors = [s for s in stats if s.error_breakdown];
    if endpoints_with_errors {
        console.print("[bold]Error breakdown:[/bold]");
        for s in endpoints_with_errors {
            parts = [];
            for item in sorted(s.error_breakdown.items()) {
                trace_ids = s.error_samples.get(item[0]);
                trace_suffix = f" (trace: {', '.join(trace_ids)})" if trace_ids else "";
                parts.append(f"{item[0]}: {item[1]}{trace_suffix}");
            }
            breakdown_str = "  ".join(parts);
            label = (f"{s.service}{s.endpoint}" if s.endpoint.startswith("/") else f"{s.service}/{s.endpoint}") if is_microservice else s.endpoint;
            console.print(f"  {label}  →  {breakdown_str}");
        }
        console.print("");
    }

    display_duration = actual_duration_s if actual_duration_s is not None else 0.0;
    load_mode_str = "open-loop" if config.open_loop else "closed-loop";
    console.print(
        f"Duration: {display_duration:.0f}s   VUs: {config.vus}   "
        f"Iterations: {config.iterations}   "
        f"Ramp-up: {config.ramp_up}   Mode: {config.mode}   Workers: {config.workers}   "
        f"RPS: {total_rps:.1f}   Load mode: {load_mode_str}   Apdex T: {config.apdex_t:.0f}ms"
    );
    console.print(
        "Completion time — "
        f"p50: {completion_p50_s:.1f}s   "
        f"p95: {completion_p95_s:.1f}s   "
        f"p99: {completion_p99_s:.1f}s"
    );
    if samples_evicted > 0 {
        console.print(
            f"[bold yellow]Warning:[/bold yellow] {samples_evicted} sample(s) evicted from the "
            "in-memory window — percentiles above reflect only the most recently retained samples."
        );
    }

    if step_results {
        console.print("\n[bold]Step Load:[/bold]");
        step_table = Table(box=box.SIMPLE, show_footer=False);
        step_table.add_column("Step", justify="right");
        step_table.add_column("VUs", justify="right");
        step_table.add_column("Window (s)", justify="right");
        step_table.add_column("Reqs", justify="right");
        step_table.add_column("Err%", justify="right");
        step_table.add_column("p95", justify="right");
        step_table.add_column("p99", justify="right");
        step_table.add_column("Result");
        for s in step_results {
            result_str = "[bold red]BREACHED[/bold red]" if s.breached else "[green]OK[/green]";
            step_table.add_row(
                str(s.step), str(s.vus), f"{s.start_s:.0f}-{s.end_s:.0f}",
                str(s.total_requests), f"{s.error_rate_pct:.1f}",
                f"{s.p95_ms:.0f}ms", f"{s.p99_ms:.0f}ms", result_str,
            );
        }
        console.print(step_table);
        last_ok = [s for s in step_results if not s.breached];
        if last_ok {
            console.print(
                f"[bold]Capacity knee:[/bold] last passing step was "
                f"{last_ok[-1].vus} VUs (step {last_ok[-1].step})."
            );
        } else {
            console.print(
                "[bold yellow]Capacity knee:[/bold yellow] even the first step breached — "
                "try starting from a lower --vus."
            );
        }
    }
}

def _endpoint_entries(stats: list[EndpointStats], slo_overrides: dict) -> list[dict] {
    entries = [];
    for s in stats {
        t50  = _resolve_threshold(s.endpoint, "p50",  slo_overrides);
        t95  = _resolve_threshold(s.endpoint, "p95",  slo_overrides);
        t99  = _resolve_threshold(s.endpoint, "p99",  slo_overrides);
        t999 = _resolve_threshold(s.endpoint, "p999", slo_overrides);
        entries.append({
            "endpoint": s.endpoint,
            "service": s.service,
            "total_requests": s.total_requests,
            "success_count": s.success_count,
            "error_count": s.error_count,
            "success_rate_pct": s.success_rate_pct,
            "rps": round(s.rps, 2),
            "bytes_received": s.bytes_received,
            "min_ms": round(s.min_ms, 2),
            "max_ms": round(s.max_ms, 2),
            "mean_ms": round(s.mean_ms, 2),
            "ttfb_ms": round(s.ttfb_ms, 2),
            "p50_ms": round(s.p50_ms, 2),
            "p50_rating": _latency_rating(s.p50_ms, "p50", s.endpoint, slo_overrides)[1].lower(),
            "p95_ms": round(s.p95_ms, 2),
            "p95_rating": _latency_rating(s.p95_ms, "p95", s.endpoint, slo_overrides)[1].lower(),
            "p99_ms": round(s.p99_ms, 2),
            "p99_rating": _latency_rating(s.p99_ms, "p99", s.endpoint, slo_overrides)[1].lower(),
            "p999_ms": round(s.p999_ms, 2),
            "p999_rating": _latency_rating(s.p999_ms, "p999", s.endpoint, slo_overrides)[1].lower(),
            # Effective good/bad bar actually applied to THIS endpoint — an
            # --slo override where one was configured, else the global default.
            "thresholds": {
                "p50":  {"good_ms": t50["good"],   "bad_ms": t50["bad"]},
                "p95":  {"good_ms": t95["good"],   "bad_ms": t95["bad"]},
                "p99":  {"good_ms": t99["good"],   "bad_ms": t99["bad"]},
                "p999": {"good_ms": t999["good"],  "bad_ms": t999["bad"]},
            },
            "apdex": round(s.apdex, 4),
            "completion_p50_s": round(s.completion_p50_s, 3),
            "completion_p95_s": round(s.completion_p95_s, 3),
            "completion_p99_s": round(s.completion_p99_s, 3),
            "error_breakdown": s.error_breakdown,
            "error_samples": s.error_samples,
        });
    }
    return entries;
}

def render_json(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list | None = None,
    interval_snapshots: list | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
    samples_evicted: int = 0,
    step_results: list[StepResult] | None = None,
    slo_overrides: dict | None = None,
) -> str {

    slo_overrides = slo_overrides or {};
    duration_s = actual_duration_s if actual_duration_s is not None else 0.0;

    total_reqs    = sum(s.total_requests for s in stats);
    total_success = sum(s.success_count for s in stats);
    total_errors  = sum(s.error_count for s in stats);
    total_bytes   = sum(s.bytes_received for s in stats);
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;

    all_latencies = [lat for s in stats for lat in s.latencies];

    total_satisfied  = sum(s.satisfied_count for s in stats);
    total_tolerating = sum(s.tolerating_count for s in stats);
    global_apdex = (total_satisfied + 0.5 * total_tolerating) / total_reqs if total_reqs else 0.0;

    global_ttfb_ms = (
        sum(s.ttfb_ms * s.total_requests for s in stats) / total_reqs if total_reqs else 0.0
    );

    json_report = {
        "meta": {
            "har_file": config.har_file,
            "url": config.url,
            "mode": config.mode,
            "vus": config.vus,
            "iterations": config.iterations,
            "workers": config.workers,
            "ramp_up": config.ramp_up,
            "actual_duration_s": round(duration_s, 3),
            "total_rps": round(total_rps, 2),
            "load_mode": "open" if config.open_loop else "closed",
            "apdex_t_ms": config.apdex_t,
            "samples_evicted": samples_evicted,
            "window_limited": samples_evicted > 0,
        },
        "latency_benchmarks": {
            "p50":  {"good_ms": 100,  "bad_ms": 500},
            "p95":  {"good_ms": 500,  "bad_ms": 2000},
            "p99":  {"good_ms": 1000, "bad_ms": 5000},
            "p999": {"good_ms": 2000, "bad_ms": 10000},
        },
        "endpoints": _endpoint_entries(stats, slo_overrides),
        "summary": {
            "total_requests": total_reqs,
            "success_count": total_success,
            "error_count": total_errors,
            "success_rate_pct": round(overall_ok_pct, 1),
            "total_bytes_received": total_bytes,
            "ttfb_ms": round(global_ttfb_ms, 2),
            "p50_ms": round(pct(all_latencies, 50), 2),
            "p50_rating": _latency_rating(pct(all_latencies, 50), "p50")[1].lower(),
            "p95_ms": round(pct(all_latencies, 95), 2),
            "p95_rating": _latency_rating(pct(all_latencies, 95), "p95")[1].lower(),
            "p99_ms": round(pct(all_latencies, 99), 2),
            "p99_rating": _latency_rating(pct(all_latencies, 99), "p99")[1].lower(),
            "p999_ms": round(pct(all_latencies, 99.9), 2),
            "p999_rating": _latency_rating(pct(all_latencies, 99.9), "p999")[1].lower(),
            "apdex": round(global_apdex, 4),
            "total_rps": round(total_rps, 2),
            "completion_p50_s": round(completion_p50_s, 3),
            "completion_p95_s": round(completion_p95_s, 3),
            "completion_p99_s": round(completion_p99_s, 3),
        },
        "cumulative_timeseries": [
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
        # Per-interval bucket deltas, not running totals — a burst confined to
        # one bucket shows up here as a spike; in cumulative_timeseries it's
        # diluted by every prior bucket and can be invisible without
        # hand-differencing consecutive points.
        "interval_timeseries": [
            {
                "timestamp": round(snap.timestamp, 3),
                "requests": snap.total_requests,
                "p50_ms": round(snap.p50_ms, 2),
                "p95_ms": round(snap.p95_ms, 2),
                "p99_ms": round(snap.p99_ms, 2),
                "rps": round(snap.rps, 2),
                "error_rate_pct": round(snap.error_rate_pct, 2),
            }
            for snap in (interval_snapshots or [])
        ],
        # --step-load ramp results, one entry per step; each step's p95/p99/
        # error_rate_pct reflect ONLY that step's own traffic window, not the
        # cumulative run — see _run_step_load in core/engine.jac.
        "step_load": [
            {
                "step": s.step,
                "vus": s.vus,
                "start_s": round(s.start_s, 3),
                "end_s": round(s.end_s, 3),
                "total_requests": s.total_requests,
                "error_rate_pct": round(s.error_rate_pct, 2),
                "p95_ms": round(s.p95_ms, 2),
                "p99_ms": round(s.p99_ms, 2),
                "breached": s.breached,
            }
            for s in (step_results or [])
        ],
        "capacity_knee_vus": next(
            (s.vus for s in reversed(step_results or []) if not s.breached), None
        ),
    };

    return json.dumps(json_report, indent=2);
}

def render_html(
    stats: list[EndpointStats],
    config: LoadTestConfig,
    actual_duration_s: float | None = None,
    total_rps: float = 0.0,
    snapshots: list | None = None,
    interval_snapshots: list | None = None,
    completion_p50_s: float = 0.0,
    completion_p95_s: float = 0.0,
    completion_p99_s: float = 0.0,
    samples_evicted: int = 0,
    step_results: list[StepResult] | None = None,
    slo_overrides: dict | None = None,
) -> str {
    import json;
    import string;
    import html as _html;
    slo_overrides = slo_overrides or {};
    duration_s = actual_duration_s if actual_duration_s is not None else 0.0;

    total_reqs    = sum(s.total_requests for s in stats);
    total_success = sum(s.success_count for s in stats);
    total_errors  = sum(s.error_count for s in stats);
    total_bytes   = sum(s.bytes_received for s in stats);
    overall_ok_pct = (total_success / total_reqs * 100.0) if total_reqs else 0.0;

    all_latencies = [lat for s in stats for lat in s.latencies];

    summary_p50  = pct(all_latencies, 50);
    summary_p95  = pct(all_latencies, 95);
    summary_p99  = pct(all_latencies, 99);
    summary_p999 = pct(all_latencies, 99.9);

    total_satisfied  = sum(s.satisfied_count for s in stats);
    total_tolerating = sum(s.tolerating_count for s in stats);
    global_apdex = (total_satisfied + 0.5 * total_tolerating) / total_reqs if total_reqs else 0.0;

    summary_ttfb = (
        sum(s.ttfb_ms * s.total_requests for s in stats) / total_reqs if total_reqs else 0.0
    );

    is_microservice = config.mode == "microservice";
    snaps = snapshots or [];
    interval_snaps = interval_snapshots or [];

    service_col = "<th>Service</th>" if is_microservice else "";
    endpoint_rows = "";
    for s in stats {
        ok_class = "ok" if s.success_rate_pct >= 99 else ("warn" if s.success_rate_pct >= 95 else "err");
        svc_cell = f"<td>{_html.escape(s.service)}</td>" if is_microservice else "";
        _p50r  = _latency_rating(s.p50_ms,  "p50",  s.endpoint, slo_overrides);
        _p95r  = _latency_rating(s.p95_ms,  "p95",  s.endpoint, slo_overrides);
        _p99r  = _latency_rating(s.p99_ms,  "p99",  s.endpoint, slo_overrides);
        _p999r = _latency_rating(s.p999_ms, "p999", s.endpoint, slo_overrides);
        rps_str = f"{s.rps:.1f}" if s.rps > 0 else "-";
        apdex_cls = _apdex_class(s.apdex);
        endpoint_rows += (
            "<tr>"
            f"{svc_cell}"
            f"<td class='mono'>{_html.escape(s.endpoint)}</td>"
            f"<td class='num'>{s.total_requests}</td>"
            f"<td class='num'>{rps_str}</td>"
            f"<td class='num {ok_class}'>{s.success_rate_pct:.1f}%</td>"
            f"<td class='num {_p50r[0]}'>{s.p50_ms:.0f} <span class='lat-badge-sm'>{_p50r[1]}</span></td>"
            f"<td class='num {_p95r[0]}'>{s.p95_ms:.0f} <span class='lat-badge-sm'>{_p95r[1]}</span></td>"
            f"<td class='num {_p99r[0]}'>{s.p99_ms:.0f} <span class='lat-badge-sm'>{_p99r[1]}</span></td>"
            f"<td class='num {_p999r[0]}'>{s.p999_ms:.0f} <span class='lat-badge-sm'>{_p999r[1]}</span></td>"
            f"<td class='num {apdex_cls}'>{s.apdex:.2f}</td>"
            f"<td class='num'>{_fmt_bytes(s.bytes_received)}</td>"
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
            label = _html.escape(label);
            _bd_parts = [];
            for _bd in s.error_breakdown.items() {
                _trace_ids = s.error_samples.get(_bd[0]);
                _trace_html = (
                    f" <span class='err-trace'>trace: {_html.escape(', '.join(_trace_ids))}</span>"
                    if _trace_ids else ""
                );
                _bd_parts.append(f"<span class='err-tag'>{_html.escape(str(_bd[0]))}: {_bd[1]}{_trace_html}</span>");
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

    if step_results {
        step_rows = "";
        for s in step_results {
            row_class = "err" if s.breached else "ok";
            result_label = "BREACHED" if s.breached else "OK";
            step_rows += (
                "<tr>"
                f"<td class='num'>{s.step}</td>"
                f"<td class='num'>{s.vus}</td>"
                f"<td class='num'>{s.start_s:.0f}-{s.end_s:.0f}s</td>"
                f"<td class='num'>{s.total_requests}</td>"
                f"<td class='num'>{s.error_rate_pct:.1f}%</td>"
                f"<td class='num'>{s.p95_ms:.0f}ms</td>"
                f"<td class='num'>{s.p99_ms:.0f}ms</td>"
                f"<td class='num {row_class}'>{result_label}</td>"
                "</tr>\n"
            );
        }
        _last_ok = [s for s in step_results if not s.breached];
        knee_line = (
            f"Capacity knee: last passing step was {_last_ok[-1].vus} VUs (step {_last_ok[-1].step})."
            if _last_ok else
            "Capacity knee: even the first step breached — try starting from a lower VU count."
        );
        step_load_section = (
            "<section><h2>Step Load</h2>"
            "<table><thead><tr>"
            "<th>Step</th><th>VUs</th><th>Window</th><th>Reqs</th>"
            "<th>Err%</th><th>p95</th><th>p99</th><th>Result</th>"
            "</tr></thead>"
            f"<tbody>{step_rows}</tbody></table>"
            f"<p class='subtitle'>{_html.escape(knee_line)}</p>"
            "</section>"
        );
    } else {
        step_load_section = "";
    }

    _sp50r  = _latency_rating(summary_p50,  "p50");
    _sp95r  = _latency_rating(summary_p95,  "p95");
    _sp99r  = _latency_rating(summary_p99,  "p99");
    _sp999r = _latency_rating(summary_p999, "p999");
    _apdex_cls = _apdex_class(global_apdex);

    window_warning = (
        "<div class='window-warning'>"
        f"⚠ {samples_evicted} sample(s) evicted from the in-memory window — "
        "percentiles above reflect only the most recently retained samples, not the full run."
        "</div>"
    ) if samples_evicted > 0 else "";

    template = string.Template(_TEMPLATE_PATH.read_text(encoding="utf-8"));
    rendered = template.substitute(
        har_file=_html.escape(config.har_file or ""),
        mode=config.mode,
        vus=config.vus,
        iterations=config.iterations,
        duration_s=f"{duration_s:.0f}",
        total_reqs=total_reqs,
        summary_ok_class="ok" if overall_ok_pct >= 99 else ("warn" if overall_ok_pct >= 95 else "err"),
        overall_ok_pct=f"{overall_ok_pct:.1f}",
        summary_p50=f"{summary_p50:.0f}",
        summary_p95=f"{summary_p95:.0f}",
        summary_p99=f"{summary_p99:.0f}",
        summary_p999=f"{summary_p999:.0f}",
        summary_ttfb=f"{summary_ttfb:.0f}",
        summary_p50_class=_sp50r[0],
        summary_p50_rating=_sp50r[1],
        summary_p95_class=_sp95r[0],
        summary_p95_rating=_sp95r[1],
        summary_p99_class=_sp99r[0],
        summary_p99_rating=_sp99r[1],
        summary_p999_class=_sp999r[0],
        summary_p999_rating=_sp999r[1],
        summary_apdex=f"{global_apdex:.2f}",
        summary_apdex_class=_apdex_cls,
        apdex_t=f"{config.apdex_t:.0f}",
        total_rps=f"{total_rps:.1f}",
        total_bytes=_fmt_bytes(total_bytes),
        completion_p50_s=f"{completion_p50_s:.1f}",
        completion_p95_s=f"{completion_p95_s:.1f}",
        completion_p99_s=f"{completion_p99_s:.1f}",
        service_col=service_col,
        endpoint_rows=endpoint_rows,
        error_section=error_section,
        step_load_section=step_load_section,
        total_service_cell="<td>-</td>" if is_microservice else "",
        total_ok_class="ok" if overall_ok_pct >= 99 else ("warn" if overall_ok_pct >= 95 else "err"),
        total_errors=total_errors,
        workers=config.workers,
        ramp_up=config.ramp_up,
        timeout=config.timeout,
        load_mode="open-loop" if config.open_loop else "closed-loop",
        url_meta=f"<span>URL: {_html.escape(config.url)}</span>" if config.url else "",
        window_warning=window_warning,
        has_timeseries="true" if snaps else "false",
        ts_labels=json.dumps([f"{snap.timestamp:.0f}s" for snap in snaps]),
        ts_p50=json.dumps([round(snap.p50_ms, 1) for snap in snaps]),
        ts_p95=json.dumps([round(snap.p95_ms, 1) for snap in snaps]),
        ts_p99=json.dumps([round(snap.p99_ms, 1) for snap in snaps]),
        ts_rps=json.dumps([round(snap.rps, 2) for snap in snaps]),
        ts_interval_rps=json.dumps([round(snap.rps, 2) for snap in interval_snaps]),
        ts_interval_p95=json.dumps([round(snap.p95_ms, 1) for snap in interval_snaps]),
        ep_labels=json.dumps([s.endpoint for s in stats]),
        ep_p50=json.dumps([round(s.p50_ms, 1) for s in stats]),
        ep_p95=json.dumps([round(s.p95_ms, 1) for s in stats]),
        ep_p99=json.dumps([round(s.p99_ms, 1) for s in stats]),
        ep_p999=json.dumps([round(s.p999_ms, 1) for s in stats]),
    );
    chartjs_src = _CHARTJS_VENDOR_PATH.read_text(encoding="utf-8");
    return rendered.replace("__CHARTJS_INLINE__", chartjs_src, 1);
}
