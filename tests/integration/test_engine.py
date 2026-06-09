"""Integration tests for core/engine.py — VU lifecycle against in-process aiohttp servers.

Phase 3 adds two microservice-mode tests.
Phase 4 will add the full engine test suite (duration cap, iteration cap, ramp-up, etc.)
"""
from __future__ import annotations

import aiohttp
import aiohttp.web
import pytest

from jac_loadtest.bridge.topology import TopologyRouter, ServiceRoute
from jac_loadtest.config import LoadTestConfig
from jac_loadtest.core.engine import run_all_vus
from jac_loadtest.core.har_parser import HarEntry
from jac_loadtest.core.metrics import MetricsCollector


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_json_app() -> aiohttp.web.Application:
    async def _ok(r: aiohttp.web.Request) -> aiohttp.web.Response:
        return aiohttp.web.json_response({"ok": True})

    app = aiohttp.web.Application()
    app.router.add_route("*", "/{path_info:.*}", _ok)
    return app


def _entry(url: str, path: str) -> HarEntry:
    return HarEntry(
        method="POST",
        url=url,
        headers={},
        body=None,
        body_mime=None,
        think_time_ms=0.0,
        is_login=False,
        original_url=path,
    )


# ---------------------------------------------------------------------------
# Microservice mode: service label in metrics
# ---------------------------------------------------------------------------

@pytest.mark.integration
async def test_microservice_service_label_in_metrics():
    """RequestResult.service is set to the matched service name from topology."""
    from aiohttp.test_utils import TestServer

    async with TestServer(_make_json_app()) as server:
        base = f"http://{server.host}:{server.port}"
        entries = [_entry(f"{base}/walker/order/create", "/walker/order/create")]
        router = TopologyRouter(
            routes=[ServiceRoute(name="order_service", prefix="/walker/order", url=base)],
        )
        config = LoadTestConfig(
            url=base, vus=1, iterations=1, duration="30s", mode="microservice"
        )
        metrics = MetricsCollector()
        await run_all_vus(entries, config, metrics, topology=router)

    stats = metrics.compute_endpoint_stats()
    assert len(stats) == 1
    assert stats[0].service == "order_service"
    assert stats[0].total_requests == 1
    assert stats[0].success_count == 1


# ---------------------------------------------------------------------------
# Microservice mode: routing to different service URLs
# ---------------------------------------------------------------------------

@pytest.mark.integration
async def test_microservice_routes_to_different_service_urls():
    """Requests to /walker/order go to server1, /walker/inventory go to server2."""
    from aiohttp.test_utils import TestServer

    received_by_server1: list[str] = []
    received_by_server2: list[str] = []

    async def handler1(r: aiohttp.web.Request) -> aiohttp.web.Response:
        received_by_server1.append(r.path)
        return aiohttp.web.json_response({"ok": True})

    async def handler2(r: aiohttp.web.Request) -> aiohttp.web.Response:
        received_by_server2.append(r.path)
        return aiohttp.web.json_response({"ok": True})

    app1 = aiohttp.web.Application()
    app1.router.add_route("*", "/{path_info:.*}", handler1)
    app2 = aiohttp.web.Application()
    app2.router.add_route("*", "/{path_info:.*}", handler2)

    async with TestServer(app1) as s1, TestServer(app2) as s2:
        url1 = f"http://{s1.host}:{s1.port}"
        url2 = f"http://{s2.host}:{s2.port}"

        # HAR entries use an arbitrary recorded origin; topology routes by path
        entries = [
            _entry("http://recorded:8000/walker/order/create",     "/walker/order/create"),
            _entry("http://recorded:8000/walker/inventory/list",   "/walker/inventory/list"),
        ]
        router = TopologyRouter(routes=[
            ServiceRoute(name="order_svc",     prefix="/walker/order",     url=url1),
            ServiceRoute(name="inventory_svc", prefix="/walker/inventory", url=url2),
        ])
        config = LoadTestConfig(vus=1, iterations=1, duration="30s", mode="microservice")
        metrics = MetricsCollector()
        await run_all_vus(entries, config, metrics, topology=router)

    # Prefix stripped before forwarding: /walker/order/create → /create, etc.
    assert "/create" in received_by_server1
    assert "/list" not in received_by_server1

    assert "/list" in received_by_server2
    assert "/create" not in received_by_server2

    stats = metrics.compute_endpoint_stats()
    service_names = {s.service for s in stats}
    assert "order_svc" in service_names
    assert "inventory_svc" in service_names
