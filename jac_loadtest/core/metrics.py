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
    rps: float
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
    """Replace UUID and integer path segments with {id}."""
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

    def compute_endpoint_stats(self, duration_seconds: float) -> list[EndpointStats]:
        raise NotImplementedError("Metrics aggregation is implemented in Phase 1.")
