"""Phase 9 — GraphQL subscription protocol adapter.

Wraps the same aiohttp WebSocket primitive core/ws_engine.jac uses
(`ClientSession.ws_connect`), layering the `graphql-ws` subprotocol handshake
on top: connection_init -> connection_ack, then a subscribe ("start")
message, then a stream of data/next events until the server completes the
subscription, --max-events is reached, or the run is stopped.

Each delivered event is recorded as its own RequestResult with
protocol="graphql", latency_ms measured from the previous event (or from the
subscribe call, for the first one) — so the first sample's latency is
naturally the time-to-first-event, and the endpoint's aggregate `rps` in the
report is the subscription's events/second.
"""

import asyncio;
import json;
import time;
import uuid;
import aiohttp;
import from ..config { parse_duration }
import from .metrics { RequestResult, MetricsCollector }
import from .ws_engine { scenario_endpoint }
import from .har_parser { HarEntry }

glob _GRAPHQL_WS_SUBPROTOCOL: str = "graphql-ws";

obj GraphQLScenarioConfig {
    has url: str;
    has query: str;
    has variables: dict | None = None;
    has operation_name: str | None = None;
    has vus: int = 1;
    has iterations: int | None = 1;
    has duration: str | None = None;
    has timeout: str = "30s";
    has name: str = "";
    # 0 = keep the subscription open until the server completes it, the
    # per-op timeout elapses with no new event, or the run stops.
    has max_events: int = 0;
    has headers: dict[str, str] = {};
}

def parse_graphql_scenarios(raw: object | None) -> list[GraphQLScenarioConfig] {
    if not raw {
        return [];
    }
    if isinstance(raw, str) {
        try {
            parsed = json.loads(raw);
        } except json.JSONDecodeError as exc {
            raise ValueError(f"graphql_scenarios is not valid JSON: {exc}") from exc;
        }
    } else {
        parsed = raw;
    }
    if not isinstance(parsed, list) {
        raise ValueError("graphql_scenarios must be a JSON array of scenario objects");
    }

    scenarios: list[GraphQLScenarioConfig] = [];
    for item in parsed {
        if not isinstance(item, dict) or not item.get("url") or not item.get("query") {
            raise ValueError(
                "each graphql scenario must be an object with 'url' and 'query' fields"
            );
        }
        scenarios.append(GraphQLScenarioConfig(
            url=str(item["url"]),
            query=str(item["query"]),
            variables=dict(item["variables"]) if item.get("variables") else None,
            operation_name=item.get("operation_name"),
            vus=int(item.get("vus", 1)),
            iterations=item.get("iterations", 1),
            duration=item.get("duration"),
            timeout=str(item.get("timeout", "30s")),
            name=str(item.get("name", "")),
            max_events=int(item.get("max_events", 0)),
            headers=dict(item.get("headers") or {}),
        ));
    }
    return scenarios;
}

def _subscribe_payload(scenario: GraphQLScenarioConfig) -> dict {
    payload: dict[str, object] = {"query": scenario.query};
    if scenario.variables {
        payload["variables"] = scenario.variables;
    }
    if scenario.operation_name {
        payload["operationName"] = scenario.operation_name;
    }
    return payload;
}

