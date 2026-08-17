"""Integration tests for core/engine.jac — VU lifecycle against in-process aiohttp servers."""

import asyncio;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.bridge.topology { TopologyRouter, ServiceRoute }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.engine { run_all_vus, parse_assert_json }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.metrics { MetricsCollector, StatsSnapshot }


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
    assert samples[0].latency_valid == False;
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
    assert samples[0].latency_valid == False;
}


# ---------------------------------------------------------------------------
# Connection failures must not fabricate latency data
# ---------------------------------------------------------------------------
#
# CONNECTION_REFUSED/DNS_ERROR/SSL_ERROR never reach the server, so their
# latency_ms=0.0 is a placeholder, not a measurement. Mixing it into the
# percentile pool makes a dying target look fast — the more it fails, the
# better p50/p95 read. latency_valid marks these so aggregations can exclude
# them (see metrics.jac compute_endpoint_stats/generate_timeseries/snapshot_now
# and the --fail-on-p95/p99 gates in cli.jac and engine.jac's abort watcher).

test "connection refused latency excluded from endpoint stats percentiles" {
    import socket as _socket;
    _s = _socket.socket();
    _s.bind(("127.0.0.1", 0));
    _free_port = _s.getsockname()[1];
    _s.close();

    stats_holder: list = [None];

    async def _run() {
        dead_url = f"http://127.0.0.1:{_free_port}";
        async with TestServer(_make_json_app()) as server {
            live_url = f"http://{server.host}:{server.port}";
            entries = [
                _entry(f"{dead_url}/api", "/api"),
                _entry(f"{live_url}/api", "/api"),
            ];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=live_url);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert len(stats) == 1;
    ep = stats[0];
    # 1 real request succeeded, 1 connection-refused failure — the fabricated
    # 0ms latency must not pull p50/min down to 0.
    assert ep.total_requests == 2;
    assert ep.error_count == 1;
    assert ep.min_ms > 0.0;
    assert ep.p50_ms > 0.0;
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

test "trace id captured from response traceparent header" {
    metrics_holder: list = [None];

    async def _run() {
        async def _traced(r: aiohttp.web.Request) -> aiohttp.web.Response {
            resp = aiohttp.web.json_response({"ok": True});
            resp.headers["traceparent"] = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
            return resp;
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _traced);
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
    assert samples[0].trace_id == "4bf92f3577b34da6a3ce929d0e0e4736";
}

test "trace id is none when response carries no known trace header" {
    metrics_holder: list = [None];

    async def _run() {
        app = _make_json_app();
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
    assert samples[0].trace_id is None;
}

test "stream_metrics_callback invoked periodically with cumulative StatsSnapshot" {
    snapshots_holder: list = [[]];

    async def _run() {
        async def _ok(r: aiohttp.web.Request) -> aiohttp.web.Response {
            await asyncio.sleep(0.02);
            return aiohttp.web.json_response({"ok": True});
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _ok);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=20, mode="monolith", url=base);
            metrics = MetricsCollector();

            def _on_snapshot(snap: StatsSnapshot) {
                snapshots_holder[0].append(snap);
            }

            await run_all_vus(
                entries, config, metrics,
                stream_metrics_callback=_on_snapshot,
                stream_interval=0.05,
            );
        }
    }

    asyncio.run(_run());
    snaps = snapshots_holder[0];
    assert len(snaps) >= 1;
    for snap in snaps {
        assert isinstance(snap, StatsSnapshot);
    }
    for i in range(1, len(snaps)) {
        assert snaps[i].total_requests >= snaps[i - 1].total_requests;
    }
}

test "stream_metrics_callback none is a no-op" {
    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, stream_metrics_callback=None);
        }
    }
    asyncio.run(_run());
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


# ---------------------------------------------------------------------------
# H1 — open-loop (fixed-arrival-rate) mode
# ---------------------------------------------------------------------------

test "open loop requires a positive rps" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, open_loop=True);
            metrics = MetricsCollector();
            try {
                await run_all_vus(entries, config, metrics);
            } except ValueError as exc {
                result_holder[0] = str(exc);
            }
        }
    }

    asyncio.run(_run());
    assert result_holder[0] is not None;
    assert "rps" in result_holder[0];
}

