"""Integration tests for core/engine.jac — VU lifecycle against in-process aiohttp servers."""

import asyncio;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.bridge.topology { TopologyRouter, ServiceRoute }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.metrics { MetricsCollector }


def _make_json_app() -> aiohttp.web.Application {
    async def _ok(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"ok": True});
    }
    app = aiohttp.web.Application();
    app.router.add_route("*", "/{path_info:.*}", _ok);
    return app;
}

def _entry(url: str, path: str) -> HarEntry {
    return HarEntry(
        method="POST",
        url=url,
        headers={},
        body=None,
        body_mime=None,
        think_time_ms=0.0,
        is_login=False,
        original_url=path,
    );
}


# ---------------------------------------------------------------------------
# Microservice mode: service label in metrics
# ---------------------------------------------------------------------------

test "microservice service label in metrics" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/walker/order/create", "/walker/order/create")];
            router = TopologyRouter(
                _routes=[ServiceRoute(name="order_service", prefix="/walker/order", url=base)],
            );
            config = LoadTestConfig(
                url=base, vus=1, iterations=1, duration="30s", mode="microservice"
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, topology=router);
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert len(stats) == 1;
    assert stats[0].service == "order_service";
    assert stats[0].total_requests == 1;
    assert stats[0].success_count == 1;
}


# ---------------------------------------------------------------------------
# Microservice mode: routing to different service URLs
# ---------------------------------------------------------------------------

test "microservice routes to different service urls" {
    received_by_server1: list = [];
    received_by_server2: list = [];

    async def _handler1(r: aiohttp.web.Request) -> aiohttp.web.Response {
        received_by_server1.append(r.path);
        return aiohttp.web.json_response({"ok": True});
    }

    async def _handler2(r: aiohttp.web.Request) -> aiohttp.web.Response {
        received_by_server2.append(r.path);
        return aiohttp.web.json_response({"ok": True});
    }

    async def _run() {
        app1 = aiohttp.web.Application();
        app1.router.add_route("*", "/{path_info:.*}", _handler1);
        app2 = aiohttp.web.Application();
        app2.router.add_route("*", "/{path_info:.*}", _handler2);

        async with TestServer(app1) as s1 {
            async with TestServer(app2) as s2 {
                url1 = f"http://{s1.host}:{s1.port}";
                url2 = f"http://{s2.host}:{s2.port}";

                entries = [
                    _entry("http://recorded:8000/walker/order/create",   "/walker/order/create"),
                    _entry("http://recorded:8000/walker/inventory/list", "/walker/inventory/list"),
                ];
                router = TopologyRouter(_routes=[
                    ServiceRoute(name="order_svc",     prefix="/walker/order",     url=url1),
                    ServiceRoute(name="inventory_svc", prefix="/walker/inventory", url=url2),
                ]);
                config = LoadTestConfig(vus=1, iterations=1, duration="30s", mode="microservice");
                metrics = MetricsCollector();
                await run_all_vus(entries, config, metrics, topology=router);
            }
        }
    }

    asyncio.run(_run());

    assert "/create" in received_by_server1;
    assert "/list"   not in received_by_server1;

    assert "/list"   in received_by_server2;
    assert "/create" not in received_by_server2;

    # Verify service names appear in stats (collected from closures above)
    # We trust the routing assertions above as the primary check.
}
