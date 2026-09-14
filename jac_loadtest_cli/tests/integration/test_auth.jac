"""Integration tests for auth flow: login, token injection, credentials, cookie jar.

Uses in-process aiohttp test servers — no real network calls.
Async tests are driven via asyncio.run() inside each test block.
"""

import asyncio;
import tempfile;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.bridge.auth { AuthProvider, AuthenticationError, Credential, parse_accounts }
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
    # --username/--password still work; Phase 7b folds them into a one-entry pool
    # rather than keeping a separate single-credential path.
    config = LoadTestConfig(username="alice", password="secret");
    provider = AuthProvider.from_config(config);
    assert provider is not None;
    assert provider.account_count() == 1;
    assert provider.credential_for(0).username == "alice";
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
            provider = AuthProvider(_accounts=[Credential("user1", "pass1")]);
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


# ---------------------------------------------------------------------------
# Phase 7b — per-VU account pool, and register-on-demand
#
# The server below mirrors jaclang runtimelib/impl/server.impl.jac: login returns
# the SAME 401 "Invalid credentials" for a missing account and a wrong password,
# and register is the only endpoint that can tell them apart (201 vs 400
# USER_EXISTS). Everything here depends on that distinction being made correctly.
# ---------------------------------------------------------------------------

import hashlib;
import secrets;

def _make_pool_app(seed: dict) -> aiohttp.web.Application {
    users: dict = {k: hashlib.sha256(v.encode()).hexdigest() for (k, v) in seed.items()};
    tokens: dict = {};
    registered: list = [];

    async def _login(r: aiohttp.web.Request) -> aiohttp.web.Response {
        payload = await r.json();
        name = payload["identity"]["value"];
        password = payload["credential"]["password"];
        if users.get(name) != hashlib.sha256(password.encode()).hexdigest() {
            return aiohttp.web.json_response(
                {"success": False, "code": "UNAUTHORIZED", "message": "Invalid credentials"},
                status=401,
            );
        }
        token = secrets.token_urlsafe(8);
        tokens[token] = name;
        return aiohttp.web.json_response(
            {"success": True, "data": {"username": name, "token": token}}
        );
    }

    async def _register(r: aiohttp.web.Request) -> aiohttp.web.Response {
        payload = await r.json();
        name = None;
        for ident in payload["identities"] {
            if ident["type"] == "username" {
                name = ident["value"];
                break;
            }
        }
        if name is None {
            return aiohttp.web.json_response(
                {"error": "identity.type 'username' is required"}, status=400
            );
        }
        if name in users {
            return aiohttp.web.json_response(
                {"success": False, "code": "USER_EXISTS", "message": "User already exists"},
                status=400,
            );
        }
        users[name] = hashlib.sha256(payload["credential"]["password"].encode()).hexdigest();
        registered.append(name);
        return aiohttp.web.json_response(
            {"success": True, "data": {"username": name, "token": secrets.token_urlsafe(8)}},
            status=201,
        );
    }

    app = aiohttp.web.Application();
    app.router.add_post("/user/login", _login);
    app.router.add_post("/user/register", _register);
    app["registered"] = registered;
    app["tokens"] = tokens;
    return app;
}


test "each VU gets a distinct token from its own account" {
    holder: list = [None];

    async def _run() {
        app = _make_pool_app({"a": "1", "b": "2", "c": "3"});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_accounts=parse_accounts('{"a":"1","b":"2","c":"3"}'));
            async with aiohttp.ClientSession() as session {
                holder[0] = (await provider.authenticate_all([0, 1, 2], session, base)).tokens;
            }
        }
    }

    asyncio.run(_run());
    tokens = holder[0];
    assert len(tokens) == 3;
    # Distinct identities mean distinct tokens, which is the whole point: three
    # VUs now exercise three root graphs instead of contending on one.
    assert len(set(tokens.values())) == 3;
}

test "VUs sharing an account share its token, and it is fetched once" {
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app({"a": "1", "b": "2"});
        calls: list = [];
        original = app.router;
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_accounts=parse_accounts('{"a":"1","b":"2"}'));
            async with aiohttp.ClientSession() as session {
                holder[0] = (await provider.authenticate_all([0, 1, 2, 3], session, base)).tokens;
            }
            holder[1] = len(app["tokens"]);
        }
    }

    asyncio.run(_run());
    tokens = holder[0];
    # 4 VUs over 2 accounts: VU0/VU2 share one identity, VU1/VU3 the other.
    assert tokens[0] == tokens[2];
    assert tokens[1] == tokens[3];
    assert tokens[0] != tokens[1];
    # Two logins, not four — the auth endpoint must not be the first thing a
    # large run overloads.
    assert holder[1] == 2;
}

test "a missing account is registered and then logged in" {
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app({"known": "pw"});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(
                _accounts=parse_accounts('{"known":"pw","brand_new":"newpw"}')
            );
            async with aiohttp.ClientSession() as session {
                holder[0] = (await provider.authenticate_all([0, 1], session, base)).tokens;
            }
            holder[1] = list(app["registered"]);
        }
    }

    asyncio.run(_run());
    assert holder[0][0];
    assert holder[0][1];
    # Only the account that did not exist was created.
    assert holder[1] == ["brand_new"];
}