test "open loop total arrivals equal vus times iterations" {
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
            config = LoadTestConfig(
                vus=3, iterations=4, mode="monolith", url=base, open_loop=True, rps=50,
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
        }
    }

    asyncio.run(_run());
    assert count_holder[0] == 12;
}

test "open loop round robins vu id across arrivals" {
    vu_ids_holder: list = [[]];

    async def _run() {
        app = _make_json_app();
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=3, iterations=2, mode="monolith", url=base, open_loop=True, rps=50,
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            vu_ids_holder[0] = [r.vu_id for r in metrics._samples];
        }
    }

    asyncio.run(_run());
    seen = set(vu_ids_holder[0]);
    assert seen == {0, 1, 2};
    assert len(vu_ids_holder[0]) == 6;
}

test "open loop does not gate new arrivals on slow responses" {
    # vus=1, rps=10 → arrivals spaced 0.1s apart; server takes 0.3s per response.
    # Closed-loop would serialize (sleep + await response each iteration ≈ 0.4s ×
    # 5 ≈ 2.0s). Open-loop keeps launching on schedule regardless, so the run
    # should finish close to (last arrival at 0.4s) + (0.3s to answer) ≈ 0.7s —
    # nowhere near the ~2.0s closed-loop would take for the same config.
    import time as _time;
    elapsed_holder: list = [0.0];
    count_holder: list = [0];

    async def _run() {
        async def _slow(r: aiohttp.web.Request) -> aiohttp.web.Response {
            count_holder[0] += 1;
            await asyncio.sleep(0.3);
            return aiohttp.web.json_response({"ok": True});
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _slow);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=5, mode="monolith", url=base, open_loop=True, rps=10,
            );
            metrics = MetricsCollector();
            t0 = _time.monotonic();
            await run_all_vus(entries, config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert count_holder[0] == 5;
    assert elapsed_holder[0] < 1.2;
}

test "open loop honors think_time between requests within an arrival" {
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
            # A single arrival replays [entry, entry] with 200ms think_time between
            # them; think_time is intra-session and must still apply in open-loop.
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                open_loop=True, rps=1000, think_time="real",
            );
            metrics = MetricsCollector();
            import time as _time;
            t0 = _time.monotonic();
            await run_all_vus([entry, entry], config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert elapsed_holder[0] >= 0.18;
}


# ---------------------------------------------------------------------------
# H3 — step-load (ramp-to-failure) mode
# ---------------------------------------------------------------------------

test "step load requires a positive step_vus" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                step_load=True, step_vus=0, step_max_vus=5,
            );
            metrics = MetricsCollector();
            try {
                await run_all_vus(entries, config, metrics);
            } except ValueError as exc {
                result_holder[0] = str(exc);
            }
        }
    }

    asyncio.run(_run());
    assert result_holder[0] is not None;
    assert "step_vus" in result_holder[0];
}

test "step load and open loop cannot both be enabled" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                step_load=True, step_vus=1, open_loop=True, rps=10,
            );
            metrics = MetricsCollector();
            try {
                await run_all_vus(entries, config, metrics);
            } except ValueError as exc {
                result_holder[0] = str(exc);
            }
        }
    }

    asyncio.run(_run());
    assert result_holder[0] is not None;
}

test "step load ramps vus up to step_max_vus and holds when nothing breaches" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                # iterations left effectively unbounded so VUs never finish on
                # their own — the ramp is driven purely by step ticks, then
                # stopped externally once the ceiling has clearly been reached.
                vus=1, iterations=100_000, mode="monolith", url=base,
                step_load=True, step_vus=1, step_duration="0.1s", step_max_vus=3,
            );
            metrics = MetricsCollector();
            stop_requested = asyncio.Event();
            run_task = asyncio.create_task(
                run_all_vus(entries, config, metrics, stop_requested=stop_requested)
            );
            for _ in range(100) {
                if len(metrics.step_results) >= 5 {
                    break;
                }
                await asyncio.sleep(0.05);
            }
            stop_requested.set();
            await asyncio.wait_for(run_task, timeout=5.0);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert len(m.step_results) >= 3;
    step_vus_seen = [s.vus for s in m.step_results];
    assert step_vus_seen[0] == 1;
    assert max(step_vus_seen) == 3;
    # Once the ceiling is reached, later steps hold at it rather than exceeding it.
    assert all(v <= 3 for v in step_vus_seen);
    assert all(not s.breached for s in m.step_results);
}

