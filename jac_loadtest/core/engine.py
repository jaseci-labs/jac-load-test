"""asyncio VU pool: ramp-up, RPS cap, duration/iteration control.

Implemented in Phase 1. core/ has zero knowledge of jac-scale internals.
"""
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from jac_loadtest.core.har_parser import HarEntry
    from jac_loadtest.core.metrics import MetricsCollector
    from jac_loadtest.config import LoadTestConfig


async def run_all_vus(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: object | None = None,
    auth_provider: object | None = None,
) -> None:
    raise NotImplementedError("Load engine is implemented in Phase 1.")
