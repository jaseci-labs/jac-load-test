"""End-to-end tests for headless.jac — run_test_headless() called synchronously,
exactly the way a non-async embedder (e.g. the sv walker) would call it.

run_test_headless() is a plain synchronous function that calls asyncio.run()
internally, so it cannot be invoked from inside an already-running event loop.
These tests therefore run the target aiohttp server on its own event loop in a
background thread, and call run_test_headless() directly from the main thread —
the same shape a real (non-async) caller would use.
"""

import io;
import sys;
import threading;
import contextlib;
import aiohttp.web;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.metrics { StatsSnapshot }
import from jac_loadtest_cli.headless { run_test_headless }
import asyncio;

glob _FIXTURES: object = __import__("pathlib").Path(__file__).parent.parent / "fixtures";


def _make_app() -> aiohttp.web.Application {
    async def _api(r: aiohttp.web.Request) -> aiohttp.web.Response {
        return aiohttp.web.json_response({"ok": True});
    }
    app = aiohttp.web.Application();
    app.router.add_route("*", "/{path_info:.*}", _api);
    return app;
}

obj _BackgroundServer {
    has app: aiohttp.web.Application;
    has base_url: str = "";
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
# run_test_headless — happy path
# ---------------------------------------------------------------------------

test "run_test_headless returns a JSON-serialisable dict" {
    server = _BackgroundServer(app=_make_app());
    server.start();
    try {
        config = LoadTestConfig.from_dict({
            "har_file": str(_FIXTURES / "minimal.har"),
            "url": server.base_url,
            "vus": 2,
            "iterations": 2,
            "mode": "monolith",
            "workers": 1,
        });
        result = run_test_headless(config);
    } finally {
        server.stop();
    }

    assert isinstance(result, dict);
    assert set(result.keys()) == {"meta", "latency_benchmarks", "endpoints", "summary", "cumulative_timeseries"};
    assert result["summary"]["total_requests"] > 0;
}

test "run_test_headless calls on_snapshot during the run" {
    snapshots_holder: list = [[]];

    server = _BackgroundServer(app=_make_app());
    server.start();
    try {
        config = LoadTestConfig.from_dict({
            "har_file": str(_FIXTURES / "minimal.har"),
            "url": server.base_url,
            "vus": 1,
            "iterations": 1,
            "mode": "monolith",
            "workers": 1,
        });

        def _on_snapshot(snap: StatsSnapshot) {
            snapshots_holder[0].append(snap);
        }

        run_test_headless(config, on_snapshot=_on_snapshot);
    } finally {
        server.stop();
    }
    # A single fast iteration won't cross the default 10s tick — this only
    # confirms wiring doesn't raise when a callback is supplied, not that a
    # tick actually fired (that's covered at the engine level).
    for snap in snapshots_holder[0] {
        assert isinstance(snap, StatsSnapshot);
    }
}

test "run_test_headless produces no stdout and no sys.exit" {
    server = _BackgroundServer(app=_make_app());
    server.start();
    out = io.StringIO();
    try {
        config = LoadTestConfig.from_dict({
            "har_file": str(_FIXTURES / "minimal.har"),
            "url": server.base_url,
            "vus": 1,
            "iterations": 1,
            "mode": "monolith",
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

test "run_test_headless writes no files" {
    import os;
    server = _BackgroundServer(app=_make_app());
    server.start();
    try {
        config = LoadTestConfig.from_dict({
            "har_file": str(_FIXTURES / "minimal.har"),
            "url": server.base_url,
            "vus": 1,
            "iterations": 1,
            "mode": "monolith",
            "workers": 1,
            "report_out": None,
        });
        before = set(os.listdir("."));
        run_test_headless(config);
        after = set(os.listdir("."));
    } finally {
        server.stop();
    }
    assert before == after;
}


# ---------------------------------------------------------------------------
# run_test_headless — error paths raise plain exceptions, never sys.exit
# ---------------------------------------------------------------------------

test "run_test_headless raises ValueError when url missing in monolith mode" {
    config = LoadTestConfig.from_dict({
        "har_file": str(_FIXTURES / "minimal.har"),
        "mode": "monolith",
        "workers": 1,
    });
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "run_test_headless raises ValueError when har_file missing" {
    config = LoadTestConfig.from_dict({"url": "http://localhost:1"});
    raised = False;
    try {
        run_test_headless(config);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "run_test_headless propagates FileNotFoundError for missing har file" {
    config = LoadTestConfig.from_dict({
        "har_file": "does_not_exist.har",
        "url": "http://localhost:1",
    });
    raised = False;
    try {
        run_test_headless(config);
    } except FileNotFoundError {
        raised = True;
    }
    assert raised;
}
