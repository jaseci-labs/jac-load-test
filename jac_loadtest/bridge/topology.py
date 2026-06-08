"""Build prefix→URL routing table from jac-scale ServiceRegistry or jac.toml.

Implements longest-prefix matching to mirror jac-scale's gateway routing algorithm:
    path == prefix  OR  path.startswith(prefix + "/")
Empty prefix is a catch-all (used for monolith mode).

Implemented in Phase 3.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from urllib.parse import urlparse, urlunparse
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from jac_loadtest.config import LoadTestConfig


@dataclass
class ServiceRoute:
    name: str    # service label used in metrics/report (e.g. "order_service")
    prefix: str  # path prefix for routing (e.g. "/walker/order"); "" = catch-all
    url: str     # service base URL, no trailing slash (e.g. "http://localhost:18001")


class TopologyRouter:
    """Routes a HAR entry URL to the correct service URL and returns the service name.

    Construction: TopologyRouter.from_config(config) is the normal entry point.
    Direct construction (TopologyRouter(routes, fallback_url)) is used in tests.
    """

    def __init__(
        self,
        routes: list[ServiceRoute],
        fallback_url: str | None = None,
    ) -> None:
        # Sort once at construction — longest prefix first (mirrors ServiceRegistry)
        self._routes = sorted(routes, key=lambda r: len(r.prefix), reverse=True)
        self._fallback_url = fallback_url

    def resolve(self, entry_url: str) -> tuple[str, str]:
        """Return (routed_full_url, service_name) for the given HAR entry URL.

        Reconstructs the full URL using the matched service's base + original path + query.
        Match logic mirrors jac-scale ServiceRegistry.match_route() exactly:
            empty prefix  → catch-all (monolith)
            path == prefix OR path.startswith(prefix + "/")
        """
        parsed = urlparse(entry_url)
        path = parsed.path

        for route in self._routes:
            if _prefix_matches(path, route.prefix):
                t = urlparse(route.url)
                # Strip the gateway prefix before sending directly to the service.
                # jac-scale's gateway strips the route prefix when forwarding; we replicate
                # that so the service receives the path it actually handles.
                # Empty prefix (monolith catch-all) keeps the path unchanged.
                if route.prefix:
                    service_path = path[len(route.prefix):] or "/"
                else:
                    service_path = path
                base_path = t.path.rstrip("/") if t.path else ""
                routed_path = f"{base_path}{service_path}" if base_path else service_path
                routed = urlunparse((
                    t.scheme, t.netloc,
                    routed_path, parsed.params, parsed.query, "",
                ))
                return routed, route.name

        if self._fallback_url:
            t = urlparse(self._fallback_url)
            base_path = t.path.rstrip("/") if t.path else ""
            routed_path = f"{base_path}{path}" if base_path else path
            routed = urlunparse((
                t.scheme, t.netloc,
                routed_path, parsed.params, parsed.query, "",
            ))
            return routed, "gateway"

        raise ValueError(
            f"No route for path '{path}' and no --url fallback provided. "
            "Use --services-map or add [plugins.scale.microservices.routes] to jac.toml."
        )

    @classmethod
    def from_config(cls, config: LoadTestConfig) -> TopologyRouter:
        """Build a TopologyRouter from LoadTestConfig.

        Monolith mode: single catch-all route to config.url.
        Microservice mode: --services-map JSON (highest priority) or jac.toml auto-discovery.
        """
        if config.mode != "microservice":
            return cls(
                routes=[ServiceRoute(name="monolith", prefix="", url=config.url or "")],
                fallback_url=None,
            )
        return cls._build_microservice(config)

    @classmethod
    def _build_microservice(cls, config: LoadTestConfig) -> TopologyRouter:
        toml_routes = _load_toml_routes()   # service_name → prefix; {} if unavailable

        routes: list[ServiceRoute]

        if config.services_map:
            try:
                services_json: dict[str, str] = json.loads(config.services_map)
            except json.JSONDecodeError as exc:
                raise ValueError(f"--services-map is not valid JSON: {exc}") from exc

            routes = [
                ServiceRoute(
                    # Strip leading slash from name so service labels display cleanly
                    name=name.lstrip("/") if name.startswith("/") else name,
                    # Key starting with "/" is used directly as prefix; otherwise derive from key
                    prefix=toml_routes.get(name, name if name.startswith("/") else f"/{name}"),
                    url=url.rstrip("/"),
                )
                for name, url in services_json.items()
            ]
            return cls(routes, fallback_url=config.url)

        # Auto-discovery: jac.toml routes + JAC_SV_<NAME>_URL env vars
        if not toml_routes:
            raise ValueError(
                "Microservice mode requires either --services-map or "
                "[plugins.scale.microservices.routes] in jac.toml. Neither was found."
            )

        routes = []
        missing: list[str] = []
        for name, prefix in toml_routes.items():
            env_var = f"JAC_SV_{name.upper()}_URL"
            url = os.environ.get(env_var)
            if not url:
                missing.append(env_var)
            else:
                routes.append(ServiceRoute(name=name, prefix=prefix, url=url.rstrip("/")))

        if missing:
            raise ValueError(
                f"Microservice mode: missing environment variable(s): {', '.join(missing)}. "
                "Expected format: JAC_SV_<SERVICE_NAME>_URL=http://host:port"
            )

        return cls(routes, fallback_url=config.url)


def _prefix_matches(path: str, prefix: str) -> bool:
    """Return True if path matches prefix using jac-scale's exact routing semantics."""
    if not prefix:
        return True  # empty prefix = catch-all (monolith)
    return path == prefix or path.startswith(prefix + "/")


def _load_toml_routes() -> dict[str, str]:
    """Read [plugins.scale.microservices.routes] from jac.toml.

    Returns {service_name: prefix} dict.
    Returns {} on any error (missing file, missing section, jac_scale unavailable).

    Isolated as a module-level function so tests can monkeypatch it without
    importing jac_scale at all — keeping topology unit tests jac-scale-free.
    """
    try:
        from pathlib import Path
        from jac_scale.config_loader import get_scale_config, reset_scale_config
        reset_scale_config()
        ms_config = get_scale_config(project_dir=Path.cwd()).get_microservices_config()
        return dict(ms_config.get("routes", {}))
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# Backward-compat shims — kept so any external code that imported these names
# does not break.  Neither is called by production or test code in this repo.
# ---------------------------------------------------------------------------

def build_routing_table(
    mode: str,
    base_url: str | None = None,
    services_map_json: str | None = None,
) -> dict[str, str]:
    raise NotImplementedError(
        "build_routing_table() is deprecated. Use TopologyRouter.from_config() instead."
    )


def resolve_url(path: str, routing_table: dict[str, str], fallback_url: str | None) -> str:
    """Longest-prefix match: mirrors jac-scale ServiceRegistry.match_route()."""
    for prefix in sorted(routing_table, key=len, reverse=True):
        if path.startswith(prefix):
            return routing_table[prefix]
    if fallback_url:
        return fallback_url
    raise ValueError(f"No route for path '{path}' and no --url fallback provided.")
