"""Pass/fail thresholds evaluated on a finished JSON report.

Pure functions over the report dict (see output/json_report.jac), so the CLI
exit code and the web app's pass/fail badge use one definition.
"""

import from ..config { LoadTestConfig }

def _fmt(x: float) -> str {
    return str(round(x, 1));
}

def evaluate(config: LoadTestConfig, result: dict[str, any]) -> list[str] {
    # Returns one human-readable line per breached threshold; empty means pass.
    out: list[str] = [];
    # A rule that never captured (envelope or schema drift) or never injected (a
    # target path that is not in the request) silently skips every request that
    # depends on it, so it can gate the run on its own, independent of the request
    # totals below.
    if config.fail_on_correlation_miss {
        unresolved = result.get("correlation", {}).get("unresolved", []);
        if unresolved {
            out.append("correlation rule(s) never worked: " + ", ".join(unresolved));
        }
    }
    summary = result.get("summary", {});
    total = summary.get("total_requests", 0);
    if total == 0 {
        return out;
    }
    # Blocked-by-infrastructure responses never reached the app: not rated.
    rated = total - summary.get("infra_block_count", 0);
    if rated <= 0 {
        return out;
    }
    err_rate = summary.get("error_count", 0) / rated * 100.0;
    if config.fail_on_error_rate is not None and err_rate > config.fail_on_error_rate {
        out.append("error_rate " + _fmt(err_rate) + "% > limit " + _fmt(config.fail_on_error_rate) + "%");
    }
    p95 = summary.get("p95_ms", 0.0);
    p99 = summary.get("p99_ms", 0.0);
    if config.fail_on_p95 is not None and p95 > config.fail_on_p95 {
        out.append("p95 " + _fmt(p95) + "ms > limit " + _fmt(config.fail_on_p95) + "ms");
    }
    if config.fail_on_p99 is not None and p99 > config.fail_on_p99 {
        out.append("p99 " + _fmt(p99) + "ms > limit " + _fmt(config.fail_on_p99) + "ms");
    }
    by_endpoint: dict[str, dict[str, any]] = {};
    for row in result.get("endpoints", []) {
        by_endpoint[row["endpoint"]] = row;
    }
    for (endpoint, limit) in config.fail_on_p95_scoped.items() {
        ep = by_endpoint.get(endpoint);
        if ep is not None and ep.get("p95_ms", 0.0) > limit {
            out.append(endpoint + " p95 " + _fmt(ep.get("p95_ms", 0.0)) + "ms > limit " + _fmt(limit) + "ms");
        }
    }
    for (endpoint, limit) in config.fail_on_p99_scoped.items() {
        ep = by_endpoint.get(endpoint);
        if ep is not None and ep.get("p99_ms", 0.0) > limit {
            out.append(endpoint + " p99 " + _fmt(ep.get("p99_ms", 0.0)) + "ms > limit " + _fmt(limit) + "ms");
        }
    }
    return out;
}
