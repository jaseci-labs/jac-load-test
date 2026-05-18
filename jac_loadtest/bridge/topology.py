"""Build prefix→URL routing table from jac-scale ServiceRegistry or jac.toml.

Implements longest-prefix matching to mirror jac-scale's gateway routing.
Implemented in Phase 3.
"""
from __future__ import annotations


def build_routing_table(
    mode: str,
    base_url: str | None = None,
    services_map_json: str | None = None,
) -> dict[str, str]:
    raise NotImplementedError("Topology module is implemented in Phase 3.")


def resolve_url(path: str, routing_table: dict[str, str], fallback_url: str | None) -> str:
    """Longest-prefix match: mirrors jac-scale ServiceRegistry.match_route()."""
    for prefix in sorted(routing_table, key=len, reverse=True):
        if path.startswith(prefix):
            return routing_table[prefix]
    if fallback_url:
        return fallback_url
    raise ValueError(f"No route for path '{path}' and no --url fallback provided.")
