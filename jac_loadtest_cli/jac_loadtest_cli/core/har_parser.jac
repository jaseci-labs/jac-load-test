import json;
import re;
import sys;
import from datetime { datetime }
import from urllib.parse { parse_qs, urlparse, urlunparse }

glob _SKIP_MIME_PREFIXES: tuple[str] = (
    "image/",
    "font/",
    "text/css",
    "application/javascript",
    "text/javascript",
    "application/wasm",
);

glob _STRIP_HEADERS: set[str] = {"authorization", "cookie", "host", "content-length"};

# "websocket" used to be here and was unconditionally skipped — Phase 9 parses
# those entries instead (see _is_websocket_entry() below). SSE, full-page
# navigations, and other non-API resource types are still out of scope and
# remain skipped.
glob _SKIP_RESOURCE_TYPES: set[str] = {
    "eventsource",
    "document",
    "manifest",
    "texttrack",
    "media",
    "font",
};

glob _CACHE_BUSTER_PARAMS: set[str] = {"_", "cb", "cachebust", "cache_bust", "nocache", "bust"};
glob _TIMESTAMP_RE: re.Pattern[str] = re.compile(r"^\d{10,13}$");

obj HarEntry {
    has method: str;
    has url: str;
    has headers: dict[str, str];
    has body: str | None;
    has body_mime: str | None;
    has think_time_ms: float;
    has is_login: bool;
    has original_url: str;
    has expected_status: int = 200;
    has occurrence: int = 0;
    has total_occurrences: int = 0;
    # Phase 9 — which adapter should replay this entry: "http" (default,
    # replayed by core/engine.jac as before), "graphql" (a GraphQL
    # query/mutation sent over plain HTTP — still replayed by core/engine.jac,
    # just tagged so the report can group it separately), "ws" (a raw
    # WebSocket connection — replayed by core/ws_engine.jac), or "graphql_ws"
    # (a GraphQL subscription over WebSocket — replayed by
    # core/graphql_engine.jac). See core/ws_engine.jac / core/graphql_engine.jac
    # :scenarios_from_har_entries() for the conversion into scenario configs.
    has protocol: str = "http";
    # Ordered "send"-direction frame payloads from the HAR's _webSocketMessages
    # extension (a Chrome/Playwright-specific field; absent from a plain HAR
    # export unless the recorder captured WS frames). Only populated when
    # protocol is "ws" or "graphql_ws".
    has ws_messages: list[str] = [];
    # Populated when protocol is "graphql" or "graphql_ws": the GraphQL
    # query/mutation/subscription document and its variables/operation name,
    # sniffed from the request body (HTTP) or the graphql-ws "start"/
    # "subscribe" frame (WebSocket).
    has graphql_query: str | None = None;
    has graphql_variables: dict | None = None;
    has graphql_operation_name: str | None = None;
}

def _parse_started_ms(value: object) -> float | None {
    # HAR's startedDateTime is mandatory in 1.1/1.2 but tolerate missing/malformed
    # values (e.g. hand-built fixtures) by falling back to no real-think-time data.
    if not isinstance(value, str) or not value {
        return None;
    }
    try {
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000.0;
    } except ValueError {
        return None;
    }
}

def _origin(url: str) -> str {
    p = urlparse(url);
    return str(urlunparse((p.scheme, p.netloc, "", "", "", "")));
}

def _rewrite_url(original: str, target_url: str) -> str {
    p = urlparse(original);
    t = urlparse(target_url);
    rewritten: str = str(urlunparse((t.scheme, t.netloc, p.path, p.params, p.query, "")));
    return rewritten;
}

def _is_static(mime: str) -> bool {
    if not mime {
        return False;
    }
    mime_lower = mime.lower().split(";")[0].strip();
    return bool(any([mime_lower.startswith(str(prefix)) for prefix in _SKIP_MIME_PREFIXES]));
}

def _is_unsupported_type(raw_ent: object) -> bool {
    if not isinstance(raw_ent, dict) {
        return False;
    }
    resource_type = str(raw_ent.get("_resourceType", "")).lower();
    return resource_type in _SKIP_RESOURCE_TYPES;
}

def _is_websocket_entry(raw_ent: object) -> bool {
    if not isinstance(raw_ent, dict) {
        return False;
    }
    resource_type = str(raw_ent.get("_resourceType", "")).lower();
    if resource_type == "websocket" {
        return True;
    }
    request = raw_ent.get("request") or {};
    url = str(request.get("url", "")) if isinstance(request, dict) else "";
    return bool(url.startswith(("ws://", "wss://")));
}

