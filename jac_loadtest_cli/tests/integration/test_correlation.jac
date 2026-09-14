"""Integration tests for response correlation — real requests, stateful server.

The unit tests cover detection and injection in isolation. These pin the
behaviour that actually matters: a HAR carrying the recording user's node id
fails every ownership check on replay, and correlation is what fixes it.
"""

import asyncio;
import json;
import uuid;
import aiohttp;
import aiohttp.web;
import from aiohttp.test_utils { TestServer }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.correlation { build_rules }
import from jac_loadtest_cli.core.engine { run_all_vus }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.metrics { MetricsCollector }

glob RECORDED_ID: str = "a3f7c2d1-9f4b-4e2a-b123-77aa0912ffde";


def _stateful_app() -> aiohttp.web.Application {
    # Mirrors how jac-scale behaves: Add mints a node id, and anything operating
    # on a node only succeeds for an id this run actually created. The recording's
    # id belongs to someone else's data, so replaying it verbatim is a 404.
    live: set = set();

    async def _add(r: aiohttp.web.Request) -> aiohttp.web.Response {
        node_id = str(uuid.uuid4());
        live.add(node_id);
        return aiohttp.web.json_response({"reports": [{"id": node_id, "ok": True}]});
    }

    async def _operate(r: aiohttp.web.Request) -> aiohttp.web.Response {
        try {
            body = json.loads(await r.text() or "{}");
        } except Exception {
            body = {};
        }
        if body.get("nd") in live {
            return aiohttp.web.json_response({"reports": [{"ok": True}]});
        }
        return aiohttp.web.json_response({"error": "node not found"}, status=404);
    }

    app = aiohttp.web.Application();
    app.router.add_post("/walker/AddTodo", _add);
    app.router.add_post("/walker/ToggleTodo", _operate);
    app.router.add_post("/walker/DeleteTodo", _operate);
    return app;
}

def _workflow_entries(base: str) -> list[HarEntry] {
    stale = '{"nd":"' + RECORDED_ID + '"}';
    return [
        HarEntry(
            method="POST", url=f"{base}/walker/AddTodo", headers={},
            body='{"title":"Buy milk"}', body_mime="application/json",
            think_time_ms=0.0, is_login=False, original_url="/walker/AddTodo",
            recorded_response='{"reports":[{"id":"' + RECORDED_ID + '","ok":true}]}',
        ),
        HarEntry(
            method="POST", url=f"{base}/walker/ToggleTodo", headers={},
            body=stale, body_mime="application/json",
            think_time_ms=0.0, is_login=False, original_url="/walker/ToggleTodo",
            recorded_response='{"reports":[{"ok":true}]}',
        ),
        HarEntry(
            method="POST", url=f"{base}/walker/DeleteTodo", headers={},
            body=stale, body_mime="application/json",
            think_time_ms=0.0, is_login=False, original_url="/walker/DeleteTodo",
            recorded_response='{"reports":[{"ok":true}]}',
        ),
    ];
}

def _run_workflow(vus: int, iterations: int, auto: bool, explicit: list[str] | None) -> dict {
    outcome: list = [None];

    async def _run() {
        async with TestServer(_stateful_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = _workflow_entries(base);
            config = LoadTestConfig(
                vus=vus, iterations=iterations, mode="monolith", url=base,
                auto_correlate=auto, correlate=explicit,
            );
            rules = build_rules(entries, explicit, auto, announce=False);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, correlation_rules=rules);
            by_endpoint: dict = {};
            for stat in metrics.compute_endpoint_stats() {
                by_endpoint[stat.endpoint] = stat.success_rate_pct;
            }
            outcome[0] = by_endpoint;
        }
    }

    asyncio.run(_run());
    return outcome[0];
}


test "replaying a recorded node id fails every ownership check" {
    # The defect correlation exists to fix, asserted as a number so the fix below
    # is measured against something real rather than assumed.
    rates = _run_workflow(vus=2, iterations=2, auto=False, explicit=None);
    assert rates["/walker/AddTodo"] == 100.0;
    assert rates["/walker/ToggleTodo"] == 0.0;
    assert rates["/walker/DeleteTodo"] == 0.0;
}

test "automatic correlation repairs the workflow with no configuration" {
    rates = _run_workflow(vus=2, iterations=2, auto=True, explicit=None);
    assert rates["/walker/AddTodo"] == 100.0;
    assert rates["/walker/ToggleTodo"] == 100.0;
    assert rates["/walker/DeleteTodo"] == 100.0;
}

test "correlation holds across many VUs and iterations" {
    # Each VU must thread its own id: any leakage between VUs or between
    # iterations shows up here as a 404, because a toggle only succeeds against
    # an id created in that same iteration.
    rates = _run_workflow(vus=6, iterations=4, auto=True, explicit=None);
    assert rates["/walker/ToggleTodo"] == 100.0;
    assert rates["/walker/DeleteTodo"] == 100.0;
}

test "an explicit rule correlates only the endpoint it names" {
    rates = _run_workflow(
        vus=2, iterations=2, auto=False,
        explicit=["AddTodo.response.reports.0.id -> ToggleTodo.body.nd"],
    );
    assert rates["/walker/ToggleTodo"] == 100.0;
    # DeleteTodo has no rule, so it still replays the recording's stale id.
    assert rates["/walker/DeleteTodo"] == 0.0;
}

test "a consumer whose producer failed reports CORRELATION_MISS" {
    # Not a 404 blamed on the application: the request is never sent, because the
    # value it needs was never handed over.
    outcome: list = [None];

    async def _run() {
        async def _fail(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.json_response({"error": "boom"}, status=500);
        }
        async def _operate(r: aiohttp.web.Request) -> aiohttp.web.Response {
            return aiohttp.web.json_response({"reports": [{"ok": True}]});
        }
        app = aiohttp.web.Application();
        app.router.add_post("/walker/AddTodo", _fail);
        app.router.add_post("/walker/ToggleTodo", _operate);
        app.router.add_post("/walker/DeleteTodo", _operate);

        async with TestServer(app) as server {
            base = f"http://{server.host}:{server.port}";
            entries = _workflow_entries(base);
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base);
            rules = build_rules(entries, None, True, announce=False);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, correlation_rules=rules);
            outcome[0] = [
                r.error_type for r in metrics._samples if r.error_type
            ];
        }
    }

    asyncio.run(_run());
    errors = outcome[0];
    assert any(str(e).startswith("CORRELATION_MISS") for e in errors);
}

test "correlation_applied records which rules rewrote a request" {
    outcome: list = [None];

    async def _run() {
        async with TestServer(_stateful_app()) as server {
            base = f"http://{server.host}:{server.port}";
            entries = _workflow_entries(base);
            config = LoadTestConfig(vus=1, iterations=1, mode="monolith", url=base);
            rules = build_rules(entries, None, True, announce=False);
            metrics = MetricsCollector();
            await run_all_vus(entries, config, metrics, correlation_rules=rules);
            outcome[0] = {
                r.endpoint: list(r.correlation_applied) for r in metrics._samples
            };
        }
    }

    asyncio.run(_run());
    applied = outcome[0];
    # The producer rewrites nothing; both consumers do.
    assert applied["/walker/AddTodo"] == [];
    assert len(applied["/walker/ToggleTodo"]) == 1;
    assert len(applied["/walker/DeleteTodo"]) == 1;
}