test "a wrong password on an existing account is not re-registered" {
    # The 401 is identical to a missing account, so the register response is what
    # distinguishes them. Getting this wrong would either mask a typo in the
    # credentials or clobber a real account.
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app({"known": "rightpw"});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_accounts=parse_accounts('{"known":"WRONG"}'));
            async with aiohttp.ClientSession() as session {
                try {
                    await provider.authenticate_all([0], session, base);
                } except AuthenticationError as exc {
                    holder[0] = str(exc);
                }
            }
            holder[1] = list(app["registered"]);
        }
    }

    asyncio.run(_run());
    assert holder[0] is not None;
    assert "wrong password" in holder[0];
    assert holder[1] == [];
}

test "auto-registration can be turned off" {
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app({});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(
                _accounts=parse_accounts('{"nobody":"pw"}'), _auto_register=False
            );
            async with aiohttp.ClientSession() as session {
                try {
                    await provider.authenticate_all([0], session, base);
                } except AuthenticationError as exc {
                    holder[0] = str(exc);
                }
            }
            holder[1] = list(app["registered"]);
        }
    }

    asyncio.run(_run());
    assert "auto-registration disabled" in holder[0];
    assert holder[1] == [];
}

test "a non-401 login failure is reported without attempting registration" {
    holder: list = [None];

    async def _run() {
        async def _boom(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.json_response({"message": "database is down"}, status=500);
        }
        app = aiohttp.web.Application();
        app.router.add_post("/user/login", _boom);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_accounts=parse_accounts('{"a":"1"}'));
            async with aiohttp.ClientSession() as session {
                try {
                    await provider.authenticate_all([0], session, base);
                } except AuthenticationError as exc {
                    holder[0] = str(exc);
                }
            }
        }
    }

    asyncio.run(_run());
    # A server fault is not a missing account; registering would be nonsense.
    assert "database is down" in holder[0];
}


# ---------------------------------------------------------------------------
# Phase 7b — partial pool failures
#
# A login failure is not one dead VU: with 10 accounts, one bad row takes out a
# tenth of the run. The question is whether that should kill the run, and what
# the report has to say if it does not.
# ---------------------------------------------------------------------------

def _pool_outcome(seed: dict, pool: object, vus: int, tolerate: bool) -> object {
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app(seed);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(
                _accounts=parse_accounts(pool), _auto_register=False
            );
            async with aiohttp.ClientSession() as session {
                try {
                    holder[0] = await provider.authenticate_all(
                        list(range(vus)), session, base, tolerate_failures=tolerate
                    );
                } except AuthenticationError as exc {
                    holder[1] = str(exc);
                }
            }
        }
    }

    asyncio.run(_run());
    return holder;
}


test "one bad account aborts the run by default" {
    # The default stays fail-fast: in CI a wrong credential should fail the
    # build rather than quietly produce a thinner run.
    out = _pool_outcome(
        {"good": "pw"}, {"good": "pw", "typo": "wrong"}, vus=4, tolerate=False
    );
    assert out[0] is None;
    assert "typo" in out[1];
}

test "with --skip-failed-accounts the run continues on the survivors" {
    out = _pool_outcome(
        {"a": "1", "b": "2"}, {"a": "1", "b": "2", "broken": "x"}, vus=6, tolerate=True
    );
    outcome = out[0];
    assert outcome is not None;
    assert outcome.total_accounts == 3;
    assert outcome.active_accounts == 2;
    assert outcome.failed_count() == 1;
    assert outcome.failures[0][0] == "broken";
}

test "every requested VU still gets a token when an account is dropped" {
    # Concurrency is what the run was asked to measure. Dropping the VUs whose
    # account failed would leave every throughput number wrong with nothing
    # pointing at why, so the VUs are re-spread over the accounts that worked.
    out = _pool_outcome(
        {"a": "1", "b": "2"}, {"a": "1", "b": "2", "broken": "x"}, vus=6, tolerate=True
    );
    tokens = out[0].tokens;
    assert sorted(tokens.keys()) == [0, 1, 2, 3, 4, 5];
    assert all(tokens[i] for i in range(6));
    # Two surviving identities, so exactly two distinct tokens across six VUs.
    assert len(set(tokens.values())) == 2;
}

test "a dropped account stops being handed out for {{account}} data too" {
    # The token a VU carries and the account row its data comes from have to
    # agree. If they drift, a VU sends one identity's data ({{account.<col>}})
    # under another identity's token -- which looks like a working run and is
    # quietly measuring nonsense. Asserted against credential_for directly.
    holder: list = [None, None];

    async def _run() {
        app = _make_pool_app({"a": "1", "b": "2"});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(
                _accounts=parse_accounts({"broken": "x", "a": "1", "b": "2"}),
                _auto_register=False,
            );
            # Before authenticating, every account is still assumed usable.
            holder[0] = [provider.credential_for(i).username for i in range(3)];
            async with aiohttp.ClientSession() as session {
                await provider.authenticate_all(
                    list(range(4)), session, base, tolerate_failures=True
                );
            }
            holder[1] = [provider.credential_for(i).username for i in range(4)];
        }
    }

    asyncio.run(_run());
    assert "broken" in holder[0];
    # After the burst, the failed account is out of rotation entirely.
    assert "broken" not in holder[1];
    assert set(holder[1]) == {"a", "b"};
}

test "a pool where nothing authenticates aborts even when tolerating" {
    # Not a bad row -- a misconfiguration. Continuing would measure nothing but
    # 401s, so this is fatal regardless of the flag.
    out = _pool_outcome({}, {"nobody": "x", "noone": "y"}, vus=2, tolerate=True);
    assert out[0] is None;
    assert "No account could be authenticated" in out[1];
}