def _extract_ws_send_messages(raw_ent: dict) -> list[str] {
    # Chrome DevTools' "Preserve log" export and some third-party recorders
    # (e.g. Playwright's HAR recorder) attach a non-standard _webSocketMessages
    # array per entry: [{type: "send"|"receive", time, opcode, data}, ...].
    # A plain Chrome "Export HAR" from the Network panel does NOT include this
    # field at all — only "send" frames are kept, since those are what a
    # replaying VU should send; "receive" frames were the original server's
    # replies, not something to resend.
    messages: list[str] = [];
    ws_msgs = raw_ent.get("_webSocketMessages");
    if not isinstance(ws_msgs, list) {
        return messages;
    }
    for m in ws_msgs {
        if not isinstance(m, dict) {
            continue;
        }
        if str(m.get("type", "")).lower() != "send" {
            continue;
        }
        data = m.get("data");
        if isinstance(data, str) {
            messages.append(data);
        }
    }
    return messages;
}

def _rewrite_ws_url(original: str, target_url: str) -> str {
    p = urlparse(original);
    t = urlparse(target_url);
    # Map the replacement target's http/https scheme to the matching ws/wss
    # scheme; if the target is already ws/wss (or something unexpected), keep
    # the recorded entry's own scheme rather than guessing.
    scheme_map = {"http": "ws", "https": "wss"};
    new_scheme = scheme_map.get(t.scheme, p.scheme);
    rewritten: str = str(urlunparse((new_scheme, t.netloc, p.path, p.params, p.query, "")));
    return rewritten;
}

glob _GRAPHQL_WS_START_TYPES: set[str] = {"start", "subscribe"};

def _detect_graphql_ws(ws_messages: list[str]) -> tuple | None {
    # Scan "send" frames for a graphql-ws-shaped subscribe message
    # ({"type": "start"|"subscribe", "payload": {"query": ..., ...}}) and pull
    # out the query/variables/operationName from the first one found. Returns
    # None when no frame looks like a GraphQL subscription start.
    for raw in ws_messages {
        try {
            parsed = json.loads(raw);
        } except (json.JSONDecodeError, TypeError) {
            continue;
        }
        if not isinstance(parsed, dict) {
            continue;
        }
        if str(parsed.get("type", "")).lower() not in _GRAPHQL_WS_START_TYPES {
            continue;
        }
        payload = parsed.get("payload");
        if not isinstance(payload, dict) {
            payload = parsed;
        }
        query = payload.get("query");
        # A real GraphQL document always has a "{" selection-set brace — this
        # rules out a "start"/"subscribe"-typed frame from an unrelated
        # protocol that happens to carry an unrelated "query" field.
        if isinstance(query, str) and query.strip() and "{" in query {
            variables = payload.get("variables") if isinstance(payload.get("variables"), dict) else None;
            operation_name = payload.get("operationName") if isinstance(payload.get("operationName"), str) else None;
            return (query, variables, operation_name);
        }
    }
    return None;
}

def _detect_graphql_http(body: str | None, body_mime: str | None) -> tuple | None {
    # A GraphQL query/mutation sent over plain HTTP is structurally just a
    # JSON POST body with a top-level "query" string — detected by sniffing
    # the body rather than the path, since real deployments use "/graphql",
    # "/api/graphql", "/graphql/v1", or anything else.
    if not body {
        return None;
    }
    if body_mime and "json" not in body_mime.lower() {
        return None;
    }
    try {
        parsed = json.loads(body);
    } except json.JSONDecodeError {
        return None;
    }
    if not isinstance(parsed, dict) {
        return None;
    }
    query = parsed.get("query");
    # A real GraphQL document always has a "{" selection-set brace — this
    # keeps a plain-JSON body that happens to have an unrelated top-level
    # "query" string field (e.g. a search endpoint's {"query": "search text"})
    # from being misclassified as GraphQL.
    if not isinstance(query, str) or not query.strip() or "{" not in query {
        return None;
    }
    variables = parsed.get("variables") if isinstance(parsed.get("variables"), dict) else None;
    operation_name = parsed.get("operationName") if isinstance(parsed.get("operationName"), str) else None;
    return (query, variables, operation_name);
}

def _has_missing_body(method: str, raw_headers: list[dict[str, str]], post_data: object) -> bool {
    if method.upper() not in ("POST", "PUT", "PATCH") {
        return False;
    }
    headers = raw_headers if isinstance(raw_headers, list) else [];
    content_length: str = "0";
    for h in headers {
        if h.get("name", "").lower() == "content-length" {
            content_length = str(h["value"]);
            break;
        }
    }
    try {
        has_content = bool(int(str(content_length)) > 0);
    } except ValueError {
        has_content = False;
    }
    post = post_data if isinstance(post_data, dict) else {};
    body_text = post.get("text");
    return bool(has_content and not body_text);
}

def _has_cache_buster(url: str) -> bool {
    qs = parse_qs(urlparse(url).query);
    return bool(any([
        str(item[0]).lower() in _CACHE_BUSTER_PARAMS
        and bool(item[1])
        and bool(_TIMESTAMP_RE.match(str(item[1][0])))
        for item in qs.items()
    ]));
}

