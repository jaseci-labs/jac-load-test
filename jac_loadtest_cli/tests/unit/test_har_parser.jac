"""Unit tests for core/har_parser.jac — no network, no external file I/O except temp HAR files."""

import json;
import io;
import os;
import sys;
import shutil;
import tempfile;
import from pathlib { Path }
import from jac_loadtest_cli.core.har_parser { parse_har }

glob _FIXTURES_DIR: str = str(Path(__file__).parent.parent / "fixtures");


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_har(entries: list | None = None) -> dict {
    default_entries = [
        {
            "request": {
                "method": "POST",
                "url": "http://recorded-host:8000/user/login",
                "headers": [],
                "postData": {
                    "mimeType": "application/json",
                    "text": '{"identity":{"type":"username","value":"u"},"credential":{"type":"password","password":"p"}}',
                },
                "queryString": [],
            },
            "response": {"status": 200, "content": {"mimeType": "application/json"}},
            "timings": {"send": 1, "wait": 50, "receive": 5},
        },
        {
            "request": {
                "method": "POST",
                "url": "http://recorded-host:8000/walker/search",
                "headers": [],
                "postData": {"mimeType": "application/json", "text": '{"query":"test"}'},
                "queryString": [],
            },
            "response": {"status": 200, "content": {"mimeType": "application/json"}},
            "timings": {"send": 1, "wait": 42, "receive": 8},
        },
    ];
    return {
        "log": {
            "version": "1.2",
            "entries": entries if entries is not None else default_entries,
        }
    };
}

def _entry(
    method: str = "POST",
    url: str = "http://recorded-host:8000/walker/search",
    headers: list | None = None,
    mime: str = "application/json",
    body: str | None = None,
    wait_s: int = 42,
    started: str | None = None,
    duration_ms: float | None = None,
) -> dict {
    e: dict = {
        "request": {
            "method": method,
            "url": url,
            "headers": headers if headers is not None else [],
            "postData": {"mimeType": mime, "text": body} if body is not None else None,
            "queryString": [],
        },
        "response": {"status": 200, "content": {"mimeType": mime}},
        "timings": {"send": 1, "wait": wait_s, "receive": 5},
    };
    if started is not None {
        e["startedDateTime"] = started;
    }
    if duration_ms is not None {
        e["time"] = duration_ms;
    }
    return e;
}

def _entry_with_resource_type(resource_type: str, url: str = "http://h:8000/endpoint") -> dict {
    e = _entry(url=url);
    e["_resourceType"] = resource_type;
    return e;
}

def _entry_missing_body(method: str = "POST", url: str = "http://h:8000/walker/create") -> dict {
    return {
        "request": {
            "method": method,
            "url": url,
            "headers": [{"name": "Content-Length", "value": "42"}],
            "postData": None,
            "queryString": [],
        },
        "response": {"status": 200, "content": {"mimeType": "application/json"}},
        "timings": {"send": 1, "wait": 10, "receive": 2},
    };
}

def _write_har(data: dict) -> str {
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False);
    json.dump(data, tmp);
    tmp.close();
    return tmp.name;
}

def _capture_stderr(fn: object) -> str {
    old = sys.stderr;
    buf = io.StringIO();
    sys.stderr = buf;
    fn();
    captured = buf.getvalue();
    sys.stderr = old;
    return captured;
}


# ---------------------------------------------------------------------------
# Basic parsing
# ---------------------------------------------------------------------------

test "parse minimal" {
    har = make_har();
    path = _write_har(har);
    entries = parse_har(path, target_url="http://target:9000");
    assert len(entries) == 2;
    assert entries[0].method == "POST";
    assert entries[0].url.startswith("http://target:9000");
    # Neither fixture entry carries startedDateTime, so real think time (the gap
    # between actions) can't be computed and falls back to 0 — timings.wait is
    # server TTFB for that request, not user pacing, so it must not leak in here.
    assert entries[0].think_time_ms == 0.0;
    assert entries[1].think_time_ms == 0.0;
}

