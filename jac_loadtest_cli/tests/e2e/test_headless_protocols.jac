"""End-to-end tests for Phase 9 — run_test_headless() with ws_scenarios/graphql_scenarios
config blocks alongside the HTTP config, driven synchronously the way a non-async
embedder (the sv walker) would call it. Mirrors the _BackgroundServer pattern in
tests/e2e/test_headless.jac since run_test_headless() calls asyncio.run() internally
and so cannot run from inside an already-running event loop — the target server
needs its own thread/event loop.
"""

import io;
import threading;
import contextlib;
import aiohttp.web;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.headless { run_test_headless }
import asyncio;

glob _FIXTURES: object = __import__("pathlib").Path(__file__).parent.parent / "fixtures";


async def _ws_echo(request: aiohttp.web.Request) -> aiohttp.web.WebSocketResponse {
    ws = aiohttp.web.WebSocketResponse();
    await ws.prepare(request);
    async for msg in ws {
        if msg.type == aiohttp.WSMsgType.TEXT {
            await ws.send_str(f"echo:{msg.data}");
        }
    }
    return ws;
}

def _make_mixed_app() -> aiohttp.web.Application {
    async def _api(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"ok": True});
    }
    app = aiohttp.web.Application();
    app.router.add_get("/ws", _ws_echo);
    app.router.add_route("*", "/{path_info:.*}", _api);
    return app;
}


obj _BackgroundServer {
    has app: aiohttp.web.Application;
    has base_url: str = "";
    has ws_url: str = "";
    has _loop: object = None;
    has _thread: object = None;
    has _runner: object = None;

    def start() {
        ready = threading.Event();
        holder: dict = {};

        def _thread_main() {
            loop = asyncio.new_event_loop();
            asyncio.set_event_loop(loop);
            holder["loop"] = loop;

            async def _setup() -> int {
                runner = aiohttp.web.AppRunner(self.app);
                await runner.setup();
                holder["runner"] = runner;
                site = aiohttp.web.TCPSite(runner, "127.0.0.1", 0);
                await site.start();
                return site._server.sockets[0].getsockname()[1];
            }

            holder["port"] = loop.run_until_complete(_setup());
            ready.set();
            loop.run_forever();
        }

        self._thread = threading.Thread(target=_thread_main, daemon=True);
        self._thread.start();
        ready.wait(timeout=5);
        self._loop = holder["loop"];
        self._runner = holder["runner"];
        self.base_url = f"http://127.0.0.1:{holder['port']}";
        self.ws_url = f"ws://127.0.0.1:{holder['port']}/ws";
    }

    def stop() {
        done = threading.Event();

        async def _cleanup() {
            await self._runner.cleanup();
        }

        def _schedule_cleanup() {
            fut = asyncio.run_coroutine_threadsafe(_cleanup(), self._loop);
            fut.add_done_callback(lambda _f: (self._loop.stop(), done.set()));
        }

        self._loop.call_soon_threadsafe(_schedule_cleanup);
        done.wait(timeout=5);
        self._thread.join(timeout=5);
    }
}


# ---------------------------------------------------------------------------
# WebSocket-only run (no HAR)
# ---------------------------------------------------------------------------

test "run_test_headless runs a ws-only scenario with no har_file" {
    server = _BackgroundServer(app=_make_mixed_app());
    server.start();
    try {
        config = LoadTestConfig.from_dict({
            "ws_scenarios": [{"url": server.ws_url, "messages": ["a", "b"], "vus": 1, "iterations": 1}],
            "workers": 1,
        });
        result = run_test_headless(config);
    } finally {
        server.stop();
    }
    assert result["summary"]["total_requests"] == 2;
    assert result["endpoints"][0]["protocol"] == "ws";
}

test "run_test_headless raises ValueError when neither har_file nor scenarios given" {
    config = LoadTestConfig.from_dict({});
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError {
        raised = True;
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# Mixed protocol — HTTP + WS in the same run, one unified report
# ---------------------------------------------------------------------------

test "run_test_headless mixes http and ws into one merged report" {
    server = _BackgroundServer(app=_make_mixed_app());
    server.start();
    try {
        config = LoadTestConfig.from_dict({
            "har_file": str(_FIXTURES / "minimal.har"),
            "url": server.base_url,
            "vus": 1,
            "iterations": 1,
            "mode": "monolith",
            "workers": 1,
            "ws_scenarios": [{"url": server.ws_url, "messages": ["hi"], "vus": 1, "iterations": 1}],
        });
        result = run_test_headless(config);
    } finally {
        server.stop();
    }
    protocols = {ep["protocol"] for ep in result["endpoints"]};
    assert "http" in protocols;
    assert "ws" in protocols;
    # Both protocols' requests land in the same global summary.
    ws_reqs = sum(ep["total_requests"] for ep in result["endpoints"] if ep["protocol"] == "ws");
    http_reqs = sum(ep["total_requests"] for ep in result["endpoints"] if ep["protocol"] == "http");
    assert ws_reqs == 1;
    assert http_reqs == result["summary"]["total_requests"] - ws_reqs;
}


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

test "run_test_headless rejects ws_scenarios combined with workers greater than one" {
    config = LoadTestConfig.from_dict({
        "har_file": str(_FIXTURES / "minimal.har"),
        "url": "http://localhost:1",
        "workers": 2,
        "ws_scenarios": [{"url": "ws://localhost:1/ws"}],
    });
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError as exc {
        raised = True;
        assert "workers" in str(exc);
    }
    assert raised;
}

test "run_test_headless raises ValueError when ws_scenarios is malformed json" {
    config = LoadTestConfig.from_dict({
        "har_file": str(_FIXTURES / "minimal.har"),
        "url": "http://localhost:1",
        "ws_scenarios": "not json",
    });
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "run_test_headless raises ValueError when a graphql scenario is missing query" {
    config = LoadTestConfig.from_dict({
        "graphql_scenarios": [{"url": "ws://localhost:1/graphql"}],
    });
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "run_test_headless with ws-only scenario produces no stdout" {
    server = _BackgroundServer(app=_make_mixed_app());
    server.start();
    out = io.StringIO();
    try {
        config = LoadTestConfig.from_dict({
            "ws_scenarios": [{"url": server.ws_url, "messages": ["a"], "vus": 1, "iterations": 1}],
            "workers": 1,
        });
        with contextlib.redirect_stdout(out) {
            run_test_headless(config);
        }
    } finally {
        server.stop();
    }
    assert out.getvalue() == "";
}