def parse_har(
    har_path: str,
    target_url: str | None = None,
    include_static: bool = False,
    login_path: str = "/user/login",
) -> list[HarEntry] {
    with open(har_path, encoding="utf-8") as f {
        data = dict(json.load(f));
    }

    if "log" not in data {
        raise ValueError("Malformed HAR file: missing 'log' key");
    }

    raw_entries:list[dict] = [];
    if isinstance (data, dict) {
        log = data.get("log", {});
        if isinstance(log, dict) {
            version = log.get("version", "unknown");
            entries = log.get("entries", []);
            if isinstance(version, str) {
                _check_version(version);
            }
            if isinstance(entries, list) {
                raw_entries = entries;
            }
        }
    }

    if not raw_entries {
        return [];
    }

    _security_scan(raw_entries);

    result: list[HarEntry] = [];
    started_ms_by_entry: list[float | None] = [];
    duration_ms_by_entry: list[float] = [];
    warned_unsupported:bool = False;
    warned_cache_buster:bool = False;
    warned_missing_body:bool = False;
    warned_ws_no_frames:bool = False;

    for entry in raw_entries {
        req:dict[str, any] = dict(entry["request"]);
        resp:dict[str, any] = dict(entry.get("response", {}));
        content:dict[str, str] = dict(resp.get("content", {}));
        mime:str = str(content.get("mimeType", ""));

        if _is_unsupported_type(entry) {
            if not warned_unsupported {
                print(
                    "\n\033[33mWarning: HAR contains SSE (eventsource), full-page "
                    "navigations, or other non-API entries (document, manifest, "
                    "texttrack, media, font). These are skipped automatically.\033[0m",
                    file=sys.stderr,
                );
                warned_unsupported = True;
            }
            continue;
        }

        if _is_websocket_entry(entry) {
            ws_original_url:str = str(req["url"]);
            if target_url is not None {
                ws_rewritten_url = _rewrite_ws_url(ws_original_url, target_url);
            } else {
                ws_rewritten_url = ws_original_url;
            }
            ws_raw_headers:list[dict] = list(req.get("headers", []));
            ws_headers = _sanitize_headers(ws_raw_headers);
            ws_messages = _extract_ws_send_messages(dict(entry));
            graphql_ws_info = _detect_graphql_ws(ws_messages);
            if graphql_ws_info is not None {
                ws_protocol = "graphql_ws";
                gqw_query = graphql_ws_info[0];
                gqw_vars = graphql_ws_info[1];
                gqw_op = graphql_ws_info[2];
            } else {
                ws_protocol = "ws";
                gqw_query = None;
                gqw_vars = None;
                gqw_op = None;
            }
            if not ws_messages and not warned_ws_no_frames {
                print(
                    "\n\033[33mWarning: HAR contains a WebSocket connection to "
                    f"'{ws_original_url}' with no captured message frames "
                    "(_webSocketMessages) — it will be replayed as a bare connect "
                    "with no message sequence. Re-record with a HAR capture tool "
                    "that preserves WebSocket frames (e.g. Playwright's HAR "
                    "recorder) to replay the actual message traffic.\033[0m",
                    file=sys.stderr,
                );
                warned_ws_no_frames = True;
            }
            result.append(
                HarEntry(
                    method=str(req.get("method", "GET")).upper(),
                    url=ws_rewritten_url,
                    headers=ws_headers,
                    body=None,
                    body_mime=None,
                    think_time_ms=0.0,
                    is_login=False,
                    original_url=ws_original_url,
                    expected_status=int(resp.get("status", 101) or 101),
                    protocol=ws_protocol,
                    ws_messages=ws_messages,
                    graphql_query=gqw_query,
                    graphql_variables=gqw_vars,
                    graphql_operation_name=gqw_op,
                )
            );
            started_ms_by_entry.append(_parse_started_ms(entry.get("startedDateTime")));
            ws_entry_meta:dict[str, float | int] = dict(entry);
            duration_ms_by_entry.append(float(ws_entry_meta.get("time", 0.0)));
            continue;
        }

        original_url:str = str(req["url"]);

        if _has_cache_buster(original_url) {
            if not warned_cache_buster {
                print(
                    "\n\033[33mWarning: HAR contains URLs with cache-busting timestamp "
                    "parameters (e.g. ?_=<timestamp>). These entries are skipped — "
                    "the stale timestamp causes the server to reject the request.\033[0m",
                    file=sys.stderr,
                );
                warned_cache_buster = True;
            }
            continue;
        }

        if not include_static and _is_static(str(mime)) {
            continue;
        }

        if target_url is not None {
            rewritten_url = _rewrite_url(str(original_url), target_url);
        } else {
            rewritten_url = str(original_url);
        }

        raw_headers:list[dict] = list(req.get("headers", []));

        if _has_missing_body(str(req["method"]), raw_headers, req.get("postData")) {
            if not warned_missing_body {
                print(
                    "\n\033[33mWarning: HAR contains POST/PUT/PATCH entries where the request body "
                    "was not captured (postData missing despite non-zero Content-Length). "
                    "These entries are skipped — replaying them without a body would cause "
                    "422 errors. Re-record the HAR to capture the full request body.\033[0m",
                    file=sys.stderr,
                );
                warned_missing_body = True;
            }
            continue;
        }

        headers = _sanitize_headers(raw_headers);

        post_data:dict[str, str] = dict(req.get("postData", {}) or {});
        raw_text = post_data.get("text");
        raw_mime = post_data.get("mimeType");
        body: str | None = str(raw_text) if raw_text else None;
        body_mime: str | None = str(raw_mime) if raw_mime else None;

        is_login = urlparse(original_url).path == login_path;

        expected_status:int = int(resp.get("status", 200) or 200);

        graphql_http_info = _detect_graphql_http(body, body_mime);
        if graphql_http_info is not None {
            http_protocol = "graphql";
            gqh_query = graphql_http_info[0];
            gqh_vars = graphql_http_info[1];
            gqh_op = graphql_http_info[2];
        } else {
            http_protocol = "http";
            gqh_query = None;
            gqh_vars = None;
            gqh_op = None;
        }

        result.append(
            HarEntry(
                method=str(req["method"].upper()),
                url=rewritten_url,
                headers=headers,
                body=body,
                body_mime=body_mime,
                think_time_ms=0.0,
                is_login=is_login,
                original_url=original_url,
                expected_status=expected_status,
                protocol=http_protocol,
                graphql_query=gqh_query,
                graphql_variables=gqh_vars,
                graphql_operation_name=gqh_op,
            )
        );
        started_ms_by_entry.append(_parse_started_ms(entry.get("startedDateTime")));
        entry_meta:dict[str, float | int] = dict(entry);
        duration_ms_by_entry.append(float(entry_meta.get("time", 0.0)));
    }

    # Real think time is the client-side gap between one action finishing and the
    # next one starting — startedDateTime[i+1] minus (startedDateTime[i] + time[i])
    # — not timings.wait (that's server TTFB for that same request). The last
    # kept entry has no "next" action, so it keeps think_time_ms = 0.0.
    for i in range(len(result) - 1) {
        started_ms = started_ms_by_entry[i];
        next_started_ms = started_ms_by_entry[i + 1];
        if started_ms is None or next_started_ms is None {
            continue;
        }
        gap_ms = next_started_ms - (started_ms + duration_ms_by_entry[i]);
        result[i].think_time_ms = gap_ms if gap_ms > 0.0 else 0.0;
    }

    totals: dict[str, int] = {};
    for entry in result {
        path: str = str(urlparse(entry.url).path);
        totals[path] = totals.get(path, 0) + 1;
    }

    seen: dict[str, int] = {};
    for entry in result {
        path: str = str(urlparse(entry.url).path);
        seen[path] = seen.get(path, 0) + 1;
        entry.occurrence = int(seen[path]);
        entry.total_occurrences = int(totals[path]);
    }

    return result;
}

