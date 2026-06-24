"""Integration tests for auth flow: login, token injection, credentials, cookie jar.

Uses in-process aiohttp test servers — no real network calls.
"""
from __future__ import annotations

import os
import types
import asyncio

import aiohttp
import aiohttp.web
import pytest

from jac_loadtest_cli.bridge.auth import AuthProvider, Credential, _load_csv
from jac_loadtest_cli.config import LoadTestConfig, BUILT_IN_DEFAULTS
from jac_loadtest_cli.core.engine import run_all_vus
from jac_loadtest_cli.core.metrics import MetricsCollector


# ---------------------------------------------------------------------------
# Shared fake-server builders
# ---------------------------------------------------------------------------

TOKEN = "test-jwt-token"
RECEIVED_HEADERS: list[dict] = []


async def _login_handler(request: aiohttp.web.Request) -> aiohttp.web.Response:
    body = await request.json()
    username = body.get("identity", {}).get("value", "")
    return aiohttp.web.json_response(
        {"ok": True, "data": {"token": TOKEN, "user_id": "u1", "role": "user"}}
    )


async def _echo_auth_handler(request: aiohttp.web.Request) -> aiohttp.web.Response:
    RECEIVED_HEADERS.append(dict(request.headers))
    return aiohttp.web.json_response({"ok": True})


def _make_auth_app() -> aiohttp.web.Application:
    app = aiohttp.web.Application()
    app.router.add_post("/user/login", _login_handler)
    app.router.add_route("*", "/{path_info:.*}", _echo_auth_handler)
    return app


# ---------------------------------------------------------------------------
# AuthProvider unit-level tests (no network)
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_get_credential_assignment():
    creds = [Credential("u1", "p1"), Credential("u2", "p2")]
    provider = AuthProvider(creds)
    assert provider.get_credential(0).username == "u1"
    assert provider.get_credential(1).username == "u2"


@pytest.mark.integration
def test_get_credential_wrap_around():
    creds = [Credential("u1", "p1"), Credential("u2", "p2")]
    provider = AuthProvider(creds)
    assert provider.get_credential(2).username == "u1"
    assert provider.get_credential(3).username == "u2"


@pytest.mark.integration
def test_from_config_shared_credentials():
    config = LoadTestConfig(username="alice", password="secret")
    provider = AuthProvider.from_config(config)
    assert provider is not None
    assert provider.get_credential(0).username == "alice"
    assert provider.get_credential(5).username == "alice"


@pytest.mark.integration
def test_from_config_no_credentials_returns_none():
    config = LoadTestConfig()
    assert AuthProvider.from_config(config) is None


@pytest.mark.integration
def test_from_config_credentials_file(tmp_path):
    csv_file = tmp_path / "creds.csv"
    csv_file.write_text("username,password\nuser1,pass1\nuser2,pass2\n")
    config = LoadTestConfig(credentials_file=str(csv_file))
    provider = AuthProvider.from_config(config)
    assert provider is not None
    assert provider.get_credential(0).username == "user1"
    assert provider.get_credential(1).username == "user2"
    assert provider.get_credential(2).username == "user1"  # wrap-around


@pytest.mark.integration
def test_load_csv_skips_header(tmp_path):
    csv_file = tmp_path / "creds.csv"
    csv_file.write_text("username,password\nalice,secret\n")
    creds = _load_csv(str(csv_file))
    assert len(creds) == 1
    assert creds[0].username == "alice"


@pytest.mark.integration
def test_load_csv_no_header(tmp_path):
    csv_file = tmp_path / "creds.csv"
    csv_file.write_text("alice,secret\nbob,hunter2\n")
    creds = _load_csv(str(csv_file))
    assert len(creds) == 2


@pytest.mark.integration
def test_load_csv_empty_raises(tmp_path):
    csv_file = tmp_path / "empty.csv"
    csv_file.write_text("")
    with pytest.raises(ValueError, match="No credentials found"):
        _load_csv(str(csv_file))


# ---------------------------------------------------------------------------
# Network-level integration tests (use aiohttp.test_utils — no pytest-aiohttp needed)
# ---------------------------------------------------------------------------

