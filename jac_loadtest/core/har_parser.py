"""Parse HAR 1.2 files, filter non-API entries, and rewrite URLs.

core/ has zero knowledge of jac-scale internals.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from urllib.parse import parse_qs, urlparse, urlunparse


_SKIP_MIME_PREFIXES = (
    "image/",
    "font/",
    "text/css",
    "application/javascript",
    "text/javascript",
    "application/wasm",
)

_STRIP_HEADERS = {"authorization", "cookie", "host", "content-length"}

# Browser resource types the tool cannot replay correctly.
_SKIP_RESOURCE_TYPES = {
    "websocket",   # protocol upgrade — tool can't speak WS
    "eventsource", # streaming SSE — resp.read() blocks forever
    "document",    # page navigations
    "manifest",    # web app manifests
    "texttrack",   # subtitle/caption tracks
    "media",       # audio/video
    "font",        # fonts — Chrome sets _resourceType="font" but MIME is often application/octet-stream, not font/*
}

# Query-param names used exclusively as cache busters.
_CACHE_BUSTER_PARAMS = {"_", "cb", "cachebust", "cache_bust", "nocache", "bust"}
# Unix timestamp: 10 digits (seconds) or 13 digits (milliseconds).
_TIMESTAMP_RE = re.compile(r"^\d{10,13}$")


@dataclass
class HarEntry:
    method: str
    url: str
    headers: dict[str, str]
    body: str | None
    body_mime: str | None
    think_time_ms: float
    is_login: bool
    original_url: str


def _origin(url: str) -> str:
    """Return scheme://host:port (no path) from a URL."""
    p = urlparse(url)
    return urlunparse((p.scheme, p.netloc, "", "", "", ""))


def _rewrite_url(original: str, recorded_origin: str, target_url: str) -> str:
    """Replace recorded origin with target_url, preserving path and query."""
    p = urlparse(original)
    t = urlparse(target_url)
    rewritten = urlunparse((t.scheme, t.netloc, p.path, p.params, p.query, ""))
    return rewritten


def _is_static(mime: str) -> bool:
    if not mime:
        return False
    mime_lower = mime.lower().split(";")[0].strip()
    return any(mime_lower.startswith(prefix) for prefix in _SKIP_MIME_PREFIXES)


def _is_unsupported_type(entry: dict) -> bool:
    """Return True if the entry uses a protocol or resource type the tool cannot replay."""
    resource_type = entry.get("_resourceType", "").lower()
    if resource_type in _SKIP_RESOURCE_TYPES:
        return True
    url = entry.get("request", {}).get("url", "")
    return url.startswith(("ws://", "wss://"))


def _has_missing_body(method: str, raw_headers: list[dict], post_data: dict | None) -> bool:
    """Return True if a request should have a body but none was captured in the HAR."""
    if method.upper() not in ("POST", "PUT", "PATCH"):
        return False
    content_length = next(
        (h["value"] for h in raw_headers if h.get("name", "").lower() == "content-length"),
        "0",
    )
    try:
        has_content = int(content_length) > 0
    except ValueError:
        has_content = False
    body_text = (post_data or {}).get("text")
    return has_content and not body_text


def _has_cache_buster(url: str) -> bool:
    """Return True if the URL contains a stale cache-busting timestamp parameter."""
    qs = parse_qs(urlparse(url).query)
    return any(
        param.lower() in _CACHE_BUSTER_PARAMS
        and values
        and _TIMESTAMP_RE.match(values[0])
        for param, values in qs.items()
    )