test "mime filter default" {
    har = make_har(entries=[
        _entry(url="http://h:8000/api/data", mime="application/json"),
        _entry(url="http://h:8000/img.png",  mime="image/png"),
        _entry(url="http://h:8000/style.css", mime="text/css"),
        _entry(url="http://h:8000/font.woff2", mime="font/woff2"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://target:9000");
    assert len(entries) == 1;
    assert "/api/data" in entries[0].url;
}

test "include static flag" {
    har = make_har(entries=[
        _entry(url="http://h:8000/api",       mime="application/json"),
        _entry(url="http://h:8000/img.png",   mime="image/png"),
        _entry(url="http://h:8000/style.css", mime="text/css"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://target:9000", include_static=True);
    assert len(entries) == 3;
}

test "url rewriting origin" {
    har = make_har(entries=[_entry(url="http://recorded-host:8000/walker/search?q=hello")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://staging.app.com:9000");
    assert entries[0].url == "http://staging.app.com:9000/walker/search?q=hello";
}

test "url rewriting port" {
    har = make_har(entries=[_entry(url="http://localhost:8000/user/login")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://localhost:9999");
    assert entries[0].url.startswith("http://localhost:9999");
    assert "/user/login" in entries[0].url;
}

test "header sanitization" {
    headers = [
        {"name": "Authorization",  "value": "Bearer secret"},
        {"name": "Cookie",         "value": "session=abc"},
        {"name": "Host",           "value": "recorded-host:8000"},
        {"name": "Content-Length", "value": "42"},
        {"name": "Content-Type",   "value": "application/json"},
        {"name": "X-Custom",       "value": "keep-me"},
    ];
    har = make_har(entries=[_entry(headers=headers, body='{"key": "val"}')]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://target:9000");
    hdrs = entries[0].headers;
    assert "Authorization"  not in hdrs;
    assert "Cookie"         not in hdrs;
    assert "Host"           not in hdrs;
    assert "Content-Length" not in hdrs;
    assert hdrs.get("Content-Type") == "application/json";
    assert hdrs.get("X-Custom") == "keep-me";
}

test "login detection default" {
    har = make_har(entries=[
        _entry(url="http://h:8000/user/login"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert entries[0].is_login is True;
    assert entries[1].is_login is False;
}

test "login detection custom path" {
    har = make_har(entries=[
        _entry(url="http://h:8000/api/auth"),
        _entry(url="http://h:8000/user/login"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000", login_path="/api/auth");
    assert entries[0].is_login is True;
    assert entries[1].is_login is False;
}

test "think time extraction" {
    # A single entry has no "next" action to measure a gap against, so it
    # keeps think_time_ms == 0.0 regardless of the recorded server wait time.
    har = make_har(entries=[_entry(wait_s=123)]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert entries[0].think_time_ms == 0.0;
}

test "think time computed from real user gap between entries" {
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/search", started="2026-07-01T10:00:00.000Z", duration_ms=48.0),
        _entry(url="http://h:8000/walker/create", started="2026-07-01T10:00:05.048Z", duration_ms=48.0),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 2;
    # 5.048s gap between the two startedDateTime values, minus entry 0's own
    # 48ms duration -> ~5000ms of real user think time before entry 1 fires.
    assert abs(entries[0].think_time_ms - 5000.0) < 1.0;
    assert entries[1].think_time_ms == 0.0;
}

test "security warning emitted" {
    src = os.path.join(_FIXTURES_DIR, "minimal.har");
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False);
    tmp.close();
    shutil.copy(src, tmp.name);

    def _run() {
        parse_har(tmp.name, target_url="http://t:9000");
    }
    captured = _capture_stderr(_run);
    assert "Authorization" in captured or "Cookie" in captured or "sensitive" in captured;
}

test "security warning suppressed when no sensitive headers" {
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/search", headers=[
            {"name": "Content-Type", "value": "application/json"}
        ])
    ]);
    path = _write_har(har);

    def _run() {
        parse_har(path, target_url="http://t:9000");
    }
    captured = _capture_stderr(_run);
    assert "Warning" not in captured;
}

test "har 1.1 compat" {
    entry = {
        "request": {
            "method": "GET",
            "url": "http://h:8000/ping",
            "headers": [],
            "queryString": [],
        },
        "response": {"status": 200, "content": {"mimeType": "application/json"}},
        "timings": {"send": 1, "wait": 10, "receive": 2},
    };
    har = {"log": {"version": "1.1", "entries": [entry]}};
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    # Single entry, no "next" action -> no gap to compute, defaults to 0.0.
    assert entries[0].think_time_ms == 0.0;
}

test "entry order preserved" {
    har = make_har(entries=[
        _entry(url="http://h:8000/a"),
        _entry(url="http://h:8000/b"),
        _entry(url="http://h:8000/c"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    paths = [e.original_url for e in entries];
    assert paths == [
        "http://h:8000/a",
        "http://h:8000/b",
        "http://h:8000/c",
    ];
}

test "empty har" {
    har = {"log": {"version": "1.2", "entries": []}};
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert entries == [];
}

test "malformed har missing log" {
    har = {"not_log": {}};
    path = _write_har(har);
    raised = False;
    try {
        parse_har(path, target_url="http://t:9000");
    } except ValueError as e {
        raised = True;
        assert "log" in str(e);
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# HTTP/2 pseudo-header stripping
# ---------------------------------------------------------------------------

test "http2 pseudo headers stripped" {
    headers = [
        {"name": ":authority", "value": "example.com"},
        {"name": ":method",    "value": "POST"},
        {"name": ":path",      "value": "/walker/me"},
        {"name": ":scheme",    "value": "https"},
        {"name": "Content-Type", "value": "application/json"},
        {"name": "X-Custom",     "value": "keep-me"},
    ];
    har = make_har(entries=[_entry(headers=headers)]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    hdrs = entries[0].headers;
    assert ":authority" not in hdrs;
    assert ":method"    not in hdrs;
    assert ":path"      not in hdrs;
    assert ":scheme"    not in hdrs;
    assert hdrs.get("Content-Type") == "application/json";
    assert hdrs.get("X-Custom") == "keep-me";
}

test "non pseudo headers kept" {
    headers = [
        {"name": "Accept",       "value": "application/json"},
        {"name": "X-Request-ID", "value": "abc123"},
    ];
    har = make_har(entries=[_entry(headers=headers)]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    hdrs = entries[0].headers;
    assert hdrs.get("Accept") == "application/json";
    assert hdrs.get("X-Request-ID") == "abc123";
}


# ---------------------------------------------------------------------------
# Resource type filter
# ---------------------------------------------------------------------------

test "unsupported resource type websocket filtered" {
    har = make_har(entries=[
        _entry_with_resource_type("websocket"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "unsupported resource type eventsource filtered" {
    har = make_har(entries=[
        _entry_with_resource_type("eventsource"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "unsupported resource type document filtered" {
    har = make_har(entries=[
        _entry_with_resource_type("document"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "unsupported resource type font filtered" {
    har = make_har(entries=[
        _entry_with_resource_type("font"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "static stylesheet filtered by mime default" {
    e = _entry_with_resource_type("stylesheet", url="http://h:8000/asset.css");
    har = make_har(entries=[e, _entry(url="http://h:8000/walker/me")]);
    har["log"]["entries"][0]["response"]["content"]["mimeType"] = "text/css";
    path = _write_har(har);

    entries_default = parse_har(path, target_url="http://t:9000");
    assert len(entries_default) == 1;
    assert "/walker/me" in entries_default[0].url;

    entries_static = parse_har(path, target_url="http://t:9000", include_static=True);
    assert len(entries_static) == 2;
}

test "static script filtered by mime default" {
    e = _entry_with_resource_type("script", url="http://h:8000/asset.script");
    har = make_har(entries=[e, _entry(url="http://h:8000/walker/me")]);
    har["log"]["entries"][0]["response"]["content"]["mimeType"] = "application/javascript";
    path = _write_har(har);

    entries_default = parse_har(path, target_url="http://t:9000");
    assert len(entries_default) == 1;

    entries_static = parse_har(path, target_url="http://t:9000", include_static=True);
    assert len(entries_static) == 2;
}

test "font with octet stream mime filtered" {
    e = _entry_with_resource_type("font", url="http://h:8000/inter-latin.woff2");
    e["response"]["content"]["mimeType"] = "application/octet-stream";
    har = make_har(entries=[e, _entry(url="http://h:8000/walker/me")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "xhr resource type kept" {
    har = make_har(entries=[
        _entry_with_resource_type("xhr",   url="http://h:8000/walker/a"),
        _entry_with_resource_type("fetch", url="http://h:8000/walker/b"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 2;
}

test "websocket url scheme filtered ws" {
    har = make_har(entries=[
        _entry(url="ws://h:8000/socket"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "websocket url scheme filtered wss" {
    har = make_har(entries=[
        _entry(url="wss://h:8000/socket"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "unsupported type warning emitted once" {
    har = make_har(entries=[
        _entry_with_resource_type("websocket", url="http://h:8000/ws1"),
        _entry_with_resource_type("websocket", url="http://h:8000/ws2"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);

    def _run() {
        parse_har(path, target_url="http://t:9000");
    }
    captured = _capture_stderr(_run);
    assert captured.count("WebSocket") == 1;
}


# ---------------------------------------------------------------------------
# Cache-busting URL filter
# ---------------------------------------------------------------------------

test "cache buster 13 digit timestamp filtered" {
    har = make_har(entries=[
        _entry(url="http://h:8000/track?_=1779986528514"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/me" in entries[0].url;
}

test "cache buster 10 digit timestamp filtered" {
    har = make_har(entries=[
        _entry(url="http://h:8000/track?_=1609459200"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "cache buster cb param filtered" {
    har = make_har(entries=[
        _entry(url="http://h:8000/track?cb=1779986528514"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "cache buster mixed params filtered" {
    har = make_har(entries=[
        _entry(url="http://h:8000/track?ip=0&_=1779986528514&ver=1.3"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "non cache buster non numeric kept" {
    har = make_har(entries=[_entry(url="http://h:8000/api?_=hello")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "non cache buster short value kept" {
    har = make_har(entries=[_entry(url="http://h:8000/api?_=123")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "non cache buster page param kept" {
    har = make_har(entries=[_entry(url="http://h:8000/api?page=1609459200")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "non cache buster no query kept" {
    har = make_har(entries=[_entry(url="http://h:8000/api/data")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "cache buster warning emitted once" {
    har = make_har(entries=[
        _entry(url="http://h:8000/track?_=1779986528514"),
        _entry(url="http://h:8000/track?_=1779986530000"),
        _entry(url="http://h:8000/walker/me"),
    ]);
    path = _write_har(har);

    def _run() {
        parse_har(path, target_url="http://t:9000");
    }
    captured = _capture_stderr(_run);
    assert captured.count("cache-busting") == 1;
}


# ---------------------------------------------------------------------------
# Missing-body filter
# ---------------------------------------------------------------------------

test "missing body entry skipped" {
    har = make_har(entries=[
        _entry_missing_body(),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert "/walker/search" in entries[0].url;
}

test "missing body skipped for post" {
    har = make_har(entries=[
        _entry_missing_body(method="POST"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "missing body skipped for put" {
    har = make_har(entries=[
        _entry_missing_body(method="PUT"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "missing body skipped for patch" {
    har = make_har(entries=[
        _entry_missing_body(method="PATCH"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
}

test "get without body not skipped" {
    har = make_har(entries=[_entry(method="GET", url="http://h:8000/walker/list", body=None)]);
    har["log"]["entries"][0]["request"].pop("postData", None);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert entries[0].body is None;
    assert entries[0].body_mime is None;
}

test "post with body not skipped" {
    har = make_har(entries=[_entry(method="POST", url="http://h:8000/walker/create", body='{"name": "x"}')]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert len(entries) == 1;
    assert entries[0].body == '{"name": "x"}';
}

test "missing body warning emitted once" {
    har = make_har(entries=[
        _entry_missing_body(url="http://h:8000/walker/a"),
        _entry_missing_body(url="http://h:8000/walker/b"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);

    def _run() {
        parse_har(path, target_url="http://t:9000");
    }
    captured = _capture_stderr(_run);
    assert captured.count("postData missing") == 1;
}


# ---------------------------------------------------------------------------
# Occurrence numbering
# ---------------------------------------------------------------------------

test "occurrence single endpoint" {
    har = make_har(entries=[_entry(url="http://h:8000/walker/search")]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert entries[0].occurrence == 1;
    assert entries[0].total_occurrences == 1;
}

test "occurrence repeated endpoint" {
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"load_history"}'),
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"start"}'),
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"load_history"}'),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    pairs = [(e.occurrence, e.total_occurrences) for e in entries];
    assert pairs == [(1, 3), (2, 3), (3, 3)];
}

test "occurrence different endpoints independent" {
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/search"),
        _entry(url="http://h:8000/walker/create"),
        _entry(url="http://h:8000/walker/search"),
    ]);
    path = _write_har(har);
    entries = parse_har(path, target_url="http://t:9000");
    assert entries[0].occurrence == 1 and entries[0].total_occurrences == 2;
    assert entries[1].occurrence == 1 and entries[1].total_occurrences == 1;
    assert entries[2].occurrence == 2 and entries[2].total_occurrences == 2;
}
