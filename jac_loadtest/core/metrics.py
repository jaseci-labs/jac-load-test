"""Per-request recording, latency histograms, percentile calculation.

Three-layer storage (Phase 4):
  Layer 1 — total_count (always accurate RPS)
  Layer 2 — deque(maxlen=max_samples) of RequestResult (percentiles)
  Layer 3 — list[StatsSnapshot] every 5s (time-series charts)

Phase 0: dataclasses only.
"""
from __future__ import annotations
import math
from dataclasses import dataclass, field
from collections import deque


@dataclass
class RequestResult:
    endpoint: str
    service: str
    status: int
    latency_ms: float
    bytes_received: int
    timestamp: float
    vu_id: int
    error_type: str | None  # None | "TIMEOUT" | "CONNECTION_REFUSED" | "DNS_ERROR" | "SSL_ERROR"
    occurrence: int = 1
    total_occurrences: int = 1


@dataclass
class EndpointStats:
    endpoint: str
    service: str
    total_requests: int
    success_count: int
    error_count: int
    success_rate_pct: float
    min_ms: float
    max_ms: float
    mean_ms: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    error_breakdown: dict[str, int] = field(default_factory=dict)


@dataclass
class StatsSnapshot:
    timestamp: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    rps: float
    error_rate_pct: float


def percentile(latencies: list[float], p: float) -> float:
    if not latencies:
        return 0.0
    sorted_l = sorted(latencies)
    idx = int(math.ceil(p / 100.0 * len(sorted_l))) - 1
    return sorted_l[max(0, idx)]


def normalize_path(url: str) -> str:
    """Extract path from URL and replace UUID/integer segments with {id}.

    Strips scheme and host so the endpoint label is consistent regardless of
    whether the URL was rewritten (monolith) or kept as recorded (microservice).
    """
    import re
    from urllib.parse import urlparse
    parsed = urlparse(url)
    segments = parsed.path.split("/")
    normalized = []
    for seg in segments:
        if re.fullmatch(r"\d+", seg):
            normalized.append("{id}")
        elif re.fullmatch(r"[0-9a-f\-]{32,36}", seg):
            normalized.append("{id}")
        else:
            normalized.append(seg)
    return "/".join(normalized)


class MetricsCollector:
    def __init__(self, max_samples: int = 1_000_000) -> None:
        self.total_count: int = 0
        self._samples: deque[RequestResult] = deque(maxlen=max_samples)
        self._snapshots: list[StatsSnapshot] = []

    def record(self, result: RequestResult) -> None:
        self.total_count += 1
        self._samples.append(result)

    def global_rps(self, duration_seconds: float) -> float:
        """Return total requests per second across all endpoints."""
        return self.total_count / max(duration_seconds, 0.001)

    def compute_endpoint_stats(self) -> list[EndpointStats]:
        """Aggregate per-endpoint stats from collected samples."""
        groups: dict[str, list[RequestResult]] = {}
        for result in self._samples:
            groups.setdefault(result.endpoint, []).append(result)

        stats: list[EndpointStats] = []

        for endpoint, results in groups.items():
            latencies = [r.latency_ms for r in results]
            total = len(results)
            success_count = sum(
                1 for r in results if r.error_type is None and 200 <= r.status < 300
            )
            error_count = total - success_count
            success_rate = (success_count / total * 100.0) if total else 0.0

            error_breakdown: dict[str, int] = {}
            for r in results:
                if r.error_type is not None:
                    label = r.error_type
                elif not (200 <= r.status < 300):
                    label = str(r.status)
                else:
                    continue
                if r.total_occurrences > 1:
                    key = f"{label} (call #{r.occurrence} of {r.total_occurrences})"
                else:
                    key = label
                error_breakdown[key] = error_breakdown.get(key, 0) + 1

            service = results[0].service if results else "monolith"

            stats.append(
                EndpointStats(
                    endpoint=endpoint,
                    service=service,
                    total_requests=total,
                    success_count=success_count,
                    error_count=error_count,
                    success_rate_pct=round(success_rate, 1),
                    min_ms=min(latencies) if latencies else 0.0,
                    max_ms=max(latencies) if latencies else 0.0,
                    mean_ms=sum(latencies) / len(latencies) if latencies else 0.0,
                    p50_ms=percentile(latencies, 50),
                    p95_ms=percentile(latencies, 95),
                    p99_ms=percentile(latencies, 99),
                    error_breakdown=error_breakdown,
                )
            )

        return stats

    def flush_snapshot(self, timestamp: float, duration_seconds: float) -> None:
        """Record a 5-second interval snapshot (for time-series charts)."""
        latencies = [r.latency_ms for r in self._samples]
        safe_duration = max(duration_seconds, 0.001)
        total = len(self._samples)
        error_count = sum(
            1 for r in self._samples
            if r.error_type is not None or not (200 <= r.status < 300)
        )
        self._snapshots.append(
            StatsSnapshot(
                timestamp=timestamp,
                p50_ms=percentile(latencies, 50),
                p95_ms=percentile(latencies, 95),
                p99_ms=percentile(latencies, 99),
                rps=self.total_count / safe_duration,
                error_rate_pct=(error_count / total * 100.0) if total else 0.0,
            )
        )
