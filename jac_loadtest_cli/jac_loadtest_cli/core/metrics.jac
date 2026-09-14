import math;
import sys;
import time;
import from collections { deque }

glob _MAX_ERROR_SAMPLES: int = 3;

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
    has trace_id: str | None = None;
    # Phase 9 — which adapter produced this sample: "http" (core/engine.jac,
    # the default and only value before Phase 9), "ws" (core/ws_engine.jac),
    # or "graphql" (core/graphql_engine.jac). Lets one run mix protocols and
    # still get a correct per-protocol breakdown out of a single collector.
    has protocol: str = "http";
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
    has error_samples: dict[str, list[str]];
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
    has protocol: str = "http";
}

obj StatsSnapshot {
    has timestamp: float;
    has p50_ms: float;
    has p95_ms: float;
    has p99_ms: float;
    has rps: float;
    has error_rate_pct: float;
    has total_requests: int = 0;
    # Phase 8d - the latency distribution behind p50/p95/p99, as bucket counts
    # (see histogram_bucket()). Finished percentiles cannot be averaged back
    # into a percentile, so a cross-worker merge needs the distribution itself;
    # core/process_runner.jac sums these and reads the merged percentiles off
    # the result. Empty on snapshots built without one (generate_timeseries(),
    # hand-constructed test fixtures), in which case the merge falls back to
    # request-weighted averaging.
    has latency_buckets: list[int] = [];
}

