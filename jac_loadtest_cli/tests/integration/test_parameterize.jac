"""Integration tests for parameterization — real requests, payloads inspected.

The unit tests cover token expansion and rule parsing. These pin what actually
reaches the server, which is the thing that matters: that two VUs in the same
pass send different data, and that a VU's data matches the account it
authenticated as.
"""

import asyncio;
import json;
import tempfile;
import os;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.bridge.auth { AuthProvider, parse_accounts }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.metrics { MetricsCollector }
import from jac_loadtest_cli.core.parameterize { parse_param_rules }


def _recording_app() -> aiohttp.web.Application {
    seen: list = [];

    async def _login(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"success": True, "data": {"token": "t"}});
    }

    async def _walker(r: aiohttp.web.Request) -> aiohttp.web.Response {
        try {
            body = json.loads(await r.text() or "{}");
        } except Exception {
            body = {};
        }
        seen.append({
            "body": body,
            "query": dict(r.rel_url.query),
            "tenant_header": r.headers.get("X-Tenant"),
        });
        return aiohttp.web.json_response({"reports": [{"ok": True}]});
    }

    app = aiohttp.web.Application();
    app.router.add_post("/user/login", _login);
    app.router.add_post("/walker/AddTodo", _walker);
    app["seen"] = seen;
    return app;
}

def _entry(base: str, body: str, query: str = "", headers: dict | None = None) -> HarEntry {
    url = f"{base}/walker/AddTodo" + (f"?{query}" if query else "");
    return HarEntry(
        method="POST", url=url, headers=headers or {}, body=body,
        body_mime="application/json", think_time_ms=0.0, is_login=False,
        original_url="/walker/AddTodo",
    );
}

def _write(content: str) -> str {
    handle = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8");
    handle.write(content);
    handle.close();
    return handle.name;
}

def _run(
    body: str, vus: int, iterations: int, params: list[str] | None = None,
    query: str = "", headers: dict | None = None, accounts: object | None = None
) -> list {
    seen: list = [None];

    async def _go() {
        app = _recording_app();
        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            rules = parse_param_rules(params);
            provider = (
                AuthProvider(_accounts=parse_accounts(accounts)) if accounts else None
            );
            config = LoadTestConfig(
                vus=vus, iterations=iterations, mode="monolith", url=base,
                param=params, accounts=accounts,
            );
            metrics = MetricsCollector();
            await run_all_vus(
                [_entry(base, body, query, headers)], config, metrics,
                auth_provider=provider, param_rules=rules,
            );
            seen[0] = list(app["seen"]);
        }
    }

    asyncio.run(_go());
    return seen[0];
}


test "uuid tokens make every request body unique" {
    # The collision problem: replaying one recorded payload means the second VU
    # to create a uniquely-named resource gets a 409 that says nothing about
    # capacity.
    seen = _run('{"ref":"{{uuid}}"}', vus=4, iterations=3);
    refs = [r["body"]["ref"] for r in seen];
    assert len(refs) == 12;
    assert len(set(refs)) == 12;
}

test "vu_id and iter identify the sender in the payload" {
    seen = _run('{"who":"vu{{vu_id}}-i{{iter}}"}', vus=3, iterations=2);
    assert {r["body"]["who"] for r in seen} == {
        "vu0-i0", "vu0-i1", "vu1-i0", "vu1-i1", "vu2-i0", "vu2-i1"
    };
}

test "tokens expand in the query string and in headers" {
    seen = _run(
        '{"x":1}', vus=2, iterations=1,
        query="tag={{vu_id}}", headers={"X-Tenant": "run-{{vu_id}}"},
    );
    assert {r["query"]["tag"] for r in seen} == {"0", "1"};
    assert {r["tenant_header"] for r in seen} == {"run-0", "run-1"};
}

test "a param file feeds a body field and varies across VUs and passes" {
    path = _write("Alpha\nBeta\nGamma\n");
    try {
        seen = _run(
            '{"title":"recorded"}', vus=3, iterations=2,
            params=[f"AddTodo.body.title={path}"],
        );
        titles = [r["body"]["title"] for r in seen];
        assert "recorded" not in titles;
        # All three values get used rather than everyone landing on one row.
        assert set(titles) == {"Alpha", "Beta", "Gamma"};
    } finally {
        os.unlink(path);
    }
}

test "account columns follow the identity the VU authenticated as" {
    path = _write("username,password,region\na,1,eu\nb,2,us\n");
    try {
        seen = _run(
            '{"tenant":"{{account.region}}","who":"vu{{vu_id}}"}',
            vus=4, iterations=1, accounts=path,
        );
        by_vu = {r["body"]["who"]: r["body"]["tenant"] for r in seen};
        # Accounts wrap round-robin, so VU0/VU2 share one identity and its region.
        assert by_vu["vu0"] == "eu";
        assert by_vu["vu1"] == "us";
        assert by_vu["vu2"] == "eu";
        assert by_vu["vu3"] == "us";
    } finally {
        os.unlink(path);
    }
}

test "a run with no parameterization sends the recorded payload unchanged" {
    seen = _run('{"title":"recorded","n":1}', vus=2, iterations=1);
    for record in seen {
        assert record["body"] == {"title": "recorded", "n": 1};
    }
}

test "a body that merely contains braces is not mangled" {
    # Guards the narrow token pattern: a payload carrying a JS snippet or the
    # app's own template syntax has to arrive byte-for-byte.
    body = '{"code":"function(){ return {a:1}; }","tmpl":"{{unknown_thing}}"}';
    seen = _run(body, vus=1, iterations=1);
    assert seen[0]["body"]["code"] == "function(){ return {a:1}; }";
    assert seen[0]["body"]["tmpl"] == "{{unknown_thing}}";
}
