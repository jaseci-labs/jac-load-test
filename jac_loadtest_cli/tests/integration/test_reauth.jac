"""Integration tests for mid-run re-authentication (Phase 7b).

Tokens are acquired once before the replay loop, so a run longer than the JWT's
lifetime used to degrade into 100% auth failures partway through with no
recovery -- the soak-test failure in CONSTRAINTS.md section 1. These pin the
recovery, and the two things that could go wrong with it: an endless retry loop,
and one expiry turning into one login per VU.
"""

import asyncio;
import hashlib;
import secrets;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.bridge.auth { AuthProvider, parse_accounts }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.metrics { MetricsCollector }


def _expiring_app(
    uses: int, accounts: dict, dead_first: bool = False
) -> aiohttp.web.Application {
    # Tokens die after `uses` requests, standing in for a JWT lifetime elapsing
    # mid-run. uses=0 means a token is never valid, so re-authentication cannot
    # help and the run must say so rather than retrying forever.
    users: dict = {k: hashlib.sha256(v.encode()).hexdigest() for (k, v) in accounts.items()};
    live: dict = {};
    logins: list = [];

    async def _login(r: aiohttp.web.Request) -> aiohttp.web.Response {
        payload = await r.json();
        name = payload["identity"]["value"];
        password = payload["credential"]["password"];
        if users.get(name) != hashlib.sha256(password.encode()).hexdigest() {
            return aiohttp.web.json_response(
                {"code": "UNAUTHORIZED", "message": "Invalid credentials"}, status=401
            );
        }
        logins.append(name);
        token = secrets.token_urlsafe(8);
        # dead_first models the realistic shape: a JWT expires by wall time, so
        # the token every VU is holding goes bad at once and a single refresh
        # then serves all of them. (`uses` alone models a per-use budget, where a
        # refreshed token can be exhausted by other VUs before a given VU's retry
        # reaches it -- useful for the AUTH_EXPIRED path, misleading here.)
        budget = 0 if (dead_first and logins.count(name) == 1) else uses;
        live[token] = [name, budget];
        return aiohttp.web.json_response(
            {"success": True, "data": {"username": name, "token": token}}
        );
    }

    async def _walker(r: aiohttp.web.Request) -> aiohttp.web.Response {
        token = r.headers.get("Authorization", "").replace("Bearer ", "");
        state = live.get(token);
        if state is None or state[1] <= 0 {
            return aiohttp.web.json_response(
                {"code": "UNAUTHORIZED", "message": "token expired"}, status=401
            );
        }
        state[1] -= 1;
        return aiohttp.web.json_response({"reports": [{"ok": True, "as": state[0]}]});
    }

    app = aiohttp.web.Application();
    app.router.add_post("/user/login", _login);
    app.router.add_post("/walker/Whoami", _walker);
    app["logins"] = logins;
    return app;
}

def _entry(base: str) -> HarEntry {
    return HarEntry(
        method="POST", url=f"{base}/walker/Whoami", headers={}, body="{}",
        body_mime="application/json", think_time_ms=0.0, is_login=False,
        original_url="/walker/Whoami",
    );
}

def _run(
    uses: int, accounts: dict, vus: int, iterations: int, dead_first: bool = False
) -> dict {
    result: list = [None];

    async def _go() {
        app = _expiring_app(uses, accounts, dead_first);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            provider = AuthProvider(_accounts=parse_accounts(accounts));
            config = LoadTestConfig(
                vus=vus, iterations=iterations, mode="monolith", url=base,
                accounts=accounts,
            );
            metrics = MetricsCollector();
            await run_all_vus(
                [_entry(base)], config, metrics, auth_provider=provider
            );
            stats = metrics.compute_endpoint_stats()[0];
            result[0] = {
                "total": stats.total_requests,
                "ok": stats.success_count,
                "errors": stats.error_count,
                "breakdown": dict(stats.error_breakdown),
                "logins": len(app["logins"]),
            };
        }
    }

    asyncio.run(_go());
    return result[0];
}