glob _SUPPORTED_HAR_VERSIONS: set = {"1.1", "1.2"};

def _check_version(version: str) -> None {
    if version not in _SUPPORTED_HAR_VERSIONS {
        print(
            f"\n\033[33mWarning: HAR version '{version}' is not tested with this tool "
            f"(tested: {', '.join(sorted(_SUPPORTED_HAR_VERSIONS))}).\n"
            "Parsing will continue but results may be incomplete or incorrect.\n"
            "If the output looks wrong, check for a jac-loadtest update.\033[0m",
            file=sys.stderr,
        );
    }
}

def _security_scan(entries: list[dict[str, object]]) -> None {
    for entry in entries {
        for hdr in entry.get("request", {}).get("headers", []) {
            name = hdr.get("name", "").lower();
            value = hdr.get("value", "");
            if name in ("authorization", "cookie") and value {
                print(
                    "\n\033[33mWarning: HAR file contains Authorization/Cookie headers from the "
                    "recording session.\nThese headers are stripped before replay, but "
                    "the file itself contains sensitive data.\n"
                    "Do not commit this HAR file to version control.\033[0m",
                    file=sys.stderr,
                );
                return;
            }
        }
    }
}

def _sanitize_headers(raw_headers: list[dict[str, str]]) -> dict[str, str] {
    return {
        h["name"]: h["value"]
        for h in raw_headers
        if h.get("name", "").lower() not in _STRIP_HEADERS
        and not h.get("name", "").startswith(":")
    };
}
