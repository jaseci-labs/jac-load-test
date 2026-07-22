import math;
import time;
import from collections { deque }

obj RequestResult {
    has endpoint: str;
    has service: str;
    has status: int;
    has latency_ms: float;
    has bytes_received: int;
    has timestamp: float;
    has vu_id: int;
    has error_type: str | None;
    has expected_status: int = 200;
    has response_text: str | None = None;
    has occurrence: int = 1;
    has total_occurrences: int = 1;
    has ttfb_ms: float = 0.0;
    has latency_valid: bool = True;
}

obj EndpointStats {
    has endpoint: str;
    has service: str;
    has total_requests: int;
    has success_count: int;
    has error_count: int;
    has success_rate_pct: float;
    has min_ms: float;
    has max_ms: float;
    has mean_ms: float;
    has p50_ms: float;
    has p95_ms: float;
    has p99_ms: float;
    has latencies: list[float];
    has error_breakdown: dict[str, int];
    has p999_ms: float = 0.0;
    has rps: float = 0.0;
    has bytes_received: int = 0;
    has apdex: float = 0.0;
    has satisfied_count: int = 0;
    has tolerating_count: int = 0;
    has completion_p50_s: float = 0.0;
    has completion_p95_s: float = 0.0;
    has completion_p99_s: float = 0.0;
    has ttfb_ms: float = 0.0;
}

obj StatsSnapshot {
    has timestamp: float;
    has p50_ms: float;
    has p95_ms: float;
    has p99_ms: float;
    has rps: float;
    has error_rate_pct: float;
    has total_requests: int = 0;
}

def percentile(latencies: list[float], p: float) -> float {
    if not latencies {
        return 0.0;
    }
    sorted_l = sorted(latencies);
    idx = int(math.ceil(p / 100.0 * len(sorted_l))) - 1;
    return sorted_l[max(0, idx)];
}

def normalize_path(url: str) -> str {
    import re;
    import from urllib.parse { urlparse }
    parsed = urlparse(url);
    segments = parsed.path.split("/");
    normalized = [];
    for seg in segments {
        if re.fullmatch(r"\d+", seg) {
            normalized.append("{id}");
        } elif re.fullmatch(r"[0-9a-f\-]{32,36}", seg) {
            normalized.append("{id}");
        } else {
            normalized.append(seg);
        }
    }
    return "/".join(normalized);
}

