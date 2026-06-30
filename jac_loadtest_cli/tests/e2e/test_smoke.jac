"""End-to-end smoke tests: HAR → engine → reporter pipeline."""

import asyncio;
import json;
import os;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.har_parser { parse_har }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.metrics { MetricsCollector }
import from jac_loadtest_cli.output.reporter { render_json, render_console }

glob _FIXTURES: object = __import__("pathlib").Path(__file__).parent.parent / "fixtures";


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_app() -> aiohttp.web.Application {
    async def _login(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"data": {"token": "test-jwt-token"}});
    }
    async def _api(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"results": []});
    }
    app = aiohttp.web.Application();
    app.router.add_post("/user/login", _login);
    app.router.add_route("*", "/{path_info:.*}", _api);
    return app;
}


# ---------------------------------------------------------------------------
# HAR → engine → JSON report
# ---------------------------------------------------------------------------

test "smoke: full pipeline produces valid json report" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_app()) as server {
            base = f"http://{server.host}:{server.port}";
            har_path = str(_FIXTURES / "minimal.har");
            entries = parse_har(har_path, target_url=base, include_static=False, login_path="/user/login");
            config = LoadTestConfig(
                har_file=har_path,
                url=base,
                vus=2,
                iterations=3,
                mode="monolith",
                apdex_t=500.0,
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            result_holder[0] = (metrics, config);
        }
    }

    asyncio.run(_run());
    metrics = result_holder[0][0];
    config  = result_holder[0][1];

    assert metrics.total_count > 0;

    import time as _t;
    stats = metrics.compute_endpoint_stats(apdex_t=500.0, actual_duration_s=1.0);
    output = render_json(stats, config, actual_duration_s=1.0, total_rps=metrics.global_rps(1.0));
    doc = json.loads(output);

    assert set(doc.keys()) == {"meta", "latency_benchmarks", "endpoints", "summary", "timeseries"};
    assert doc["meta"]["vus"] == 2;
    assert doc["meta"]["apdex_t_ms"] == 500.0;
    assert len(doc["endpoints"]) >= 1;
    assert doc["summary"]["total_requests"] == metrics.total_count;
    assert "apdex" in doc["summary"];
    assert "p999_ms" in doc["summary"];
    assert "total_bytes_received" in doc["summary"];
}


# ---------------------------------------------------------------------------
# Apdex calculation
# ---------------------------------------------------------------------------

test "smoke: apdex is 1.0 when all requests satisfy threshold" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_app()) as server {
            base = f"http://{server.host}:{server.port}";
            har_path = str(_FIXTURES / "minimal.har");
            entries = parse_har(har_path, target_url=base, include_static=False, login_path="/user/login");
            config = LoadTestConfig(
                har_file=har_path, url=base, vus=1, iterations=2, mode="monolith",
                apdex_t=30000.0,
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            result_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = result_holder[0];
    stats = m.compute_endpoint_stats(apdex_t=30000.0, actual_duration_s=1.0);
    for s in stats {
        assert s.apdex == 1.0;
    }
}


# ---------------------------------------------------------------------------
# Per-endpoint RPS is populated when actual_duration_s is given
# ---------------------------------------------------------------------------

test "smoke: per-endpoint rps populated when duration provided" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_app()) as server {
            base = f"http://{server.host}:{server.port}";
            har_path = str(_FIXTURES / "minimal.har");
            entries = parse_har(har_path, target_url=base, include_static=False, login_path="/user/login");
            config = LoadTestConfig(
                har_file=har_path, url=base, vus=1, iterations=4, mode="monolith",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            result_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    m = result_holder[0];
    stats = m.compute_endpoint_stats(actual_duration_s=2.0);
    for s in stats {
        assert s.rps > 0;
    }
}


# ---------------------------------------------------------------------------
# render_console does not raise with new fields
# ---------------------------------------------------------------------------

test "smoke: render_console runs without error after full pipeline" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_app()) as server {
            base = f"http://{server.host}:{server.port}";
            har_path = str(_FIXTURES / "minimal.har");
            entries = parse_har(har_path, target_url=base, include_static=False, login_path="/user/login");
            config = LoadTestConfig(
                har_file=har_path, url=base, vus=1, iterations=2, mode="monolith",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            result_holder[0] = (metrics, config);
        }
    }

    asyncio.run(_run());
    metrics = result_holder[0][0];
    config  = result_holder[0][1];
    stats = metrics.compute_endpoint_stats(actual_duration_s=1.0);
    render_console(stats, config, actual_duration_s=1.0, total_rps=metrics.global_rps(1.0));
}


# ---------------------------------------------------------------------------
# p99.9 is >= p99 for any sample set
# ---------------------------------------------------------------------------

test "smoke: p999 >= p99 for all endpoints" {
    result_holder: list = [None];

    async def _run() {
        async with TestServer(_make_app()) as server {
            base = f"http://{server.host}:{server.port}";
            har_path = str(_FIXTURES / "minimal.har");
            entries = parse_har(har_path, target_url=base, include_static=False, login_path="/user/login");
            config = LoadTestConfig(
                har_file=har_path, url=base, vus=3, iterations=5, mode="monolith",
            );
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics);
            result_holder[0] = metrics;
        }
    }

    asyncio.run(_run());
    stats = result_holder[0].compute_endpoint_stats(actual_duration_s=1.0);
    for s in stats {
        assert s.p999_ms >= s.p99_ms;
    }
}