test "an expired token is refreshed mid-run and the request retried" {
    # 3 VUs x 12 iterations with tokens good for 3 requests: without recovery
    # this is 9 successes and 27 auth failures.
    out = _run(uses=3, accounts={"u0": "pw0", "u1": "pw1", "u2": "pw2"}, vus=3, iterations=12);
    assert out["total"] == 36;
    assert out["ok"] == 36;
    assert out["errors"] == 0;
    # 12 requests per VU over tokens worth 3 each = 4 logins per VU.
    assert out["logins"] == 12;
}

test "a second 401 after refreshing is reported as AUTH_EXPIRED" {
    # uses=0: every token is dead on arrival, so re-authenticating cannot fix it.
    # The request must fail once with a named reason, not retry indefinitely.
    out = _run(uses=0, accounts={"u0": "pw0"}, vus=2, iterations=3);
    assert out["ok"] == 0;
    assert out["errors"] == 6;
    assert list(out["breakdown"].keys()) == ["AUTH_EXPIRED: still 401 after re-authentication"];
    # At most one refresh per request, and never fewer than the initial login.
    # Bounded rather than exact: VUs that queue behind a concurrent refresh reuse
    # its result instead of logging in again, so the exact count depends on how
    # the VUs interleave. The point is that it is bounded at all — an unguarded
    # retry would loop forever against a token that is never valid.
    assert 1 <= out["logins"] <= out["total"] + 1;
}

test "VUs sharing an account refresh it once, not once each" {
    # The failure this guards against: a JWT expires at a wall time, so every VU
    # holding it 401s at once. Without per-account locking, 12 VUs would fire 12
    # simultaneous logins at the endpoint least able to take them.
    out = _run(
        uses=10_000, accounts={"u0": "pw0"}, vus=12, iterations=10, dead_first=True
    );
    assert out["total"] == 120;
    assert out["ok"] == 120;
    # Every VU holds the same dead token and 401s at essentially the same moment.
    # Two logins is the floor (the initial one, plus the single refresh they all
    # share); 12 VUs each refreshing for themselves would be 13.
    assert out["logins"] <= 3;
}

test "an unauthenticated run is untouched by the refresh path" {
    # No provider, so a 401 is just a 401 — nothing to refresh, and the tool must
    # not invent an error class for it.
    result: list = [None];

    async def _go() {
        async def _always_401(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.json_response({"error": "nope"}, status=401);
        }
        app = aiohttp.web.Application();
        app.router.add_post("/walker/Whoami", _always_401);
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            config = LoadTestConfig(vus=1, iterations=2, mode="monolith", url=base);
            metrics = MetricsCollector();
            await run_all_vus([_entry(base)], config, metrics);
            result[0] = [r.error_type for r in metrics._samples];
        }
    }

    asyncio.run(_go());
    assert all(e is None for e in result[0]);
}

test "a recording that expects a 401 is not refreshed" {
    # A HAR deliberately exercising an auth-failure path should keep seeing its
    # 401 rather than having the tool try to repair it.
    result: list = [None, None];

    async def _go() {
        app = _expiring_app(0, {"u0": "pw0"});
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            expects_401 = _entry(base);
            expects_401.expected_status = 401;
            provider = AuthProvider(_accounts=parse_accounts({"u0": "pw0"}));
            config = LoadTestConfig(vus=1, iterations=2, mode="monolith", url=base);
            metrics = MetricsCollector();
            await run_all_vus([expects_401], config, metrics, auth_provider=provider);
            result[0] = [r.error_type for r in metrics._samples];
            result[1] = len(app["logins"]);
        }
    }

    asyncio.run(_go());
    assert all(e is None for e in result[0]);
    # Only the pre-run login: no refresh was attempted.
    assert result[1] == 1;
}