obj StepResult {
    # One rung of a --step-load ramp: the VU count held during [start_s, end_s)
    # and what that window's OWN traffic looked like — not blended with earlier,
    # lower-load steps — so a breach at step 5 is visible instead of averaged away.
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

def percentile(latencies: list[float], p: float) -> float {
    if not latencies {
        return 0.0;
    }
    sorted_l = sorted(latencies);
    idx = int(math.ceil(p / 100.0 * len(sorted_l))) - 1;
    return sorted_l[max(0, idx)];
}

# ---------------------------------------------------------------------------
# Latency histogram (Phase 8d)
#
# A live cross-worker reading cannot be built from finished percentiles: an
# average of four workers' p95 values is not the fleet's p95, and the error is
# unbounded (a worker doing 10 slow requests and one doing 10,000 fast ones
# average to something neither of them saw). Workers therefore ship the shape
# of their latency distribution instead, as counts in fixed exponential
# buckets, and the controller sums the buckets and reads percentiles off the
# total. Bucket edges are constants, so every worker's array lines up index for
# index and merging is plain addition.
#
# Buckets grow 5% at a time, so a percentile read back out is at most ~5% above
# the true value -- bounded, and always on the pessimistic side, which is the
# right direction for a live indicator and for a threshold check. The array is
# a fixed 300 entries regardless of VU count or request volume, covering 0.5 ms
# to ~18 minutes; that ceiling is far above any usable --timeout, and anything
# past it lands in the top bucket rather than being lost.
#
# This is only ever used for the *live* view and the mid-run --abort-on-fail
# decision. The final report still computes exact percentiles from the merged
# raw samples (compute_endpoint_stats()) and is unaffected.
# ---------------------------------------------------------------------------

glob HISTOGRAM_MIN_MS: float = 0.5;
glob HISTOGRAM_GROWTH: float = 1.05;
glob HISTOGRAM_BUCKETS: int = 300;

def histogram_bucket(latency_ms: float) -> int {
    # Bucket 0 holds everything at or below HISTOGRAM_MIN_MS; bucket i holds
    # (MIN * GROWTH^(i-1), MIN * GROWTH^i]. Latencies past the last bucket's
    # edge are clamped into it rather than dropped, so the count stays honest
    # even if the percentile saturates.
    if latency_ms <= HISTOGRAM_MIN_MS {
        return 0;
    }
    raw = math.log(latency_ms / HISTOGRAM_MIN_MS) / math.log(HISTOGRAM_GROWTH);
    idx = int(math.ceil(raw));
    if idx < 1 {
        return 1;
    }
    if idx >= HISTOGRAM_BUCKETS {
        return HISTOGRAM_BUCKETS - 1;
    }
    return idx;
}

def histogram_bucket_upper_ms(index: int) -> float {
    return HISTOGRAM_MIN_MS * (HISTOGRAM_GROWTH ** index);
}

def build_histogram(latencies: list[float]) -> list[int] {
    buckets = [0] * HISTOGRAM_BUCKETS;
    for value in latencies {
        buckets[histogram_bucket(value)] += 1;
    }
    return buckets;
}

def merge_histograms(histograms: list[list[int]]) -> list[int] {
    merged = [0] * HISTOGRAM_BUCKETS;
    for hist in histograms {
        for i in range(min(len(hist), HISTOGRAM_BUCKETS)) {
            merged[i] += hist[i];
        }
    }
    return merged;
}

def histogram_total(buckets: list[int]) -> int {
    return sum(buckets);
}

def histogram_percentile(buckets: list[int], p: float) -> float {
    # Same rank convention as percentile() above (ceil(p/100 * n)), so a
    # histogram reading and an exact reading pick the same sample -- they differ
    # only in that this one reports that sample's bucket ceiling instead of its
    # precise value.
    total = sum(buckets);
    if total == 0 {
        return 0.0;
    }
    rank = int(math.ceil(p / 100.0 * total));
    if rank < 1 {
        rank = 1;
    }
    seen = 0;
    for i in range(len(buckets)) {
        seen += buckets[i];
        if seen >= rank {
            return histogram_bucket_upper_ms(i);
        }
    }
    return histogram_bucket_upper_ms(len(buckets) - 1);
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

# Checked in priority order — traceparent (W3C Trace Context) first since it's
# the interoperable standard; the rest are common proprietary conventions
# (Zipkin/B3, AWS X-Ray, generic request-id) seen on jac-scale/gateway responses.
glob _TRACE_HEADER_CANDIDATES: list[str] = [
    "traceparent",
    "x-trace-id",
    "x-b3-traceid",
    "x-amzn-trace-id",
    "x-request-id",
];

def extract_trace_id(headers: object) -> str | None {
    # `headers` is expected to be a case-insensitive mapping (e.g. aiohttp's
    # CIMultiDictProxy on resp.headers) so header casing from the target
    # doesn't matter here.
    for name in _TRACE_HEADER_CANDIDATES {
        val = headers.get(name);
        if val {
            if name == "traceparent" {
                # W3C format: "<version>-<trace-id>-<parent-id>-<flags>" —
                # surface just the trace-id segment, not the full context.
                parts = val.split("-");
                if len(parts) >= 2 and parts[1] {
                    return parts[1];
                }
            } else {
                return val;
            }
        }
    }
    return None;
}

obj MetricsCollector {
    has max_samples: int = 1_000_000;
    has total_count: int = 0;
    has error_count: int = 0;
    has samples_evicted: int = 0;
    has step_results: list[StepResult] = [];
    has _samples: deque[RequestResult] = deque();
    # Phase 8d - running latency distribution, updated on every record(). Kept
    # alongside the sample deque rather than derived from it so snapshot_now()
    # stays O(1): that call is now made once a second (not once per
    # --stream-interval) whenever the controller owns the --abort-on-fail
    # decision, and rescanning up to --max-samples entries at that rate would
    # cost real throughput. It also survives deque eviction, so the live view
    # reflects the whole run instead of only the retained tail.
    has _latency_buckets: list[int] = [];

    def __post_init__() {
        self._samples = deque(maxlen=self.max_samples);
        self._latency_buckets = [0] * HISTOGRAM_BUCKETS;
    }

    def record(result: RequestResult) {
        self.total_count += 1;
        if result.error_type is not None or result.status != result.expected_status {
            self.error_count += 1;
        }
        if result.latency_valid {
            self._latency_buckets[histogram_bucket(result.latency_ms)] += 1;
        }
        # deque(maxlen=...) evicts the oldest sample silently once full; warn
        # once as it starts happening so a 1M+ request run doesn't leave the
        # operator thinking every request fed the percentiles below.
        if self.max_samples > 0 and len(self._samples) >= self.max_samples {
            if self.samples_evicted == 0 {
                print(
                    f"Warning: sample buffer full at {self.max_samples} — "
                    "older samples are being evicted; percentiles reflect only "
                    "the most recently retained window, not the full run.",
                    file=sys.stderr,
                );
            }
            self.samples_evicted += 1;
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
        # Grouped by (protocol, endpoint) rather than endpoint alone — a mixed
        # run (e.g. HTTP + a GraphQL subscription hitting the same path) must
        # not blend an HTTP p95 with a GraphQL event-delivery p95 into one
        # meaningless row.
        groups: dict[tuple[str, str], list[RequestResult]] = {};
        for result in self._samples {
            groups.setdefault((result.protocol, result.endpoint), []).append(result);
        }

        stats: list[EndpointStats] = [];

        for item in groups.items() {
            protocol:str = str(item[0][0]);
            endpoint:str = str(item[0][1]);
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
            # A handful of example trace IDs per error class — enough to jump
            # from a red cell in the report straight into Tempo/Loki without
            # storing a trace ID for every one of potentially millions of
            # identical errors.
            error_samples: dict[str, list[str]] = {};
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
                if r.trace_id {
                    samples = error_samples.setdefault(key, []);
                    if len(samples) < _MAX_ERROR_SAMPLES {
                        samples.append(r.trace_id);
                    }
                }
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
                    protocol=protocol,
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
                    error_samples=error_samples,
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
        # Cumulative-since-t_start snapshot of the run so far — used for live
        # progress streaming (stream_metrics_callback in core/engine.jac) and, in
        # multiprocess mode, as the reading the controller merges to make the
        # --abort-on-fail decision. generate_timeseries() bins full history after
        # the run instead, and the final report is exact either way.
        #
        # Reads the running counters and the running histogram rather than
        # rescanning and sorting the sample deque. Two consequences worth knowing:
        # this is O(1) rather than O(n log n), which matters now that it can be
        # called once a second; and totals cover the whole run rather than only
        # the window --max-samples happened to retain, so a long run's live rps no
        # longer sags once eviction starts. Percentiles are histogram reads, so
        # they can sit up to one bucket (~5%) high — the same reading a merged
        # multiprocess snapshot gives, which is the point: the live view must not
        # change meaning with --workers.
        buckets: list[int] = list(self._latency_buckets);
        total: int = self.total_count;
        elapsed: float = max(time.time() - t_start, 0.001);
        return StatsSnapshot(
            timestamp=elapsed,
            p50_ms=histogram_percentile(buckets, 50),
            p95_ms=histogram_percentile(buckets, 95),
            p99_ms=histogram_percentile(buckets, 99),
            rps=total / elapsed,
            error_rate_pct=(self.error_count / total * 100.0) if total else 0.0,
            total_requests=total,
            latency_buckets=buckets,
        );
    }

    def completion_percentiles(t_start: float) -> tuple[float, float, float] {
        times: list[float] = [
            (r.timestamp - t_start) + r.latency_ms / 1000.0
            for r in self._samples
        ];
        return (percentile(times, 50), percentile(times, 95), percentile(times, 99));
    }

    def _bucket_by_interval(t_start: float, interval: float) -> dict[int, list[RequestResult]] {
        buckets: dict[int, list[RequestResult]] = {};
        for r in self._samples {
            bucket = int((r.timestamp - t_start) / interval);
            if bucket >= 0 {
                buckets.setdefault(bucket, []).append(r);
            }
        }
        return buckets;
    }

    def _bucket_elapsed(
        bucket_idx: int, last_bucket_idx: int, interval: float, actual_duration_s: float | None
    ) -> float {
        # Bucket boundaries round elapsed time UP to the next `interval`
        # multiple, which is misleading for the final point — a run that
        # finishes in 3s would otherwise plot its only point at "10s".
        # Use the real measured duration for the last point instead.
        is_last = bucket_idx == last_bucket_idx;
        return (
            actual_duration_s if (is_last and actual_duration_s is not None)
            else float((bucket_idx + 1) * interval)
        );
    }

    def generate_timeseries(
        t_start: float, interval: float = 10.0, actual_duration_s: float | None = None
    ) -> list[StatsSnapshot] {
        buckets = self._bucket_by_interval(t_start, interval);
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
            elapsed = self._bucket_elapsed(bucket_idx, last_bucket_idx, interval, actual_duration_s);
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

    def generate_interval_timeseries(
        t_start: float, interval: float = 10.0, actual_duration_s: float | None = None
    ) -> list[StatsSnapshot] {
        # Windowed counterpart to generate_timeseries(): each point reflects
        # only the requests that landed in that bucket, not the running total.
        # A burst confined to a single bucket shows up as a spike here — in
        # the cumulative series it gets diluted by every prior bucket and can
        # be invisible without hand-differencing consecutive points.
        buckets = self._bucket_by_interval(t_start, interval);
        if not buckets {
            return [];
        }
        last_bucket_idx = max(buckets.keys());

        snapshots: list[StatsSnapshot] = [];
        for bucket_idx in sorted(buckets.keys()) {
            results:list[RequestResult] = list(buckets[bucket_idx]);
            bucket_total = len(results);
            bucket_errors = sum(
                1 for r in results
                if r.error_type is not None or r.status != r.expected_status
            );
            bucket_latencies = [r.latency_ms for r in results if r.latency_valid];
            elapsed = self._bucket_elapsed(bucket_idx, last_bucket_idx, interval, actual_duration_s);
            bucket_start = float(bucket_idx * interval);
            bucket_duration = elapsed - bucket_start;
            snapshots.append(StatsSnapshot(
                timestamp=elapsed,
                p50_ms=percentile(bucket_latencies, 50),
                p95_ms=percentile(bucket_latencies, 95),
                p99_ms=percentile(bucket_latencies, 99),
                rps=bucket_total / bucket_duration if bucket_duration > 0 else 0.0,
                error_rate_pct=(bucket_errors / bucket_total * 100.0) if bucket_total else 0.0,
                total_requests=bucket_total,
            ));
        }

        return snapshots;
    }
}
