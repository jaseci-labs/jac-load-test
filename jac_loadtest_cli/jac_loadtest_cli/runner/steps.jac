"""Step-load: add users in steps and find the capacity knee.

Each step holds a user count for step_duration, then judges THAT STEP'S OWN
traffic against --fail-on-* thresholds. Judging the cumulative run instead would
dilute a breach at step 5 with four passing steps' worth of requests and hide the
knee. Locust only keeps cumulative histograms, so a step's window is the
difference between the histogram now and the one captured at the step's start.

The knee is the highest user count whose step did not breach.
"""

import from locust.stats { StatsEntry }
import from ..config { LoadTestConfig }

obj StepResult {
    has step: int;
    has vus: int;
    has start_s: float;
    has end_s: float;
    has total_requests: int;
    has error_rate_pct: float;
    has p95_ms: float;
    has p99_ms: float;
    has breached: bool;
}

obj Mark {
    # Cumulative counters at the start of a step.
    has requests: int = 0;
    has failures: int = 0;
    has times: dict[int, int] = {};
}

def mark_of(agg: StatsEntry) -> Mark {
    return Mark(
        requests=agg.num_requests, failures=agg.num_failures,
        times={int(k): int(v) for (k, v) in agg.response_times.items()},
    );
}

def percentile_from(times: dict[int, int], pct: float) -> float {
    total = sum(times.values());
    if total <= 0 {
        return 0.0;
    }
    need = total * pct / 100.0;
    seen = 0;
    for k in sorted(times.keys()) {
        seen += times[k];
        if seen >= need {
            return float(k);
        }
    }
    return float(max(times.keys()));
}

def window_between(start: Mark, now: Mark) -> tuple[int, int, dict[int, int]] {
    times: dict[int, int] = {};
    for (k, v) in now.times.items() {
        d = v - start.times.get(k, 0);
        if d > 0 {
            times[k] = d;
        }
    }
    return (now.requests - start.requests, now.failures - start.failures, times);
}

def breached_window(config: LoadTestConfig, total: int, error_rate_pct: float, times: dict[int, int]) -> bool {
    if total == 0 {
        return False;
    }
    if config.fail_on_error_rate is not None and error_rate_pct > config.fail_on_error_rate {
        return True;
    }
    wants_latency = config.fail_on_p95 is not None or config.fail_on_p99 is not None;
    if wants_latency and not times {
        # Every request in the window failed before a response: a dead target must
        # not read as a passing p95/p99.
        return True;
    }
    if config.fail_on_p95 is not None and percentile_from(times, 95) > config.fail_on_p95 {
        return True;
    }
    if config.fail_on_p99 is not None and percentile_from(times, 99) > config.fail_on_p99 {
        return True;
    }
    return False;
}

def judge_step(
    config: LoadTestConfig, step: int, vus: int, start_s: float, end_s: float,
    start: Mark, now: Mark,
) -> StepResult {
    window = window_between(start, now);
    total = window[0];
    err_rate = (window[1] / total * 100.0) if total else 0.0;
    return StepResult(
        step=step, vus=vus, start_s=start_s, end_s=end_s, total_requests=total,
        error_rate_pct=err_rate,
        p95_ms=percentile_from(window[2], 95), p99_ms=percentile_from(window[2], 99),
        breached=breached_window(config, total, err_rate, window[2]),
    );
}

def next_vus(config: LoadTestConfig, current: int) -> int {
    # Returns the next user count, or `current` when already at the ceiling.
    if config.step_max_vus > 0 and current >= config.step_max_vus {
        return current;
    }
    add = config.step_vus;
    if config.step_max_vus > 0 {
        add = min(add, config.step_max_vus - current);
    }
    return current + max(add, 0);
}

def capacity_knee(steps: list[StepResult]) -> int | None {
    for s in reversed(steps) {
        if not s.breached {
            return s.vus;
        }
    }
    return None;
}

def validate_step_config(config: LoadTestConfig) -> None {
    if not config.step_load {
        return;
    }
    if config.step_vus <= 0 {
        raise ValueError("step_load requires step_vus to be set to a positive value");
    }
    has_threshold = (
        config.fail_on_error_rate is not None
        or config.fail_on_p95 is not None
        or config.fail_on_p99 is not None
    );
    if config.step_max_vus <= 0 and not has_threshold {
        raise ValueError(
            "step_load requires step_max_vus or at least one of "
            "fail_on_error_rate/fail_on_p95/fail_on_p99 -- otherwise the ramp "
            "has no stopping condition"
        );
    }
}
