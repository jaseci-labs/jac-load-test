"""WebSocket and graphql-ws replay for a Locust user.

Locust has no WebSocket client of its own, so these use websocket-client (a
blocking API that gevent makes cooperative) and report every message
round-trip through Locust's request event. That puts them in the same stats,
console table, HTML report and JSON report as HTTP, as rows named
"WS /path [connect]", "WS /path" and "GraphQL /path".

Both functions take a `fire` callback instead of a user, so this module has no
dependency on users.jac:

    fire(request_type, name, elapsed_ms, length, error_or_None)
"""

import time;
import json;
import uuid;
import websocket;
import from urllib.parse { urlparse }

glob _SKIP_HEADERS: list[str] = [
    "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
    "sec-websocket-extensions", "sec-websocket-protocol", "content-length",
];

def ws_url(url: str) -> str {
    # websocket-client wants ws/wss; HAR entries that were rewritten to the
    # target may still carry http/https.
    if url.startswith("https://") {
        return "wss://" + url[len("https://"):];
    }
    if url.startswith("http://") {
        return "ws://" + url[len("http://"):];
    }
    return url;
}

def handshake_headers(recorded: dict[str, str], token: str) -> list[str] {
    out: list[str] = [];
    for (k, v) in recorded.items() {
        lk = k.lower();
        if lk in _SKIP_HEADERS or k.startswith(":") {
            continue;
        }
        if lk == "authorization" and token {
            continue;
        }
        out.append(f"{k}: {v}");
    }
    if token {
        out.append(f"Authorization: Bearer {token}");
    }
    return out;
}

def _ms(t0: float) -> float {
    return (time.perf_counter() - t0) * 1000.0;
}

def run_ws(
    fire: any, url: str, headers: list[str], messages: list[str],
    timeout_s: float, think_ms: float,
) -> None {
    path = urlparse(url).path or "/";
    t0 = time.perf_counter();
    try {
        sock = websocket.create_connection(ws_url(url), timeout=timeout_s, header=headers);
    } except Exception as ex {
        fire("WS", f"WS {path} [connect]", _ms(t0), 0, f"WS_CONNECT_FAILED: {ex}");
        return;
    }
    fire("WS", f"WS {path} [connect]", _ms(t0), 0, None);
    try {
        for msg in messages {
            t1 = time.perf_counter();
            try {
                sock.send(msg);
                reply = sock.recv();
                fire("WS", f"WS {path}", _ms(t1), len(reply), None);
            } except websocket.WebSocketTimeoutException {
                fire("WS", f"WS {path}", _ms(t1), 0, "WS_TIMEOUT");
            } except Exception as ex {
                fire("WS", f"WS {path}", _ms(t1), 0, f"WS_ERROR: {ex}");
                break;
            }
            if think_ms > 0 {
                time.sleep(think_ms / 1000.0);
            }
        }
    } finally {
        try {
            sock.close();
        } except Exception {
        }
    }
}

def run_graphql_ws(
    fire: any, url: str, headers: list[str], query: str,
    variables: dict[str, any] | None, operation_name: str | None,
    timeout_s: float, max_events: int,
) -> None {
    path = urlparse(url).path or "/";
    name = f"GraphQL {path}";
    t0 = time.perf_counter();
    try {
        sock = websocket.create_connection(
            ws_url(url), timeout=timeout_s, header=headers, subprotocols=["graphql-ws"],
        );
        sock.send(json.dumps({"type": "connection_init", "payload": {}}));
        ack = json.loads(sock.recv());
        if ack.get("type") != "connection_ack" {
            raise RuntimeError("graphql-ws connection_ack not received");
        }
    } except Exception as ex {
        fire("GRAPHQL", name, _ms(t0), 0, f"GRAPHQL_CONNECT_FAILED: {ex}");
        return;
    }
    payload: dict[str, any] = {"query": query};
    if variables {
        payload["variables"] = variables;
    }
    if operation_name {
        payload["operationName"] = operation_name;
    }
    sub_id = str(uuid.uuid4());
    sock.send(json.dumps({"id": sub_id, "type": "start", "payload": payload}));
    last = time.perf_counter();
    events = 0;
    try {
        while True {
            try {
                raw = sock.recv();
            } except websocket.WebSocketTimeoutException {
                fire("GRAPHQL", name, timeout_s * 1000.0, 0, "GRAPHQL_TIMEOUT");
                return;
            } except Exception as ex {
                fire("GRAPHQL", name, _ms(last), 0, f"GRAPHQL_ERROR: {ex}");
                return;
            }
            data = json.loads(raw);
            kind = data.get("type");
            if kind in ("data", "next") {
                body = data.get("payload") if isinstance(data.get("payload"), dict) else {};
                bad = bool(body.get("errors"));
                fire("GRAPHQL", name, _ms(last), len(raw), "GRAPHQL_ERROR: errors in payload" if bad else None);
                last = time.perf_counter();
                events += 1;
                if max_events > 0 and events >= max_events {
                    return;
                }
            } elif kind == "error" {
                fire("GRAPHQL", name, _ms(last), len(raw), "GRAPHQL_ERROR: subscription error");
                return;
            } elif kind == "complete" {
                return;
            }
        }
    } finally {
        try {
            sock.send(json.dumps({"id": sub_id, "type": "stop"}));
            sock.close();
        } except Exception {
        }
    }
}
