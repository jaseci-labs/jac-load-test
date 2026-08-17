"""Phase 9 — raw WebSocket protocol adapter.

A new engine alongside core/engine.jac (HTTP), not a replacement for it — the
HTTP engine is untouched. A WsScenarioConfig describes one logical WebSocket
flow (connect once, send a fixed message sequence, one reply expected per
message); run_ws_scenarios() spawns `vus` independent VU coroutines per
scenario, all recording into the same MetricsCollector the HTTP engine uses,
tagged with protocol="ws" so compute_endpoint_stats() reports it as its own
row instead of blending it into HTTP latencies.

Success/failure reuses the existing status == expected_status convention from
core/metrics.jac: a message round-trip that gets a reply is recorded as
status=101 (the WS handshake status code, standing in for "ok" here) against
expected_status=101; anything else is a 0-status error sample.
"""

import asyncio;
import json as _json;
import time;
import aiohttp;
import from urllib.parse { urlparse }
import from ..config { parse_duration }
import from .metrics { RequestResult, MetricsCollector }

glob WS_EXPECTED_STATUS: int = 101;

obj WsScenarioConfig {
    has url: str;
    has messages: list[str] = [];
    has vus: int = 1;
    has iterations: int | None = 1;
    has duration: str | None = None;
    has timeout: str = "30s";
    has name: str = "";
    has think_time_ms: float = 0.0;
    has headers: dict[str, str] = {};
}

def scenario_endpoint(url: str, name: str, label: str) -> str {
    # Shared by ws_engine and graphql_engine so both label their EndpointStats
    # rows consistently: an explicit `name` wins, else fall back to the URL's
    # own path prefixed with the protocol label.
    if name {
        return name;
    }
    path = urlparse(url).path or "/";
    return f"{label} {path}";
}

def parse_ws_scenarios(raw: object | None) -> list[WsScenarioConfig] {
    if not raw {
        return [];
    }
    if isinstance(raw, str) {
        try {
            parsed = _json.loads(raw);
        } except _json.JSONDecodeError as exc {
            raise ValueError(f"ws_scenarios is not valid JSON: {exc}") from exc;
        }
    } else {
        parsed = raw;
    }
    if not isinstance(parsed, list) {
        raise ValueError("ws_scenarios must be a JSON array of scenario objects");
    }

    scenarios: list[WsScenarioConfig] = [];
    for item in parsed {
        if not isinstance(item, dict) or not item.get("url") {
            raise ValueError("each ws scenario must be an object with a 'url' field");
        }
        scenarios.append(WsScenarioConfig(
            url=str(item["url"]),
            messages=[str(m) for m in (item.get("messages") or [])],
            vus=int(item.get("vus", 1)),
            iterations=item.get("iterations", 1),
            duration=item.get("duration"),
            timeout=str(item.get("timeout", "30s")),
            name=str(item.get("name", "")),
            think_time_ms=float(item.get("think_time_ms", 0.0)),
            headers=dict(item.get("headers") or {}),
        ));
    }
    return scenarios;
}

async def _run_ws_vu(
    vu_id: int,
    scenario: WsScenarioConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
) -> None {
    endpoint = scenario_endpoint(scenario.url, scenario.name, "WS");
    timeout_s = parse_duration(scenario.timeout);
    iteration = 0;

    while not stop_requested.is_set() {
        if scenario.iterations is not None and iteration >= scenario.iterations {
            break;
        }

        try {
            async with aiohttp.ClientSession() as session {
                async with session.ws_connect(
                    scenario.url, headers=scenario.headers, timeout=timeout_s
                ) as ws {
                    for message in scenario.messages {
                        if stop_requested.is_set() {
                            break;
                        }
                        send_ts = time.time();
                        t0 = loop.time();
                        await ws.send_str(message);
                        try {
                            reply = await asyncio.wait_for(ws.receive(), timeout=timeout_s);
                        } except asyncio.TimeoutError {
                            metrics.record(RequestResult(
                                endpoint=endpoint,
                                service="monolith",
                                status=0,
                                latency_ms=timeout_s * 1000,
                                ttfb_ms=timeout_s * 1000,
                                bytes_received=0,
                                timestamp=send_ts,
                                vu_id=vu_id,
                                error_type="WS_TIMEOUT",
                                expected_status=WS_EXPECTED_STATUS,
                                protocol="ws",
                                latency_valid=False,
                            ));
                            continue;
                        }

                        latency_ms = (loop.time() - t0) * 1000;
                        ok = reply.type in (aiohttp.WSMsgType.TEXT, aiohttp.WSMsgType.BINARY);
                        reply_len = len(reply.data) if ok and reply.data else 0;
                        metrics.record(RequestResult(
                            endpoint=endpoint,
                            service="monolith",
                            status=WS_EXPECTED_STATUS if ok else 0,
                            latency_ms=latency_ms,
                            ttfb_ms=latency_ms,
                            bytes_received=reply_len,
                            timestamp=send_ts,
                            vu_id=vu_id,
                            error_type=None if ok else f"WS_UNEXPECTED_FRAME_{reply.type.name}",
                            expected_status=WS_EXPECTED_STATUS,
                            protocol="ws",
                        ));

                        if scenario.think_time_ms > 0 {
                            await asyncio.sleep(scenario.think_time_ms / 1000.0);
                        }
                    }
                }
            }
        } except (aiohttp.ClientError, OSError) {
            metrics.record(RequestResult(
                endpoint=endpoint,
                service="monolith",
                status=0,
                latency_ms=0.0,
                ttfb_ms=0.0,
                bytes_received=0,
                timestamp=time.time(),
                vu_id=vu_id,
                error_type="WS_CONNECTION_ERROR",
                expected_status=WS_EXPECTED_STATUS,
                protocol="ws",
                latency_valid=False,
            ));
        }

        iteration += 1;
    }
}

async def run_ws_scenarios(
    scenarios: list[WsScenarioConfig],
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
                asyncio.create_task(_run_ws_vu(next_vu, scenario, metrics, stop_requested, loop))
            );
            next_vu += 1;
        }
    }
    await asyncio.gather(*tasks);
}
