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

def _message_stats(stats: list) -> list {
    # Every connection also records its handshake under a "[connect]" label, so
    # tests about message traffic select the message rows explicitly rather than
    # assuming there is exactly one endpoint.
    return [st for st in stats if not st.endpoint.endswith("[connect]")];
}

def _connect_stats(stats: list) -> list {
    return [st for st in stats if st.endpoint.endswith("[connect]")];
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
    stats = _message_stats(stats_holder[0]);
    assert len(stats) == 1;
    assert stats[0].protocol == "ws";
    assert stats[0].total_requests == 3;
    assert stats[0].success_count == 3;
    assert stats[0].error_count == 0;
    # The handshake is measured separately.
    assert _connect_stats(stats_holder[0])[0].total_requests == 1;
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
    stats = _message_stats(stats_holder[0]);
    assert stats[0].total_requests == 4;
    assert _connect_stats(stats_holder[0])[0].total_requests == 4;
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
    stats = _message_stats(stats_holder[0]);
    assert stats[0].total_requests == 6;
    # One handshake per iteration, not per message.
    assert _connect_stats(stats_holder[0])[0].total_requests == 3;
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
    assert _message_stats(stats_holder[0])[0].endpoint == "chat-flow";
    # The connect row is labelled from the same name.
    assert _connect_stats(stats_holder[0])[0].endpoint == "chat-flow [connect]";
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
    stats = _message_stats(stats);
    assert stats[0].error_breakdown == {"WS_TIMEOUT": 1};
    assert stats[0].latencies == [];  # WS_TIMEOUT carries latency_valid=False
}


# ---------------------------------------------------------------------------
# The handshake is measured, not just the messages
# ---------------------------------------------------------------------------

test "a connection with no frames still reports its connects" {
    # The common case: a Chrome HAR export drops _webSocketMessages, so there is
    # nothing to send. The connection is still opened once per VU per iteration,
    # which is real load on the target -- it has to appear in the report rather
    # than being generated invisibly.
    holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=[], vus=2, iterations=3);
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            holder[0] = {
                st.endpoint: st.total_requests for st in metrics.compute_endpoint_stats()
            };
        }
    }

    asyncio.run(_run());
    stats = holder[0];
    connect_rows = [k for k in stats if k.endswith("[connect]")];
    assert len(connect_rows) == 1;
    # 2 VUs x 3 iterations.
    assert stats[connect_rows[0]] == 6;
}

test "connect latency is kept apart from message latency" {
    # A handshake and a message round-trip measure different things; folding them
    # into one row would distort both percentiles.
    holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(
                url=url, messages=["a", "b"], vus=2, iterations=3
            );
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            holder[0] = {
                st.endpoint: st.total_requests for st in metrics.compute_endpoint_stats()
            };
        }
    }

    asyncio.run(_run());
    stats = holder[0];
    connects = [v for (k, v) in stats.items() if k.endswith("[connect]")];
    messages = [v for (k, v) in stats.items() if not k.endswith("[connect]")];
    assert connects == [6];
    # 2 VUs x 3 iterations x 2 messages.
    assert messages == [12];
}

test "every connect sample is tagged as the ws protocol" {
    holder: list = [None];

    async def _run() {
        async with TestServer(_echo_app()) as server {
            url = f"ws://{server.host}:{server.port}/ws";
            scenario = WsScenarioConfig(url=url, messages=[], vus=1, iterations=1);
            metrics = MetricsCollector();
            await run_ws_scenarios([scenario], metrics, asyncio.Event());
            holder[0] = [(r.protocol, r.error_type) for r in metrics._samples];
        }
    }

    asyncio.run(_run());
    assert holder[0] == [("ws", None)];
}
