"""Shared fixtures for all test suites."""
from __future__ import annotations
import jaclang  # registers the .jac import hook
import pytest
import aiohttp.web


def make_har(entries: list[dict] | None = None) -> dict:
    """Build a minimal valid HAR 1.2 dict."""
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
    ]
    return {
        "log": {
            "version": "1.2",
            "entries": entries if entries is not None else default_entries,
        }
    }


@pytest.fixture
async def fake_server(aiohttp_server):
    """In-process aiohttp server returning {"ok": True} for all routes."""
    app = aiohttp.web.Application()
    app.router.add_route(
        "*",
        "/{path_info:.*}",
        lambda r: aiohttp.web.json_response({"ok": True}),
    )
    return await aiohttp_server(app)
