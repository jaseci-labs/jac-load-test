"""Console (Rich), JSON, and HTML report rendering.

stdout: machine-readable output (json).
stderr: all human-readable output (console table, progress bar, warnings).

Implemented in Phase 1 (console), Phase 5 (JSON + HTML).
"""
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from jac_loadtest.core.metrics import EndpointStats
    from jac_loadtest.config import LoadTestConfig


def render_console(stats: list[EndpointStats], config: LoadTestConfig) -> None:
    raise NotImplementedError("Console reporter is implemented in Phase 1.")


def render_json(stats: list[EndpointStats], config: LoadTestConfig) -> str:
    raise NotImplementedError("JSON reporter is implemented in Phase 5.")


def render_html(stats: list[EndpointStats], config: LoadTestConfig) -> str:
    raise NotImplementedError("HTML reporter is implemented in Phase 5.")
