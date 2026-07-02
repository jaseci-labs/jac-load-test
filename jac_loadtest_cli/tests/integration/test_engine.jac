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
                url=base, vus=1, iterations=1,mode="microservice"
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
                config = LoadTestConfig(vus=1, iterations=1,mode="microservice");
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


# ---------------------------------------------------------------------------
# Phase 4: iterations cap
# ---------------------------------------------------------------------------

test "iterations cap stops after exact N iterations" {
    count_holder: list = [0];

    async def _run() {
        async def _count(r: aiohttp.web.Request) -> aiohttp.web.Response {
            count_holder[0] += 1;
            return aiohttp.web.json_response({"ok": True});
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _count);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=3,mode="monolith", url=base);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
        }
    }

    asyncio.run(_run());
    assert count_holder[0] == 3;
}


# ---------------------------------------------------------------------------
# Phase 4: TIMEOUT error type
# ---------------------------------------------------------------------------

test "timeout error type recorded for slow server" {
    metrics_holder: list = [None];

    async def _run() {
        async def _slow(r: aiohttp.web.Request) -> aiohttp.web.Response {
            await asyncio.sleep(1.0);
            return aiohttp.web.json_response({"ok": True});
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _slow);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1,
                mode="monolith", url=base, timeout="0.3s",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    samples = list(m._samples);
    assert samples[0].error_type == "TIMEOUT";
}


# ---------------------------------------------------------------------------
# Phase 4: CONNECTION_REFUSED error type
# ---------------------------------------------------------------------------

test "connection refused error type recorded" {
    import socket as _socket;
    _s = _socket.socket();
    _s.bind(("127.0.0.1", 0));
    _free_port = _s.getsockname()[1];
    _s.close();

    metrics_holder: list = [None];

    async def _run() {
        dead_url = f"http://127.0.0.1:{_free_port}";
        entries = [_entry(f"{dead_url}/api", "/api")];
        config = LoadTestConfig(
            vus=1, iterations=1,
            mode="monolith", url=dead_url,
        );
        metrics = MetricsCollector();
        await run_all_vus(entries, config, metrics);
        metrics_holder[0] = metrics;
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    samples = list(m._samples);
    assert samples[0].error_type == "CONNECTION_REFUSED";
}


# ---------------------------------------------------------------------------
# Phase 4: RPS cap throttles request rate (timing)
# ---------------------------------------------------------------------------

test "rps cap slows request rate" {
    import time as _time;
    elapsed_holder: list = [0.0];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            # rps=5, vus=1 → rps_interval=0.2s; 5 iterations → sleep ≥1.0s
            config = LoadTestConfig(
                vus=1, iterations=5,
                mode="monolith", url=base, rps=5,
            );
            metrics = MetricsCollector();
            t0 = _time.monotonic();
            await run_all_vus(entries, config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert elapsed_holder[0] >= 0.8;
    assert elapsed_holder[0] < 5.0;
}


# ---------------------------------------------------------------------------
# Phase 4: think_time scaled mode applies scaling factor
# ---------------------------------------------------------------------------

test "think_time scaled applies time scaling" {
    import time as _time;
    elapsed_holder: list = [0.0];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entry = HarEntry(
                method="GET",
                url=f"{base}/api",
                headers={},
                body=None,
                body_mime=None,
                think_time_ms=200.0,
                is_login=False,
                original_url="/api",
            );
            # 200ms × 0.5 scale = 100ms per req; 3 iterations → ≥300ms total
            config = LoadTestConfig(
                vus=1, iterations=3,
                mode="monolith", url=base,
                think_time="scaled", think_time_scale=0.5,
            );
            metrics = MetricsCollector();
            t0 = _time.monotonic();
            await run_all_vus([entry], config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert elapsed_holder[0] >= 0.25;
    assert elapsed_holder[0] < 3.0;
}


# ---------------------------------------------------------------------------
# Phase 4: debug flag does not affect result count
# ---------------------------------------------------------------------------

test "debug mode does not affect request count" {
    count_holder: list = [0];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=2, iterations=2,
                mode="monolith", url=base, debug=True,
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            count_holder[0] = metrics.total_count;
        }
    }

    asyncio.run(_run());
    assert count_holder[0] == 4;  # 2 vus × 2 iterations × 1 entry
}


# ---------------------------------------------------------------------------
# Phase 4: abort_on_fail stops test early when error threshold is breached
# ---------------------------------------------------------------------------

test "abort_on_fail stops test early when error threshold breached" {
    count_holder: list = [0];

    async def _run() {
        async def _error(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.Response(status=500, text="err");
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _error);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            # rps=2 → 0.5s interval, so watcher fires after ~2-4 requests
            config = LoadTestConfig(
                vus=1,
                iterations=100,
                mode="monolith",
                url=base,
                rps=2,
                fail_on_error_rate=0.0,
                abort_on_fail=True,
                threshold_start_delay="0s",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            count_holder[0] = metrics.total_count;
        }
    }

    asyncio.run(_run());
    assert count_holder[0] > 0;
    assert count_holder[0] < 10;
}


# ---------------------------------------------------------------------------
# TTFB breakdown
# ---------------------------------------------------------------------------

test "ttfb_ms recorded separately from total latency for streaming response" {
    metrics_holder: list = [None];

    async def _run() {
        async def _slow_body(r: aiohttp.web.Request) -> aiohttp.web.StreamResponse {
            resp = aiohttp.web.StreamResponse(status=200);
            await resp.prepare(r);
            await resp.write(b"x");
            await asyncio.sleep(0.3);
            await resp.write(b"y" * 1000);
            await resp.write_eof();
            return resp;
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _slow_body);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    samples = list(m._samples);
    assert len(samples) == 1;
    result = samples[0];
    assert result.ttfb_ms > 0;
    assert result.ttfb_ms < 150;
    assert result.latency_ms >= 300;
    assert result.latency_ms - result.ttfb_ms > 150;
}

test "ttfb_ms falls back to latency_ms on timeout" {
    metrics_holder: list = [None];

    async def _run() {
        async def _slow(r: aiohttp.web.Request) -> aiohttp.web.Response {
            await asyncio.sleep(1.0);
            return aiohttp.web.json_response({"ok": True});
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _slow);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1,
                mode="monolith", url=base, timeout="0.3s",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    samples = list(m._samples);
    assert samples[0].error_type == "TIMEOUT";
    assert samples[0].ttfb_ms == samples[0].latency_ms;
}