@pytest.mark.integration
async def test_login_success_returns_token():
    from aiohttp.test_utils import TestServer
    async with TestServer(_make_auth_app()) as server:
        base_url = f"http://{server.host}:{server.port}"
        provider = AuthProvider([Credential("user1", "pass1")])
        async with aiohttp.ClientSession() as session:
            token = await provider.authenticate(0, session, base_url)
    assert token == TOKEN


@pytest.mark.integration
async def test_token_injected_in_subsequent_requests():
    """After auth, all non-login requests carry Authorization: Bearer <token>."""
    from aiohttp.test_utils import TestServer
    from jac_loadtest_cli.core.har_parser import HarEntry

    RECEIVED_HEADERS.clear()
    async with TestServer(_make_auth_app()) as server:
        base_url = f"http://{server.host}:{server.port}"
        entries = [
            HarEntry(
                method="POST",
                url=f"{base_url}/walker/search",
                headers={},
                body=None,
                body_mime=None,
                think_time_ms=0.0,
                is_login=False,
                original_url="/walker/search",
            )
        ]
        config = LoadTestConfig(
            url=base_url,
            vus=1,
            duration="1s",
            iterations=1,
            username="user1",
            password="pass1",
        )
        provider = AuthProvider.from_config(config)
        metrics = MetricsCollector()
        await run_all_vus(entries, config, metrics, auth_provider=provider)

    assert any("Authorization" in h for h in RECEIVED_HEADERS), (
        "No Authorization header found in requests after auth"
    )
    auth_values = [h["Authorization"] for h in RECEIVED_HEADERS if "Authorization" in h]
    assert all(v == f"Bearer {TOKEN}" for v in auth_values)


@pytest.mark.integration
async def test_login_entry_not_replayed():
    """HAR entries with is_login=True must be skipped during the replay loop."""
    from aiohttp.test_utils import TestServer
    from jac_loadtest_cli.core.har_parser import HarEntry

    login_calls: list[str] = []

    async def counting_login(request: aiohttp.web.Request) -> aiohttp.web.Response:
        login_calls.append("login")
        return aiohttp.web.json_response({"ok": True, "data": {"token": TOKEN}})

    app = aiohttp.web.Application()
    app.router.add_post("/user/login", counting_login)
    app.router.add_route("*", "/{path_info:.*}", _echo_auth_handler)

    async with TestServer(app) as server:
        base_url = f"http://{server.host}:{server.port}"
        entries = [
            HarEntry(
                method="POST",
                url=f"{base_url}/user/login",
                headers={},
                body='{"identity":{"type":"username","value":"u"},"credential":{"type":"password","password":"p"}}',
                body_mime="application/json",
                think_time_ms=0.0,
                is_login=True,
                original_url="/user/login",
            ),
            HarEntry(
                method="POST",
                url=f"{base_url}/walker/search",
                headers={},
                body=None,
                body_mime=None,
                think_time_ms=0.0,
                is_login=False,
                original_url="/walker/search",
            ),
        ]
        config = LoadTestConfig(
            url=base_url,
            vus=1,
            iterations=1,
            duration="30s",
            username="user1",
            password="pass1",
        )
        provider = AuthProvider.from_config(config)
        metrics = MetricsCollector()
        await run_all_vus(entries, config, metrics, auth_provider=provider)

    # Only 1 login call: the pre-loop auth step. The HAR login entry is skipped.
    assert len(login_calls) == 1, (
        f"Expected 1 login call (pre-loop auth), got {len(login_calls)}"
    )


@pytest.mark.integration
async def test_no_auth_provider_no_auth_header():
    """When no credentials are configured, no Authorization header is sent."""
    from aiohttp.test_utils import TestServer
    from jac_loadtest_cli.core.har_parser import HarEntry

    RECEIVED_HEADERS.clear()
    async with TestServer(_make_auth_app()) as server:
        base_url = f"http://{server.host}:{server.port}"
        entries = [
            HarEntry(
                method="POST",
                url=f"{base_url}/walker/search",
                headers={},
                body=None,
                body_mime=None,
                think_time_ms=0.0,
                is_login=False,
                original_url="/walker/search",
            )
        ]
        config = LoadTestConfig(url=base_url, vus=1, iterations=1, duration="30s")
        metrics = MetricsCollector()
        await run_all_vus(entries, config, metrics, auth_provider=None)

    assert not any("Authorization" in h for h in RECEIVED_HEADERS), (
        "Authorization header sent even without auth provider"
    )