async def _run_one_subscription(
    ws: aiohttp.ClientWebSocketResponse,
    scenario: GraphQLScenarioConfig,
    endpoint: str,
    vu_id: int,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
    timeout_s: float,
) -> None {
    await ws.send_json({"type": "connection_init", "payload": {}});
    ack = await asyncio.wait_for(ws.receive(), timeout=timeout_s);
    if ack.type != aiohttp.WSMsgType.TEXT or json.loads(ack.data).get("type") != "connection_ack" {
        raise RuntimeError("graphql-ws connection_ack not received");
    }

    sub_id = str(uuid.uuid4());
    t0 = loop.time();
    await ws.send_json({"id": sub_id, "type": "start", "payload": _subscribe_payload(scenario)});

    last_event_t = t0;
    events = 0;
    try {
        while not stop_requested.is_set() {
            try {
                msg = await asyncio.wait_for(ws.receive(), timeout=timeout_s);
            } except asyncio.TimeoutError {
                metrics.record(RequestResult(
                    endpoint=endpoint,
                    service="monolith",
                    status=0,
                    latency_ms=timeout_s * 1000,
                    ttfb_ms=timeout_s * 1000,
                    bytes_received=0,
                    timestamp=time.time(),
                    vu_id=vu_id,
                    error_type="GRAPHQL_TIMEOUT",
                    expected_status=200,
                    protocol="graphql",
                    latency_valid=False,
                ));
                return;
            }

            if msg.type != aiohttp.WSMsgType.TEXT {
                return;
            }
            data = json.loads(msg.data);
            mtype = data.get("type");

            if mtype in ("data", "next") {
                now = loop.time();
                latency_ms = (now - last_event_t) * 1000;
                last_event_t = now;
                events += 1;
                body = data.get("payload") if isinstance(data.get("payload"), dict) else {};
                has_errors = bool(body.get("errors"));
                metrics.record(RequestResult(
                    endpoint=endpoint,
                    service="monolith",
                    status=500 if has_errors else 200,
                    latency_ms=latency_ms,
                    ttfb_ms=latency_ms,
                    bytes_received=len(msg.data),
                    timestamp=time.time(),
                    vu_id=vu_id,
                    error_type="GRAPHQL_ERROR" if has_errors else None,
                    expected_status=200,
                    protocol="graphql",
                ));
                if scenario.max_events > 0 and events >= scenario.max_events {
                    return;
                }
            } elif mtype == "error" {
                metrics.record(RequestResult(
                    endpoint=endpoint,
                    service="monolith",
                    status=500,
                    latency_ms=(loop.time() - last_event_t) * 1000,
                    ttfb_ms=(loop.time() - last_event_t) * 1000,
                    bytes_received=len(msg.data),
                    timestamp=time.time(),
                    vu_id=vu_id,
                    error_type="GRAPHQL_ERROR",
                    expected_status=200,
                    protocol="graphql",
                ));
                return;
            } elif mtype == "complete" {
                return;
            }
        }
    } finally {
        if not ws.closed {
            try {
                await ws.send_json({"id": sub_id, "type": "stop"});
            } except Exception {

            }
        }
    }
}

def scenarios_from_har_entries(
    entries: list[HarEntry], vus: int = 1, iterations: int | None = 1
) -> list[GraphQLScenarioConfig] {
    # Bridges core/har_parser.jac's protocol-tagged HarEntry list into
    # replayable scenarios: one scenario per recorded GraphQL subscription
    # (HarEntry.protocol == "graphql_ws"), using the query/variables/operation
    # name sniffed from the recorded graphql-ws "start"/"subscribe" frame.
    scenarios: list[GraphQLScenarioConfig] = [];
    for entry in entries {
        if entry.protocol != "graphql_ws" or not entry.graphql_query {
            continue;
        }
        scenarios.append(GraphQLScenarioConfig(
            url=entry.url,
            query=entry.graphql_query,
            variables=entry.graphql_variables,
            operation_name=entry.graphql_operation_name,
            vus=vus,
            iterations=iterations,
            name=scenario_endpoint(entry.url, "", "GraphQL"),
        ));
    }
    return scenarios;
}

async def _run_graphql_vu(
    vu_id: int,
    scenario: GraphQLScenarioConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
) -> None {
    endpoint = scenario_endpoint(scenario.url, scenario.name, "GraphQL");
    timeout_s = parse_duration(scenario.timeout);
    iteration = 0;

    while not stop_requested.is_set() {
        if scenario.iterations is not None and iteration >= scenario.iterations {
            break;
        }

        try {
            async with aiohttp.ClientSession() as session {
                async with session.ws_connect(
                    scenario.url,
                    protocols=[_GRAPHQL_WS_SUBPROTOCOL],
                    headers=scenario.headers,
                    timeout=timeout_s,
                ) as ws {
                    await _run_one_subscription(
                        ws, scenario, endpoint, vu_id, metrics, stop_requested, loop, timeout_s
                    );
                }
            }
        } except (aiohttp.ClientError, OSError, RuntimeError, asyncio.TimeoutError) {
            metrics.record(RequestResult(
                endpoint=endpoint,
                service="monolith",
                status=0,
                latency_ms=0.0,
                ttfb_ms=0.0,
                bytes_received=0,
                timestamp=time.time(),
                vu_id=vu_id,
                error_type="GRAPHQL_CONNECTION_ERROR",
                expected_status=200,
                protocol="graphql",
                latency_valid=False,
            ));
        }

        iteration += 1;
    }
}

async def run_graphql_scenarios(
    scenarios: list[GraphQLScenarioConfig],
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    vu_id_offset: int = 0,
) -> None {
    if not scenarios {
        return;
    }
    loop = asyncio.get_event_loop();
    tasks = [];
    next_vu = vu_id_offset;
    for scenario in scenarios {
        for _i in range(scenario.vus) {
            tasks.append(
                asyncio.create_task(_run_graphql_vu(next_vu, scenario, metrics, stop_requested, loop))
            );
            next_vu += 1;
        }
    }
    await asyncio.gather(*tasks);
}
