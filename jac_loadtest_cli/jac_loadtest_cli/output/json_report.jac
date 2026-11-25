"""The machine-readable report. This one is ours; console, HTML and CSV are Locust's.

Shape is the one jac_loadtest_web already reads (meta / summary / endpoints /
cumulative_timeseries) so the web app and CI consumers keep working. Fields that
only existed because of the old engine -- Apdex, good/bad ratings,
completion-time percentiles, latency_benchmarks -- are gone on purpose.

Every value is read from Locust's stats, so it matches Locust's own console and
HTML report for the same run.
"""

import from locust.stats { StatsEntry }
import from ..config { LoadTestConfig }
import from ..runner.live { aggregate, Snapshot, AUTH_PREFIX, POLL_PREFIX, is_side_row }
import from ..runner.steps { StepResult, capacity_knee }
import from ..runner.infra { Suspect, blocks_per_endpoint }

def error_type_of(message: str) -> str {
    # "APP_ERROR_IN_200: reports[]..." -> "APP_ERROR_IN_200";
    # "HTTP 404 (expected 200): ..." -> "HTTP 404".
    text = message.strip();
    if text.startswith("Exception(") {
        text = text[len("Exception("):].strip("'\") ");
    }
    cut = len(text);
    for mark in (":", " (") {
        i = text.find(mark);
        if i != -1 and i < cut {
            cut = i;
        }
    }
    return text[:cut].strip() or "ERROR";
}

def _row(stat: StatsEntry, duration_s: float, name: str, method: str) -> dict[str, any] {
    n = stat.num_requests;
    return {
        "endpoint": name,
        "method": method,
        "total_requests": n,
        "success_count": n - stat.num_failures,
        "error_count": stat.num_failures,
        "success_rate_pct": round((n - stat.num_failures) / n * 100.0, 1) if n else 0.0,
        "rps": round(n / duration_s, 2) if duration_s > 0 else 0.0,
        "bytes_received": stat.total_content_length,
        "min_ms": round(stat.min_response_time or 0.0, 2),
        "max_ms": round(stat.max_response_time or 0.0, 2),
        "mean_ms": round(stat.avg_response_time or 0.0, 2),
        "p50_ms": float(stat.get_response_time_percentile(0.50) or 0),
        "p95_ms": float(stat.get_response_time_percentile(0.95) or 0),
        "p99_ms": float(stat.get_response_time_percentile(0.99) or 0),
        "p999_ms": float(stat.get_response_time_percentile(0.999) or 0),
        "error_breakdown": {},
    };
}

def build_report(
    env: any,
    config: LoadTestConfig,
    duration_s: float,
    snapshots: list[Snapshot],
    auth_failures: list[tuple[str, str]],
    suspects: list[Suspect] = [],
    started_at: float = 0.0,
    steps: list[StepResult] = [],
) -> dict[str, any] {
    endpoints: list[dict[str, any]] = [];
    auth_rows: dict[str, any] = {};
    for item in env.stats.entries.items() {
        key = item[0];
        stat = item[1];
        if key[0].startswith(AUTH_PREFIX) {
            auth_rows[key[0][len(AUTH_PREFIX):]] = {
                "requests": stat.num_requests, "failures": stat.num_failures,
            };
            continue;
        }
        if key[0].startswith(POLL_PREFIX) {
            # Individual polls inside a --poll-until block; the block itself is
            # reported once under the endpoint's own name.
            continue;
        }
        endpoints.append(_row(stat, duration_s, key[0], key[1]));
    }
    by_key = {(ep["endpoint"], ep["method"]): ep for ep in endpoints};
    for err in env.stats.errors.values() {
        row = by_key.get((err.name, err.method));
        if row is not None {
            etype = error_type_of(str(err.error));
            row["error_breakdown"][etype] = row["error_breakdown"].get(etype, 0) + err.occurrences;
        }
    }

    # Infra blocks: failures that were really a WAF/gateway deny page. They stay in
    # the counts but are taken out of the error count and the success-rate base.
    blocks = blocks_per_endpoint(suspects, config.infra_block_threshold, started_at);
    total_blocks = 0;
    for ep in endpoints {
        b = blocks.get(ep["endpoint"], 0);
        if b > 0 {
            ep["infra_block_count"] = b;
            ep["error_count"] = ep["error_count"] - b;
            rated = ep["total_requests"] - b;
            ep["success_rate_pct"] = round(ep["success_count"] / rated * 100.0, 1) if rated > 0 else 0.0;
            if ep["endpoint"].startswith("health: ") {
                continue;
            }
            total_blocks += b;
        }
    }

    agg = aggregate(env);
    n = agg.num_requests;
    summary = _row(agg, duration_s, "Aggregated", "");
    for k in ("endpoint", "method", "bytes_received", "min_ms", "max_ms", "mean_ms", "rps", "error_breakdown") {
        summary.pop(k, None);
    }
    summary["infra_block_count"] = total_blocks;
    summary["error_count"] = agg.num_failures - total_blocks;
    rated_total = n - total_blocks;
    summary["success_rate_pct"] = round((n - agg.num_failures) / rated_total * 100.0, 1) if rated_total > 0 else 0.0;
    summary["total_bytes_received"] = agg.total_content_length;
    summary["total_rps"] = round(n / duration_s, 2) if duration_s > 0 else 0.0;

    return {
        "meta": {
            "har_file": config.har_file,
            "url": config.url,
            "mode": config.mode,
            "vus": config.vus,
            "iterations": config.iterations,
            "ramp_up": config.ramp_up,
            "actual_duration_s": round(duration_s, 3),
            "engine": "locust",
        },
        "endpoints": endpoints,
        "summary": summary,
        "auth": {"requests": auth_rows, "failed_accounts": [{"account": a, "reason": r} for (a, r) in auth_failures]},
        "step_load": [
            {
                "step": s.step, "vus": s.vus, "start_s": round(s.start_s, 3),
                "end_s": round(s.end_s, 3), "total_requests": s.total_requests,
                "error_rate_pct": round(s.error_rate_pct, 2), "p95_ms": round(s.p95_ms, 2),
                "p99_ms": round(s.p99_ms, 2), "breached": s.breached,
            }
            for s in steps
        ],
        "capacity_knee_vus": capacity_knee(steps),
        "cumulative_timeseries": [
            {
                "timestamp": round(s.timestamp, 3),
                "total_requests": s.total_requests,
                "p50_ms": round(s.p50_ms, 2),
                "p95_ms": round(s.p95_ms, 2),
                "p99_ms": round(s.p99_ms, 2),
                "rps": round(s.rps, 2),
                "error_rate_pct": round(s.error_rate_pct, 2),
            }
            for s in snapshots
        ],
    };
}
