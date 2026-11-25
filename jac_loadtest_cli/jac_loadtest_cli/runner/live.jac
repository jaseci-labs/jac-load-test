"""Live sampling of a running Locust environment.

Locust keeps cumulative stats; the web app and --abort-on-fail need periodic
snapshots and a way to ask "has a threshold been breached yet?". Both are read
off the same aggregate so they agree with the final report.

Percentiles come from Locust's own histogram (response times above 100 ms are
bucketed to two significant digits), so they are close to, not byte-identical
with, an exact sort of every sample.
"""

import from locust.stats { StatsEntry }
import from ..config { LoadTestConfig }

glob AUTH_PREFIX: str = "auth: ";

obj Snapshot {
    has timestamp: float = 0.0;
    has total_requests: int = 0;
    has p50_ms: float = 0.0;
    has p95_ms: float = 0.0;
    has p99_ms: float = 0.0;
    has rps: float = 0.0;
    has error_rate_pct: float = 0.0;
}

def aggregate(env: any) -> StatsEntry {
    # Every replayed request, excluding the login/register traffic that precedes
    # it -- the same population the old report rolled up.
    agg = StatsEntry(env.stats, "Aggregated", "");
    for item in env.stats.entries.items() {
        if not item[0][0].startswith(AUTH_PREFIX) {
            agg.extend(item[1]);
        }
    }
    return agg;
}

def take_snapshot(env: any, elapsed_s: float) -> Snapshot {
    agg = aggregate(env);
    n = agg.num_requests;
    return Snapshot(
        timestamp=elapsed_s,
        total_requests=n,
        p50_ms=float(agg.get_response_time_percentile(0.50) or 0),
        p95_ms=float(agg.get_response_time_percentile(0.95) or 0),
        p99_ms=float(agg.get_response_time_percentile(0.99) or 0),
        rps=(n / elapsed_s) if elapsed_s > 0 else 0.0,
        error_rate_pct=(agg.num_failures / n * 100.0) if n else 0.0,
    );
}

def breached(config: LoadTestConfig, env: any) -> bool {
    # Global thresholds only (error rate, p95, p99) -- what --abort-on-fail checks.
    agg = aggregate(env);
    if agg.num_requests == 0 {
        return False;
    }
    rate = agg.num_failures / agg.num_requests * 100.0;
    if config.fail_on_error_rate is not None and rate > config.fail_on_error_rate {
        return True;
    }
    if config.fail_on_p95 is not None {
        if agg.get_response_time_percentile(0.95) > config.fail_on_p95 {
            return True;
        }
    }
    if config.fail_on_p99 is not None {
        if agg.get_response_time_percentile(0.99) > config.fail_on_p99 {
            return True;
        }
    }
    return False;
}
