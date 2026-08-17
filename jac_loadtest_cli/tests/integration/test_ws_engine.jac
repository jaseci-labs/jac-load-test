"""Integration tests for core/ws_engine.jac — real in-process aiohttp WS server, no live jac-scale app."""

import asyncio;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.core.ws_engine { WsScenarioConfig, run_ws_scenarios }
import from jac_loadtest_cli.core.metrics { MetricsCollector }


async def _echo_handler(request: aiohttp.web.Request) -> aiohttp.web.WebSocketResponse {
    ws = aiohttp.web.WebSocketResponse();
    await ws.prepare(request);
    async for msg in ws {
        if msg.type == aiohttp.WSMsgType.TEXT {
            await ws.send_str(f"echo:{msg.data}");
        }
    }
    return ws;
}

def _echo_app() -> aiohttp.web.Application {
    app = aiohttp.web.Application();
    app.router.add_get("/ws", _echo_handler);
    return app;
}


# ---------------------------------------------------------------------------
# Happy path — message sequence round-trips and is recorded
# ---------------------------------------------------------------------------

test "ws scenario records one result per message with protocol ws" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=["a", "b", "c"], vus=1, iterations=1);
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert len(stats) == 1;
    assert stats[0].protocol == "ws";
    assert stats[0].total_requests == 3;
    assert stats[0].success_count == 3;
    assert stats[0].error_count == 0;
}

test "ws scenario multiple vus multiply total requests" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=["ping"], vus=4, iterations=1);
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert stats[0].total_requests == 4;
}

test "ws scenario iterations replays the full message sequence" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=["a", "b"], vus=1, iterations=3);
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert stats[0].total_requests == 6;
}

test "ws scenario uses explicit name as endpoint label" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=["a"], vus=1, iterations=1, name="chat-flow");
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    assert stats_holder[0][0].endpoint == "chat-flow";
}

test "ws scenarios with no scenarios is a no-op" {
    metrics = MetricsCollector();
    asyncio.run(run_ws_scenarios([], metrics, asyncio.Event()));
    assert metrics.total_count == 0;
}


# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

test "ws scenario connection error recorded when server unreachable" {
    metrics = MetricsCollector();
    scenario = WsScenarioConfig(url="ws://127.0.0.1:1/ws", messages=["a"], vus=1, iterations=1);
    asyncio.run(run_ws_scenarios([scenario], metrics, asyncio.Event()));
    stats = metrics.compute_endpoint_stats();
    assert stats[0].error_count == 1;
    assert stats[0].error_breakdown == {"WS_CONNECTION_ERROR": 1};
    assert stats[0].protocol == "ws";
}

test "ws scenario timeout recorded when server never replies" {
    async def _silent_handler(request: aiohttp.web.Request) -> aiohttp.web.WebSocketResponse {
        ws = aiohttp.web.WebSocketResponse();
        await ws.prepare(request);
        async for _msg in ws {

        }
        return ws;
    }

    stats_holder: list = [None];

    async def _run() {
        app = aiohttp.web.Application();
        app.router.add_get("/ws", _silent_handler);
        async with TestServer(app) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(
                url=url, messages=["a"], vus=1, iterations=1, timeout="0.2s"
            );
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert stats[0].error_breakdown == {"WS_TIMEOUT": 1};
    assert stats[0].latencies == [];  # WS_TIMEOUT carries latency_valid=False
}