test "step load stops ramp and run once a step breaches its error threshold" {
    metrics_holder: list = [None];
    elapsed_holder: list = [0.0];

    async def _run() {
        request_counter: list = [0];
        # A fixed, monotonically-counted failure point: the first FAIL_AFTER
        # requests succeed, every request after that fails. This makes the
        # breach depend only on cumulative request COUNT (deterministic),
        # never on request concurrency timing (which would be flaky).
        FAIL_AFTER = 4;

        async def _flaky(r: aiohttp.web.Request) -> aiohttp.web.Response {
            request_counter[0] += 1;
            await asyncio.sleep(0.15);
            if request_counter[0] > FAIL_AFTER {
                return aiohttp.web.Response(status=500);
            }
            return aiohttp.web.json_response({"ok": True});
        }

        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _flaky);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=10_000, mode="monolith", url=base,
                step_load=True, step_vus=1, step_duration="0.4s", step_max_vus=5,
                fail_on_error_rate=20.0,
            );
            metrics = MetricsCollector();
            import time as _time;
            t0 = _time.monotonic();
            await asyncio.wait_for(run_all_vus(entries, config, metrics), timeout=10.0);
            elapsed_holder[0] = _time.monotonic() - t0;
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert len(m.step_results) >= 2;
    # The breach stops the ramp immediately — the LAST recorded step is the
    # only breached one, everything before it passed.
    assert m.step_results[-1].breached is True;
    assert all(not s.breached for s in m.step_results[:-1]);
    assert m.step_results[-1].vus > m.step_results[0].vus;
    # The run itself stops shortly after the breach, not after exhausting
    # iterations=10_000 — proves stop_requested actually propagated.
    assert elapsed_holder[0] < 5.0;
}


# ---------------------------------------------------------------------------
# H2 — --duration hard wall-clock cutoff
# ---------------------------------------------------------------------------

test "duration cutoff stops closed-loop run before iterations exhaust" {
    import time as _time;
    elapsed_holder: list = [0.0];
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
            # iterations=None (unbounded) — only the duration watcher should stop this.
            config = LoadTestConfig(
                vus=2, iterations=None, mode="monolith", url=base, duration="0.3s",
            );
            metrics = MetricsCollector();
            t0 = _time.monotonic();
            await run_all_vus(entries, config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert elapsed_holder[0] >= 0.3;
    assert elapsed_holder[0] < 2.0;
    assert count_holder[0] > 1;
}

test "duration cutoff stops open-loop run before iterations exhaust" {
    import time as _time;
    elapsed_holder: list = [0.0];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=2, iterations=None, mode="monolith", url=base,
                open_loop=True, rps=50, duration="0.3s",
            );
            metrics = MetricsCollector();
            t0 = _time.monotonic();
            await run_all_vus(entries, config, metrics);
            elapsed_holder[0] = _time.monotonic() - t0;
        }
    }

    asyncio.run(_run());
    assert elapsed_holder[0] >= 0.3;
    assert elapsed_holder[0] < 2.0;
}

test "duration and step load cannot both be enabled" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_json_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                step_load=True, step_vus=1, duration="30s",
            );
            metrics = MetricsCollector();
            try {
                await run_all_vus(entries, config, metrics);
            } except ValueError as exc {
                result_holder[0] = str(exc);
            }
        }
    }

    asyncio.run(_run());
    assert result_holder[0] is not None;
}


# ---------------------------------------------------------------------------
# H8 — parse_assert_json (pure parsing, no network)
# ---------------------------------------------------------------------------

test "parse_assert_json returns empty list for none or empty list" {
    assert parse_assert_json(None) == [];
    assert parse_assert_json([]) == [];
}

