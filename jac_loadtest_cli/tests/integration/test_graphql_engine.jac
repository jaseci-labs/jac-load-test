"""Integration tests for core/graphql_engine.jac — real in-process aiohttp server
speaking the graphql-ws subprotocol, no live jac-scale app."""

import asyncio;
import json;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.core.graphql_engine { GraphQLScenarioConfig, run_graphql_scenarios }
import from jac_loadtest_cli.core.metrics { MetricsCollector }


def _subscription_app(event_count: int = 3, emit_error: bool = False) -> aiohttp.web.Application {
    async def _handler(request: aiohttp.web.Request) -> aiohttp.web.WebSocketResponse {
        ws = aiohttp.web.WebSocketResponse(protocols=("graphql-ws",));
        await ws.prepare(request);
        async for msg in ws {
            if msg.type != aiohttp.WSMsgType.TEXT {
                continue;
            }
            data = json.loads(msg.data);
            if data.get("type") == "connection_init" {
                await ws.send_json({"type": "connection_ack"});
            } elif data.get("type") == "start" {
                sub_id = data["id"];
                if emit_error {
                    await ws.send_json({"id": sub_id, "type": "data", "payload": {"errors": [{"message": "boom"}]}});
                } else {
                    for i in range(event_count) {
                        await ws.send_json({"id": sub_id, "type": "data", "payload": {"data": {"n": i}}});
                    }
                }
                await ws.send_json({"id": sub_id, "type": "complete"});
            }
        }
        return ws;
    }
    app = aiohttp.web.Application();
    app.router.add_get("/graphql", _handler);
    return app;
}


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

test "graphql scenario records one result per event with protocol graphql" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_subscription_app(event_count=3)) as server {
            url = f"ws://{server.host}:{server.port}/graphql";
            scenario = GraphQLScenarioConfig(
                url=url, query="subscription { n }", vus=1, iterations=1
            );
            metrics = MetricsCollector();
            await run_graphql_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert len(stats) == 1;
    assert stats[0].protocol == "graphql";
    assert stats[0].total_requests == 3;
    assert stats[0].success_count == 3;
    assert stats[0].error_count == 0;
}

test "graphql scenario stops early once max_events reached" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_subscription_app(event_count=10)) as server {
            url = f"ws://{server.host}:{server.port}/graphql";
            scenario = GraphQLScenarioConfig(
                url=url, query="subscription { n }", vus=1, iterations=1, max_events=2
            );
            metrics = MetricsCollector();
            await run_graphql_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    assert stats_holder[0][0].total_requests == 2;
}

test "graphql scenario uses explicit name as endpoint label" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_subscription_app(event_count=1)) as server {
            url = f"ws://{server.host}:{server.port}/graphql";
            scenario = GraphQLScenarioConfig(
                url=url, query="subscription { n }", vus=1, iterations=1, name="live-orders"
            );
            metrics = MetricsCollector();
            await run_graphql_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    assert stats_holder[0][0].endpoint == "live-orders";
}

test "graphql scenarios with no scenarios is a no-op" {
    metrics = MetricsCollector();
    asyncio.run(run_graphql_scenarios([], metrics, asyncio.Event()));
    assert metrics.total_count == 0;
}


# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

test "graphql scenario records a graphql error payload as a failed sample" {
    stats_holder: list = [None];

    async def _run() {
        async with TestServer(_subscription_app(emit_error=True)) as server {
            url = f"ws://{server.host}:{server.port}/graphql";
            scenario = GraphQLScenarioConfig(
                url=url, query="subscription { n }", vus=1, iterations=1
            );
            metrics = MetricsCollector();
            await run_graphql_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert stats[0].total_requests == 1;
    assert stats[0].error_count == 1;
    assert stats[0].error_breakdown == {"GRAPHQL_ERROR": 1};
}

test "graphql scenario connection error recorded when server unreachable" {
    metrics = MetricsCollector();
    scenario = GraphQLScenarioConfig(
        url="ws://127.0.0.1:1/graphql", query="subscription { n }", vus=1, iterations=1
    );
    asyncio.run(run_graphql_scenarios([scenario], metrics, asyncio.Event()));
    stats = metrics.compute_endpoint_stats();
    assert stats[0].error_breakdown == {"GRAPHQL_CONNECTION_ERROR": 1};
    assert stats[0].protocol == "graphql";
}

test "graphql scenario timeout recorded when no event arrives in time" {
    async def _stalling_handler(request: aiohttp.web.Request) -> aiohttp.web.WebSocketResponse {
        ws = aiohttp.web.WebSocketResponse(protocols=("graphql-ws",));
        await ws.prepare(request);
        async for msg in ws {
            if msg.type != aiohttp.WSMsgType.TEXT {
                continue;
            }
            data = json.loads(msg.data);
            if data.get("type") == "connection_init" {
                await ws.send_json({"type": "connection_ack"});
            }
            # "start" is acknowledged with silence — no data ever follows.
        }
        return ws;
    }

    stats_holder: list = [None];

    async def _run() {
        app = aiohttp.web.Application();
        app.router.add_get("/graphql", _stalling_handler);
        async with TestServer(app) as server {
            url = f"ws://{server.host}:{server.port}/graphql";
            scenario = GraphQLScenarioConfig(
                url=url, query="subscription { n }", vus=1, iterations=1, timeout="0.2s"
            );
            metrics = MetricsCollector();
            await run_graphql_scenarios([scenario], metrics, asyncio.Event());
            stats_holder[0] = metrics.compute_endpoint_stats();
        }
    }

    asyncio.run(_run());
    stats = stats_holder[0];
    assert stats[0].error_breakdown == {"GRAPHQL_TIMEOUT": 1};
    assert stats[0].latencies == [];
}
