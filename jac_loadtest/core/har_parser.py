"""Parse HAR 1.2 files, filter non-API entries, and rewrite URLs.

Implemented in Phase 1. core/ has zero knowledge of jac-scale internals.
"""
from __future__ import annotations
from dataclasses import dataclass


@dataclass
class HarEntry:
    method: str
    url: str
    headers: dict[str, str]
    body: str | None
    body_mime: str | None
    think_time_ms: float
    is_login: bool
    original_url: str


def parse_har(
    har_path: str,
    target_url: str,
    include_static: bool = False,
    login_path: str = "/user/login",
) -> list[HarEntry]:
    raise NotImplementedError("HAR parsing is implemented in Phase 1.")