obj MetricsCollector {
    has max_samples: int = 1_000_000;
    has total_count: int = 0;
    has error_count: int = 0;
    has _samples: deque[RequestResult] = deque();

    def __post_init__() {
        self._samples = deque(maxlen=self.max_samples);
    }

    def record(result: RequestResult) {
        self.total_count += 1;
        if result.error_type is not None or result.status != result.expected_status {
            self.error_count += 1;
        }
        self._samples.append(result);
    }

    def global_rps(duration_seconds: float) -> float {
        return self.total_count / max(duration_seconds, 0.001);
    }

    def measured_duration_s() -> float {
        # Wall time from the first request sent to the last response received,
        # derived from the samples themselves rather than the harness's own
        # start/stop clock. In multiprocess mode t_start is captured before
        # worker processes are spawned, so time.time() - t_start also bills
        # per-worker jaclang re-import/startup cost against throughput —
        # understating RPS by double digits percent. This window reflects only
        # what the target actually experienced.
        if not self._samples {
            return 0.0;
        }
        starts = [r.timestamp for r in self._samples];
        ends = [r.timestamp + r.latency_ms / 1000.0 for r in self._samples];
        return max(max(ends) - min(starts), 0.001);
    }

    def compute_endpoint_stats(
        t_start: float | None = None,
        apdex_t: float = 500.0,
        actual_duration_s: float | None = None,
    ) -> list[EndpointStats] {
        groups: dict[str, list[RequestResult]] = {};
        for result in self._samples {
            groups.setdefault(result.endpoint, []).append(result);
        }

        stats: list[EndpointStats] = [];

        for item in groups.items() {
            endpoint:str = str(item[0]);
            results:list[RequestResult] = list(item[1]);
            # Transport failures that never reached the server (connection refused,
            # DNS/SSL errors) carry a fabricated 0ms latency — mixing those into the
            # percentile pool makes latency look better the more the target fails.
            # Only samples with a real measured latency feed latency aggregations.
            timed_results: list[RequestResult] = [r for r in results if r.latency_valid];
            latencies: list[float] = [r.latency_ms for r in timed_results];
            ttfb_values: list[float] = [r.ttfb_ms for r in timed_results];
            total: int = len(results);
            success_count: int = len([r for r in results if r.error_type is None and r.status == r.expected_status]);
            error_count: int = total - success_count;
            success_rate: float = float(success_count / total * 100.0) if total else 0.0;

            error_breakdown: dict[str, int] = {};
            for r in results {
                if r.error_type is not None {
                    label = r.error_type;
                    if r.total_occurrences > 1 {
                        key = f"{label} (call #{r.occurrence} of {r.total_occurrences})";
                    } else {
                        key = label;
                    }
                } elif r.status != r.expected_status {
                    base = f"expected {r.expected_status} got {r.status}";
                    occurrence = f" (call #{r.occurrence} of {r.total_occurrences})" if r.total_occurrences > 1 else "";
                    body_snippet = f": {r.response_text}" if r.response_text else "";
                    key = f"{base}{occurrence}{body_snippet}";
                } else {
                    continue;
                }
                error_breakdown[key] = error_breakdown.get(key, 0) + 1;
            }

            service = results[0].service if results else "monolith";

            if t_start is not None {
                completion_times = [
                    (r.timestamp - t_start) + r.latency_ms / 1000.0
                    for r in results
                ];
                c_p50 = percentile(completion_times, 50);
                c_p95 = percentile(completion_times, 95);
                c_p99 = percentile(completion_times, 99);
            } else {
                c_p50 = 0.0;
                c_p95 = 0.0;
                c_p99 = 0.0;
            }

            ep_rps = float(total) / actual_duration_s if (actual_duration_s and actual_duration_s > 0) else 0.0;
            ep_bytes = sum(r.bytes_received for r in results);

            satisfied = 0;
            tolerating = 0;
            for r in results {
                if r.error_type is None and r.status == r.expected_status {
                    if r.latency_ms <= apdex_t {
                        satisfied += 1;
                    } elif r.latency_ms <= 4.0 * apdex_t {
                        tolerating += 1;
                    }
                }
            }
            ep_apdex = (satisfied + 0.5 * tolerating) / total if total else 0.0;

            stats.append(
                EndpointStats(
                    endpoint=endpoint,
                    service=service,
                    total_requests=total,
                    success_count=success_count,
                    error_count=error_count,
                    success_rate_pct=float(round(success_rate,1)),
                    min_ms=min(latencies) if latencies else 0.0,
                    max_ms=max(latencies) if latencies else 0.0,
                    mean_ms=sum(latencies) / len(latencies) if latencies else 0.0,
                    p50_ms=percentile(latencies, 50),
                    p95_ms=percentile(latencies, 95),
                    p99_ms=percentile(latencies, 99),
                    latencies=latencies,
                    error_breakdown=error_breakdown,
                    p999_ms=percentile(latencies, 99.9),
                    rps=ep_rps,
                    bytes_received=ep_bytes,
                    apdex=ep_apdex,
                    satisfied_count=satisfied,
                    tolerating_count=tolerating,
                    completion_p50_s=c_p50,
                    completion_p95_s=c_p95,
                    completion_p99_s=c_p99,
                    ttfb_ms=sum(ttfb_values) / len(ttfb_values) if ttfb_values else 0.0,
                )
            );
        }

        return stats;
    }

    def snapshot_now(t_start: float) -> StatsSnapshot {
        # Cumulative-since-t_start snapshot of whatever samples have been recorded so
        # far — used for live progress streaming during a run (see stream_metrics_callback
        # in core/engine.jac), as opposed to generate_timeseries() which bins full history
        # after the run completes.
        samples: list[RequestResult] = list(self._samples);
        latencies: list[float] = [r.latency_ms for r in samples if r.latency_valid];
        total: int = len(samples);
        errors: int = sum(
            1 for r in samples
            if r.error_type is not None or r.status != r.expected_status
        );
        elapsed: float = max(time.time() - t_start, 0.001);
        return StatsSnapshot(
            timestamp=elapsed,
            p50_ms=percentile(latencies, 50),
            p95_ms=percentile(latencies, 95),
            p99_ms=percentile(latencies, 99),
            rps=total / elapsed,
            error_rate_pct=(errors / total * 100.0) if total else 0.0,
            total_requests=total,
        );
    }

    def completion_percentiles(t_start: float) -> tuple[float, float, float] {
        times: list[float] = [
            (r.timestamp - t_start) + r.latency_ms / 1000.0
            for r in self._samples
        ];
        return (percentile(times, 50), percentile(times, 95), percentile(times, 99));
    }

    def generate_timeseries(
        t_start: float, interval: float = 10.0, actual_duration_s: float | None = None
    ) -> list[StatsSnapshot] {
        if not self._samples {
            return [];
        }

        buckets: dict[int, list[RequestResult]] = {};
        for r in self._samples {
            bucket = int((r.timestamp - t_start) / interval);
            if bucket >= 0 {
                buckets.setdefault(bucket, []).append(r);
            }
        }
        if not buckets {
            return [];
        }
        last_bucket_idx = max(buckets.keys());

        snapshots: list[StatsSnapshot] = [];
        running_total = 0;
        running_errors = 0;
        running_latencies: list[float] = [];
        for bucket_idx in sorted(buckets.keys()) {
            results:list[RequestResult] = list(buckets[bucket_idx]);
            running_total += len(results);
            running_errors += sum(
                1 for r in results
                if r.error_type is not None or r.status != r.expected_status
            );
            running_latencies.extend(r.latency_ms for r in results if r.latency_valid);
            # Bucket boundaries round elapsed time UP to the next `interval`
            # multiple, which is misleading for the final point — a run that
            # finishes in 3s would otherwise plot its only point at "10s".
            # Use the real measured duration for the last point instead.
            is_last = bucket_idx == last_bucket_idx;
            elapsed: float = (
                actual_duration_s if (is_last and actual_duration_s is not None)
                else float((bucket_idx + 1) * interval)
            );
            snapshots.append(StatsSnapshot(
                timestamp=elapsed,
                p50_ms=percentile(running_latencies, 50),
                p95_ms=percentile(running_latencies, 95),
                p99_ms=percentile(running_latencies, 99),
                rps=running_total / elapsed if elapsed > 0 else 0.0,
                error_rate_pct=(running_errors / running_total * 100.0) if running_total else 0.0,
                total_requests=running_total,
            ));
        }

        return snapshots;
    }
}
