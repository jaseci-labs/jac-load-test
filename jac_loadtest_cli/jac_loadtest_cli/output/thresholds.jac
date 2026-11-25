"""Pass/fail thresholds evaluated on a finished JSON report.

Pure functions over the report dict (see output/json_report.jac), so the CLI
exit code and the web app's pass/fail badge use one definition.
"""

import from ..config { LoadTestConfig }

def evaluate(config: LoadTestConfig, result: dict[str, any]) -> list[str] {
    # Returns one human-readable line per breached threshold; empty means pass.
    out: list[str] = [];
    summary = result.get("summary", {});
    total = summary.get("total_requests", 0);
    if total == 0 {
        return out;
    }
    err_rate = summary.get("error_count", 0) / total * 100.0;
    if config.fail_on_error_rate is not None and err_rate > config.fail_on_error_rate {
        out.append(f"error_rate {err_rate:.1f}% > limit {config.fail_on_error_rate:.1f}%");
    }
    p95 = summary.get("p95_ms", 0.0);
    p99 = summary.get("p99_ms", 0.0);
    if config.fail_on_p95 is not None and p95 > config.fail_on_p95 {
        out.append(f"p95 {p95:.1f}ms > limit {config.fail_on_p95:.1f}ms");
    }
    if config.fail_on_p99 is not None and p99 > config.fail_on_p99 {
        out.append(f"p99 {p99:.1f}ms > limit {config.fail_on_p99:.1f}ms");
    }
    by_endpoint = {ep["endpoint"]: ep for ep in result.get("endpoints", [])};
    for (endpoint, limit) in config.fail_on_p95_scoped.items() {
        ep = by_endpoint.get(endpoint);
        if ep is not None and ep.get("p95_ms", 0.0) > limit {
            out.append(f"{endpoint} p95 {ep['p95_ms']:.1f}ms > limit {limit:.1f}ms");
        }
    }
    for (endpoint, limit) in config.fail_on_p99_scoped.items() {
        ep = by_endpoint.get(endpoint);
        if ep is not None and ep.get("p99_ms", 0.0) > limit {
            out.append(f"{endpoint} p99 {ep['p99_ms']:.1f}ms > limit {limit:.1f}ms");
        }
    }
    return out;
}