def parse_har(
    har_path: str,
    target_url: str | None = None,
    include_static: bool = False,
    login_path: str = "/user/login",
) -> list[HarEntry]:
    """Parse a HAR 1.2 file and return filtered, URL-rewritten HarEntry objects.

    target_url: when provided, rewrites all entry origins to this URL (monolith mode).
                when None, keeps original recorded URLs — the TopologyRouter handles
                per-request routing at send time (microservice mode without gateway URL).
    """
    with open(har_path, encoding="utf-8") as f:
        data = json.load(f)

    if "log" not in data:
        raise ValueError("Malformed HAR file: missing 'log' key")

    _check_version(data["log"].get("version", "unknown"))

    raw_entries = data["log"].get("entries", [])

    if not raw_entries:
        return []

    recorded_origin = _origin(raw_entries[0]["request"]["url"])

    # Security scan — warn once if any auth headers found
    _security_scan(raw_entries)

    result: list[HarEntry] = []
    warned_unsupported = False
    warned_cache_buster = False
    warned_missing_body = False

    for entry in raw_entries:
        req = entry["request"]
        resp = entry.get("response", {})
        content = resp.get("content", {})
        mime = content.get("mimeType", "")

        if _is_unsupported_type(entry):
            if not warned_unsupported:
                print(
                    "\n\033[33mWarning: HAR contains WebSocket, SSE, or non-API entries "
                    "(websocket, eventsource, document, etc.). "
                    "These are skipped automatically.\033[0m",
                    file=sys.stderr,
                )
                warned_unsupported = True
            continue

        original_url = req["url"]

        if _has_cache_buster(original_url):
            if not warned_cache_buster:
                print(
                    "\n\033[33mWarning: HAR contains URLs with cache-busting timestamp "
                    "parameters (e.g. ?_=<timestamp>). These entries are skipped — "
                    "the stale timestamp causes the server to reject the request.\033[0m",
                    file=sys.stderr,
                )
                warned_cache_buster = True
            continue

        if not include_static and _is_static(mime):
            continue

        if target_url is not None:
            rewritten_url = _rewrite_url(original_url, recorded_origin, target_url)
        else:
            rewritten_url = original_url  # keep recorded URL; topology handles routing

        raw_headers = req.get("headers", [])

        if _has_missing_body(req["method"], raw_headers, req.get("postData")):
            if not warned_missing_body:
                print(
                    "\n\033[33mWarning: HAR contains POST/PUT/PATCH entries where the request body "
                    "was not captured (postData missing despite non-zero Content-Length). "
                    "These entries are skipped — replaying them without a body would cause "
                    "422 errors. Re-record the HAR to capture the full request body.\033[0m",
                    file=sys.stderr,
                )
                warned_missing_body = True
            continue

        headers = _sanitize_headers(raw_headers)

        post_data = req.get("postData", {}) or {}
        body = post_data.get("text") or None
        body_mime = post_data.get("mimeType") or None

        timings = entry.get("timings", {})
        think_time_ms = float(timings.get("wait", 0.0))

        is_login = urlparse(original_url).path == login_path

        result.append(
            HarEntry(
                method=req["method"].upper(),
                url=rewritten_url,
                headers=headers,
                body=body,
                body_mime=body_mime,
                think_time_ms=think_time_ms,
                is_login=is_login,
                original_url=original_url,
            )
        )

    return result


_SUPPORTED_HAR_VERSIONS = {"1.1", "1.2"}


def _check_version(version: str) -> None:
    """Warn if the HAR version is outside the tested range."""
    if version not in _SUPPORTED_HAR_VERSIONS:
        print(
            f"\n\033[33mWarning: HAR version '{version}' is not tested with this tool "
            f"(tested: {', '.join(sorted(_SUPPORTED_HAR_VERSIONS))}).\n"
            "Parsing will continue but results may be incomplete or incorrect.\n"
            "If the output looks wrong, check for a jac-loadtest update.\033[0m",
            file=sys.stderr,
        )


def _security_scan(entries: list[dict]) -> None:
    """Emit a stderr warning if any HAR entry contains auth/cookie headers."""
    for entry in entries:
        for hdr in entry.get("request", {}).get("headers", []):
            name = hdr.get("name", "").lower()
            value = hdr.get("value", "")
            if name in ("authorization", "cookie") and value:
                print(
                    "\n\033[33mWarning: HAR file contains Authorization/Cookie headers from the "
                    "recording session.\nThese headers are stripped before replay, but "
                    "the file itself contains sensitive data.\n"
                    "Do not commit this HAR file to version control.\033[0m",
                    file=sys.stderr,
                )
                return


def _sanitize_headers(raw_headers: list[dict]) -> dict[str, str]:
    """Strip session-specific and HTTP/2 pseudo-headers; return clean dict."""
    return {
        h["name"]: h["value"]
        for h in raw_headers
        if h.get("name", "").lower() not in _STRIP_HEADERS
        and not h.get("name", "").startswith(":")
    }
