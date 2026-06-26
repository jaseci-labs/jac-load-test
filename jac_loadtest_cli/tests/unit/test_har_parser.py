"""Unit tests for core/har_parser.py — no network, no file I/O (except fixture HAR files)."""
from __future__ import annotations

import json
import sys
import pytest

from jac_loadtest_cli.core.har_parser import parse_har
from tests.conftest import make_har


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_har(tmp_path, data: dict) -> str:
    p = tmp_path / "test.har"
    p.write_text(json.dumps(data))
    return str(p)


def _entry(method="POST", url="http://recorded-host:8000/walker/search",
           headers=None, mime="application/json", body=None, wait=42):
    return {
        "request": {
            "method": method,
            "url": url,
            "headers": headers or [],
            "postData": {"mimeType": "application/json", "text": body or "{}"},
            "queryString": [],
        },
        "response": {"status": 200, "content": {"mimeType": mime}},
        "timings": {"send": 1, "wait": wait, "receive": 5},
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_parse_minimal(tmp_path):
    har = make_har()
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://target:9000")
    assert len(entries) == 2
    assert entries[0].method == "POST"
    assert entries[0].url.startswith("http://target:9000")
    assert entries[0].think_time_ms == 50
    assert entries[1].think_time_ms == 42


@pytest.mark.unit
def test_mime_filter_default(tmp_path):
    har = make_har(entries=[
        _entry(url="http://h:8000/api/data", mime="application/json"),
        _entry(url="http://h:8000/img.png", mime="image/png"),
        _entry(url="http://h:8000/style.css", mime="text/css"),
        _entry(url="http://h:8000/font.woff2", mime="font/woff2"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://target:9000")
    assert len(entries) == 1
    assert "/api/data" in entries[0].url


@pytest.mark.unit
def test_include_static_flag(tmp_path):
    har = make_har(entries=[
        _entry(url="http://h:8000/api", mime="application/json"),
        _entry(url="http://h:8000/img.png", mime="image/png"),
        _entry(url="http://h:8000/style.css", mime="text/css"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://target:9000", include_static=True)
    assert len(entries) == 3


@pytest.mark.unit
def test_url_rewriting_origin(tmp_path):
    har = make_har(entries=[
        _entry(url="http://recorded-host:8000/walker/search?q=hello")
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://staging.app.com:9000")
    assert entries[0].url == "http://staging.app.com:9000/walker/search?q=hello"


@pytest.mark.unit
def test_url_rewriting_port(tmp_path):
    har = make_har(entries=[
        _entry(url="http://localhost:8000/user/login")
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://localhost:9999")
    assert entries[0].url.startswith("http://localhost:9999")
    assert "/user/login" in entries[0].url


@pytest.mark.unit
def test_header_sanitization(tmp_path):
    headers = [
        {"name": "Authorization", "value": "Bearer secret"},
        {"name": "Cookie", "value": "session=abc"},
        {"name": "Host", "value": "recorded-host:8000"},
        {"name": "Content-Length", "value": "42"},
        {"name": "Content-Type", "value": "application/json"},
        {"name": "X-Custom", "value": "keep-me"},
    ]
    har = make_har(entries=[_entry(headers=headers)])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://target:9000")
    hdrs = entries[0].headers
    assert "Authorization" not in hdrs
    assert "Cookie" not in hdrs
    assert "Host" not in hdrs
    assert "Content-Length" not in hdrs
    assert hdrs.get("Content-Type") == "application/json"
    assert hdrs.get("X-Custom") == "keep-me"


@pytest.mark.unit
def test_login_detection_default(tmp_path):
    har = make_har(entries=[
        _entry(url="http://h:8000/user/login"),
        _entry(url="http://h:8000/walker/search"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert entries[0].is_login is True
    assert entries[1].is_login is False


@pytest.mark.unit
def test_login_detection_custom_path(tmp_path):
    har = make_har(entries=[
        _entry(url="http://h:8000/api/auth"),
        _entry(url="http://h:8000/user/login"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000", login_path="/api/auth")
    assert entries[0].is_login is True
    assert entries[1].is_login is False


@pytest.mark.unit
def test_think_time_extraction(tmp_path):
    har = make_har(entries=[
        _entry(wait=123),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert entries[0].think_time_ms == 123.0


@pytest.mark.unit
def test_security_warning_emitted(tmp_path, capsys):
    path = str(tmp_path / "min.har")
    import shutil, os
    fixtures = os.path.join(os.path.dirname(__file__), "../fixtures/minimal.har")
    shutil.copy(fixtures, path)
    parse_har(path, target_url="http://t:9000")
    captured = capsys.readouterr()
    assert "Authorization" in captured.err or "Cookie" in captured.err or "sensitive" in captured.err


@pytest.mark.unit
def test_security_warning_suppressed(tmp_path, capsys):
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/search", headers=[
            {"name": "Content-Type", "value": "application/json"}
        ])
    ])
    path = _write_har(tmp_path, har)
    parse_har(path, target_url="http://t:9000")
    captured = capsys.readouterr()
    assert "Warning" not in captured.err


@pytest.mark.unit
def test_har_1_1_compat(tmp_path):
    """HAR 1.1 entries have no 'ssl' timing field — must parse without error."""
    entry = {
        "request": {
            "method": "GET",
            "url": "http://h:8000/ping",
            "headers": [],
            "queryString": [],
        },
        "response": {"status": 200, "content": {"mimeType": "application/json"}},
        "timings": {"send": 1, "wait": 10, "receive": 2},  # no ssl field
    }
    har = {"log": {"version": "1.1", "entries": [entry]}}
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert entries[0].think_time_ms == 10.0


@pytest.mark.unit
def test_entry_order_preserved(tmp_path):
    har = make_har(entries=[
        _entry(url="http://h:8000/a"),
        _entry(url="http://h:8000/b"),
        _entry(url="http://h:8000/c"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    paths = [e.original_url for e in entries]
    assert paths == [
        "http://h:8000/a",
        "http://h:8000/b",
        "http://h:8000/c",
    ]


@pytest.mark.unit
def test_empty_har(tmp_path):
    har = {"log": {"version": "1.2", "entries": []}}
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert entries == []


@pytest.mark.unit
def test_malformed_har_missing_log(tmp_path):
    har = {"not_log": {}}
    path = _write_har(tmp_path, har)
    with pytest.raises(ValueError, match="log"):
        parse_har(path, target_url="http://t:9000")


# ---------------------------------------------------------------------------
# HTTP/2 pseudo-header stripping
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_http2_pseudo_headers_stripped(tmp_path):
    """Headers whose name starts with ':' must be removed (HTTP/2 pseudo-headers)."""
    headers = [
        {"name": ":authority", "value": "example.com"},
        {"name": ":method",    "value": "POST"},
        {"name": ":path",      "value": "/walker/me"},
        {"name": ":scheme",    "value": "https"},
        {"name": "Content-Type", "value": "application/json"},
        {"name": "X-Custom",     "value": "keep-me"},
    ]
    har = make_har(entries=[_entry(headers=headers)])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    hdrs = entries[0].headers
    assert ":authority" not in hdrs
    assert ":method"    not in hdrs
    assert ":path"      not in hdrs
    assert ":scheme"    not in hdrs
    assert hdrs.get("Content-Type") == "application/json"
    assert hdrs.get("X-Custom") == "keep-me"


@pytest.mark.unit
def test_non_pseudo_headers_kept(tmp_path):
    """Normal headers (no leading ':') must not be stripped by the pseudo-header rule."""
    headers = [
        {"name": "Accept",       "value": "application/json"},
        {"name": "X-Request-ID", "value": "abc123"},
    ]
    har = make_har(entries=[_entry(headers=headers)])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    hdrs = entries[0].headers
    assert hdrs.get("Accept") == "application/json"
    assert hdrs.get("X-Request-ID") == "abc123"


# ---------------------------------------------------------------------------
# Resource type filter
# ---------------------------------------------------------------------------

def _entry_with_resource_type(resource_type: str, url="http://h:8000/endpoint"):
    entry = _entry(url=url)
    entry["_resourceType"] = resource_type
    return entry


@pytest.mark.unit
@pytest.mark.parametrize("resource_type", [
    "websocket", "eventsource", "document",
    "manifest", "texttrack", "media",
    "font",  # Chrome records fonts with _resourceType='font'; MIME is often application/octet-stream
])
def test_unsupported_resource_types_filtered(tmp_path, resource_type):
    """Entries with unsupported _resourceType must be skipped."""
    har = make_har(entries=[
        _entry_with_resource_type(resource_type),
        _entry(url="http://h:8000/walker/me"),  # should survive
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert "/walker/me" in entries[0].url


@pytest.mark.unit
@pytest.mark.parametrize("resource_type,mime", [
    ("stylesheet", "text/css"),
    ("script",     "application/javascript"),
])
def test_static_resource_types_filtered_by_mime(tmp_path, resource_type, mime):
    """stylesheet/script entries are filtered via MIME (not _resourceType) so --include-static can override."""
    har = make_har(entries=[
        _entry_with_resource_type(resource_type, url=f"http://h:8000/asset.{resource_type}"),
        _entry(url="http://h:8000/walker/me"),
    ])
    # Override the response MIME to match the resource type
    har["log"]["entries"][0]["response"]["content"]["mimeType"] = mime
    path = _write_har(tmp_path, har)

    entries_default = parse_har(path, target_url="http://t:9000")
    assert len(entries_default) == 1, "MIME filter should drop static asset by default"
    assert "/walker/me" in entries_default[0].url

    entries_static = parse_har(path, target_url="http://t:9000", include_static=True)
    assert len(entries_static) == 2, "--include-static should keep stylesheet/script entries"


@pytest.mark.unit
def test_font_with_octet_stream_mime_filtered(tmp_path):
    """Font files recorded by Chrome have _resourceType='font' but MIME application/octet-stream.
    They must be filtered even though MIME alone would not catch them."""
    entry = _entry_with_resource_type("font", url="http://h:8000/inter-latin.woff2")
    entry["response"]["content"]["mimeType"] = "application/octet-stream"
    har = make_har(entries=[entry, _entry(url="http://h:8000/walker/me")])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert "/walker/me" in entries[0].url


@pytest.mark.unit
def test_xhr_resource_type_kept(tmp_path):
    """Entries with _resourceType 'xhr' or 'fetch' must not be filtered."""
    har = make_har(entries=[
        _entry_with_resource_type("xhr",   url="http://h:8000/walker/a"),
        _entry_with_resource_type("fetch", url="http://h:8000/walker/b"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 2


@pytest.mark.unit
@pytest.mark.parametrize("ws_url", [
    "ws://h:8000/socket",
    "wss://h:8000/socket",
])
def test_websocket_url_scheme_filtered(tmp_path, ws_url):
    """Entries with ws:// or wss:// URLs must be skipped even without _resourceType."""
    har = make_har(entries=[
        _entry(url=ws_url),
        _entry(url="http://h:8000/walker/me"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert "/walker/me" in entries[0].url


@pytest.mark.unit
def test_unsupported_type_warning_emitted_once(tmp_path, capsys):
    """Warning for unsupported resource types must appear exactly once."""
    har = make_har(entries=[
        _entry_with_resource_type("websocket", url="http://h:8000/ws1"),
        _entry_with_resource_type("websocket", url="http://h:8000/ws2"),
        _entry(url="http://h:8000/walker/me"),
    ])
    path = _write_har(tmp_path, har)
    parse_har(path, target_url="http://t:9000")
    captured = capsys.readouterr()
    assert captured.err.count("WebSocket") == 1


# ---------------------------------------------------------------------------
# Cache-busting URL filter
# ---------------------------------------------------------------------------

@pytest.mark.unit
@pytest.mark.parametrize("url", [
    "http://h:8000/track?_=1779986528514",        # 13-digit ms timestamp
    "http://h:8000/track?_=1609459200",           # 10-digit s timestamp
    "http://h:8000/track?cb=1779986528514",
    "http://h:8000/track?cachebust=1609459200",
    "http://h:8000/track?nocache=1609459200000",
    "http://h:8000/track?bust=1609459200",
    "http://h:8000/track?ip=0&_=1779986528514&ver=1.3",  # mixed params
])
def test_cache_buster_urls_filtered(tmp_path, url):
    """Entries with cache-busting timestamp query params must be skipped."""
    har = make_har(entries=[
        _entry(url=url),
        _entry(url="http://h:8000/walker/me"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert "/walker/me" in entries[0].url


@pytest.mark.unit
@pytest.mark.parametrize("url", [
    "http://h:8000/api?_=hello",          # non-numeric value
    "http://h:8000/api?page=1609459200",  # timestamp-like but param is 'page'
    "http://h:8000/api?_=123",            # too short to be a timestamp (< 10 digits)
    "http://h:8000/api?_=12345678901234", # too long (> 13 digits)
    "http://h:8000/api/data",             # no query string at all
])
def test_non_cache_buster_urls_kept(tmp_path, url):
    """Entries that look similar but are not cache busters must not be filtered."""
    har = make_har(entries=[_entry(url=url)])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1


@pytest.mark.unit
def test_cache_buster_warning_emitted_once(tmp_path, capsys):
    """Warning for cache-busting URLs must appear exactly once."""
    har = make_har(entries=[
        _entry(url="http://h:8000/track?_=1779986528514"),
        _entry(url="http://h:8000/track?_=1779986530000"),
        _entry(url="http://h:8000/walker/me"),
    ])
    path = _write_har(tmp_path, har)
    parse_har(path, target_url="http://t:9000")
    captured = capsys.readouterr()
    assert captured.err.count("cache-busting") == 1


# ---------------------------------------------------------------------------
# Missing-body filter (POST/PUT/PATCH with Content-Length but no captured body)
# ---------------------------------------------------------------------------

def _entry_missing_body(method="POST", url="http://h:8000/walker/create"):
    """Entry where Content-Length says there's a body but postData was not captured."""
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
    }


@pytest.mark.unit
def test_missing_body_entry_skipped(tmp_path):
    """POST with Content-Length > 0 but no captured body must be skipped."""
    har = make_har(entries=[
        _entry_missing_body(),
        _entry(url="http://h:8000/walker/search"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1
    assert "/walker/search" in entries[0].url


@pytest.mark.unit
@pytest.mark.parametrize("method", ["POST", "PUT", "PATCH"])
def test_missing_body_skipped_for_mutation_methods(tmp_path, method):
    """All mutation methods with a missing body must be skipped."""
    har = make_har(entries=[
        _entry_missing_body(method=method),
        _entry(url="http://h:8000/walker/search"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1


@pytest.mark.unit
def test_get_without_body_not_skipped(tmp_path):
    """GET entries with no body must not be filtered by the missing-body rule."""
    har = make_har(entries=[
        _entry(method="GET", url="http://h:8000/walker/list", body=None),
    ])
    # Patch postData to be absent (GET has no body naturally)
    har["log"]["entries"][0]["request"].pop("postData", None)
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1


@pytest.mark.unit
def test_post_with_body_not_skipped(tmp_path):
    """POST with a captured body must pass through normally."""
    har = make_har(entries=[
        _entry(method="POST", url="http://h:8000/walker/create", body='{"name": "x"}'),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert len(entries) == 1


@pytest.mark.unit
def test_missing_body_warning_emitted_once(tmp_path, capsys):
    """Warning for missing-body entries must appear exactly once."""
    har = make_har(entries=[
        _entry_missing_body(url="http://h:8000/walker/a"),
        _entry_missing_body(url="http://h:8000/walker/b"),
        _entry(url="http://h:8000/walker/search"),
    ])
    path = _write_har(tmp_path, har)
    parse_har(path, target_url="http://t:9000")
    captured = capsys.readouterr()
    assert captured.err.count("postData missing") == 1


# ---------------------------------------------------------------------------
# Occurrence numbering
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_occurrence_single_endpoint(tmp_path):
    """A path that appears once gets occurrence=1, total_occurrences=1."""
    har = make_har(entries=[_entry(url="http://h:8000/walker/search")])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert entries[0].occurrence == 1
    assert entries[0].total_occurrences == 1


@pytest.mark.unit
def test_occurrence_repeated_endpoint(tmp_path):
    """The same path appearing N times gets sequential occurrence numbers 1..N."""
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"load_history"}'),
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"start"}'),
        _entry(url="http://h:8000/walker/ai_chat", body='{"action":"load_history"}'),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert [(e.occurrence, e.total_occurrences) for e in entries] == [
        (1, 3), (2, 3), (3, 3)
    ]


@pytest.mark.unit
def test_occurrence_different_endpoints_independent(tmp_path):
    """Different paths each get their own independent occurrence counters."""
    har = make_har(entries=[
        _entry(url="http://h:8000/walker/search"),
        _entry(url="http://h:8000/walker/create"),
        _entry(url="http://h:8000/walker/search"),
    ])
    path = _write_har(tmp_path, har)
    entries = parse_har(path, target_url="http://t:9000")
    assert entries[0].occurrence == 1 and entries[0].total_occurrences == 2  # search #1
    assert entries[1].occurrence == 1 and entries[1].total_occurrences == 1  # create #1
    assert entries[2].occurrence == 2 and entries[2].total_occurrences == 2  # search #2
