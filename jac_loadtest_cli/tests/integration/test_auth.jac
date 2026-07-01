"""Integration tests for auth flow: login, token injection, credentials, cookie jar.

Uses in-process aiohttp test servers — no real network calls.
Async tests are driven via asyncio.run() inside each test block.
"""

import asyncio;
import tempfile;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.bridge.auth { AuthProvider, Credential }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.metrics { MetricsCollector }
import from jac_loadtest_cli.core.har_parser { HarEntry }

glob _TOKEN: str = "test-jwt-token";


# ---------------------------------------------------------------------------
# Fake server helpers (module-level so they can be referenced in async funcs)
# ---------------------------------------------------------------------------

async def _login_handler(request: aiohttp.web.Request) -> aiohttp.web.Response {
    return aiohttp.web.json_response(
        {"ok": True, "data": {"token": _TOKEN, "user_id": "u1", "role": "user"}}
    );
}

async def _echo_auth_handler(request: aiohttp.web.Request) -> aiohttp.web.Response {
    return aiohttp.web.json_response({"ok": True});
}

def _make_auth_app() -> aiohttp.web.Application {
    app = aiohttp.web.Application();
    app.router.add_post("/user/login", _login_handler);
    app.router.add_route("*", "/{path_info:.*}", _echo_auth_handler);
    return app;
}


# ---------------------------------------------------------------------------
# AuthProvider unit-level tests (no network)
# ---------------------------------------------------------------------------

test "from config shared credentials" {
    config = LoadTestConfig(username="alice", password="secret");
    provider = AuthProvider.from_config(config);
    assert provider is not None;
    assert provider.get_credential(0).username == "alice";
    assert provider.get_credential(5).username == "alice";
}

test "from config no credentials returns none" {
    config = LoadTestConfig();
    assert AuthProvider.from_config(config) is None;
}


# ---------------------------------------------------------------------------
# Network-level integration tests
# ---------------------------------------------------------------------------

test "login success returns token" {
    token_holder: list = [None];

    async def _run() {
        async with TestServer(_make_auth_app()) as server {
            base_url = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_credentials=[Credential("user1", "pass1")]);
            async with aiohttp.ClientSession() as session {
                token_holder[0] = await provider.authenticate(0, session, base_url);
            }
        }
    }

    asyncio.run(_run());
    assert token_holder[0] == _TOKEN;
}

test "token injected in subsequent requests" {
    received_headers: list = [];

    async def _capturing_handler(request: aiohttp.web.Request) -> aiohttp.web.Response {
        received_headers.append(dict(request.headers));
        return aiohttp.web.json_response({"ok": True});
    }

    async def _run() {
        app = aiohttp.web.Application();
        app.router.add_post("/user/login", _login_handler);
        app.router.add_route("*", "/{path_info:.*}", _capturing_handler);

        async with TestServer(app) as server {
            base_url = f"http://{server.host}:{server.port}";
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
            ];
            config = LoadTestConfig(
                url=base_url,
                vus=1,
                iterations=1,
                username="user1",
                password="pass1",
            );
            provider = AuthProvider.from_config(config);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, auth_provider=provider);
        }
    }

    asyncio.run(_run());
    assert any("Authorization" in h for h in received_headers) , "No Authorization header found after auth";
    auth_values = [h["Authorization"] for h in received_headers if "Authorization" in h];
    assert all(v == f"Bearer {_TOKEN}" for v in auth_values);
}

test "login entry not replayed" {
    login_calls: list = [];

    async def _counting_login(request: aiohttp.web.Request) -> aiohttp.web.Response {
        login_calls.append("login");
        return aiohttp.web.json_response({"ok": True, "data": {"token": _TOKEN}});
    }

    async def _run() {
        app = aiohttp.web.Application();
        app.router.add_post("/user/login", _counting_login);
        app.router.add_route("*", "/{path_info:.*}", _echo_auth_handler);

        async with TestServer(app) as server {
            base_url = f"http://{server.host}:{server.port}";
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
            ];
            config = LoadTestConfig(
                url=base_url,
                vus=1,
                iterations=1,
                username="user1",
                password="pass1",
            );
            provider = AuthProvider.from_config(config);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, auth_provider=provider);
        }
    }

    asyncio.run(_run());
    assert len(login_calls) == 1 , f"Expected 1 login call (pre-loop auth), got {len(login_calls)}";
}

test "no auth provider no auth header" {
    received_headers: list = [];

    async def _capturing_handler(request: aiohttp.web.Request) -> aiohttp.web.Response {
        received_headers.append(dict(request.headers));
        return aiohttp.web.json_response({"ok": True});
    }

    async def _run() {
        app = aiohttp.web.Application();
        app.router.add_post("/user/login", _login_handler);
        app.router.add_route("*", "/{path_info:.*}", _capturing_handler);

        async with TestServer(app) as server {
            base_url = f"http://{server.host}:{server.port}";
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
            ];
            config = LoadTestConfig(url=base_url, vus=1, iterations=1);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, auth_provider=None);
        }
    }

    asyncio.run(_run());
    assert not any("Authorization" in h for h in received_headers) , "Authorization header sent without auth provider";
}