test "parse_assert_json parses a boolean value as json" {
    assert parse_assert_json(["ok=true"]) == [("ok", True)];
}

test "parse_assert_json parses a bare string as a literal when not valid json" {
    assert parse_assert_json(["status=ok"]) == [("status", "ok")];
}

test "parse_assert_json parses a number and null" {
    assert parse_assert_json(["count=3", "error=null"]) == [("count", 3), ("error", None)];
}

test "parse_assert_json rejects an expression without an equals sign" {
    raised = False;
    try {
        parse_assert_json(["ok"]);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_assert_json rejects an expression with an empty path" {
    raised = False;
    try {
        parse_assert_json(["=true"]);
    } except ValueError {
        raised = True;
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# H8 — --assert-json against real HTTP responses
# ---------------------------------------------------------------------------

def _json_app(payload: object, content_type: str = "application/json") -> aiohttp.web.Application {
    async def _handler(r: aiohttp.web.Request) -> aiohttp.web.Response {
        import json as _json;
        body = payload if isinstance(payload, (bytes, str)) else _json.dumps(payload);
        return aiohttp.web.Response(text=body if isinstance(body, str) else body.decode(), content_type=content_type);
    }
    app = aiohttp.web.Application();
    app.router.add_route("*", "/{path_info:.*}", _handler);
    return app;
}

test "assert_json passes a matching field and stays a success" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"ok": True})) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 0;
    assert list(m._samples)[0].error_type is None;
}

test "assert_json fails a request whose field does not match" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"ok": False})) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    result = list(m._samples)[0];
    assert result.status == 200;
    assert result.error_type is not None;
    assert "ASSERTION_FAILED" in result.error_type;
    assert "ok" in result.error_type;
}

test "assert_json fails a request whose field is missing entirely" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"other": 1})) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    assert "missing" in list(m._samples)[0].error_type;
}

test "assert_json fails a request whose body is not valid json" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app("not json at all", content_type="text/plain")) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    assert "not valid JSON" in list(m._samples)[0].error_type;
}

test "assert_json supports a nested dotted path and list index" {
    metrics_holder: list = [None];

    async def _run() {
        payload = {"reports": [{"ctx": {"success": True}}]};
        async with TestServer(_json_app(payload)) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                assert_json=["reports.0.ctx.success=true"],
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 0;
}

test "assert_json is not evaluated when the status code already mismatched" {
    metrics_holder: list = [None];

    async def _run() {
        async def _err(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.json_response({"ok": False}, status=500);
        }
        app = aiohttp.web.Application();
        app.router.add_route("*", "/{path_info:.*}", _err);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    result = list(m._samples)[0];
    # Error comes from the status mismatch, not a redundant assertion failure.
    assert result.error_type is None;
    assert result.status == 500;
    stats = m.compute_endpoint_stats();
    assert any("expected 200 got 500" in key for key in stats[0].error_breakdown);
}

test "assert_json all listed assertions must pass" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"ok": True, "count": 0})) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(
                vus=1, iterations=1, mode="monolith", url=base,
                assert_json=["ok=true", "count=5"],
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 1;
    assert "count" in list(m._samples)[0].error_type;
}

test "assert_json without the flag leaves an application-level failure counted as success" {
    # Reproduces the H8 problem directly: a 200 carrying {"ok": false} counts
    # as success when assert_json is not configured at all.
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"ok": False})) as server {
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
    assert m.error_count == 0;
}

test "assert_json failures for the same assertion collapse into one error_breakdown bucket" {
    metrics_holder: list = [None];

    async def _run() {
        async with TestServer(_json_app({"ok": False})) as server {
            base = f"http://{server.host}:{server.port}";
            entries = [_entry(f"{base}/api", "/api")];
            config = LoadTestConfig(vus=1, iterations=5, mode="monolith", url=base, assert_json=["ok=true"]);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            metrics_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = metrics_holder[0];
    assert m.error_count == 5;
    stats = m.compute_endpoint_stats();
    assert len(stats[0].error_breakdown) == 1;
    assert list(stats[0].error_breakdown.values())[0] == 5;
}
