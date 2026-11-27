"""A mock jac-scale target for component tests.

Runs an aiohttp app on a background thread (own event loop) and counts every
request it receives, which is the ground truth the Locust runner's own report is
checked against. Walkers answer in jac-scale's envelope; login and register
follow the real 0.39.2 contract (401 for an unknown user, 201 on register, 400
IDENTITY_TAKEN for a duplicate).

Fault switches (set through mock.set_fault):
  waf       create_task, ok and graphql return one identical HTML 403 page
  inside200 /walker/ok answers 200 with reports[].success false
  envelope37 walkers answer in the jac 0.37+ envelope (reports under data.reports,
             data.result holding only the walker's own fields) instead of the
             0.34 one (reports under data.result.reports)

/graphql answers a task list, so a recorded GraphQL response carries the same ids
a create call returned.
"""

import json;
import uuid;
import asyncio;
import threading;
import aiohttp.web;

obj MockServer {
    has port: int = 0;
    has hits: dict[str, int] = {};
    has users: set[str] = set();
    has tasks: set[str] = set();
    has faults: dict[str, bool] = {};
    has loop: any = None;
    has runner: any = None;
    has thread: any = None;

    def url() -> str {
        return f"http://127.0.0.1:{self.port}";
    }

    def count(key: str) -> int {
        return self.hits.get(key, 0);
    }

    def set_fault(name: str, on: bool) -> None {
        self.faults[name] = on;
    }

    def hit(key: str) -> None {
        self.hits[key] = self.hits.get(key, 0) + 1;
    }
}

def _envelope(result: dict[str, any], modern: bool = False) -> any {
    if modern {
        fields = {k: v for (k, v) in result.items() if k != "reports"};
        data = {"result": fields, "reports": result.get("reports", [])};
    } else {
        data = {"result": result};
    }
    return aiohttp.web.json_response({"ok": True, "type": "response", "data": data, "error": None});
}

def _deny() -> any {
    return aiohttp.web.Response(
        status=403, text="<html><body>Blocked by WAF</body></html>", content_type="text/html"
    );
}

def _build_app(mock: MockServer) -> any {
    def reply(result: dict[str, any]) -> any {
        return _envelope(result, mock.faults.get("envelope37", False));
    }

    async def login(request: any) -> any {
        body = await request.json();
        name = body["identity"]["value"];
        mock.hit("/user/login");
        if name not in mock.users {
            return aiohttp.web.json_response(
                {"ok": False, "error": {"code": "UNAUTHORIZED", "message": "Invalid credentials"}}, status=401
            );
        }
        return aiohttp.web.json_response({"ok": True, "data": {"token": "tok-" + name}});
    }

    async def register(request: any) -> any {
        body = await request.json();
        name = body["identities"][0]["value"];
        mock.hit("/user/register");
        if name in mock.users {
            return aiohttp.web.json_response(
                {"ok": False, "error": {"code": "IDENTITY_TAKEN", "message": "taken"}}, status=400
            );
        }
        mock.users.add(name);
        return aiohttp.web.json_response({"ok": True, "data": {"token": "tok-" + name}}, status=201);
    }

    async def create_task(request: any) -> any {
        mock.hit("/walker/create_task");
        if mock.faults.get("waf", False) {
            return _deny();
        }
        task_id = str(uuid.uuid4());
        mock.tasks.add(task_id);
        return reply({"reports": [{"success": True, "task_id": task_id}]});
    }

    async def get_task(request: any) -> any {
        mock.hit("/walker/get_task");
        if mock.faults.get("waf", False) {
            return _deny();
        }
        body = await request.json();
        if body.get("task_id") in mock.tasks {
            return reply({"reports": [{"success": True, "title": "t"}]});
        }
        mock.hit("get_task_miss");
        return reply({"reports": [{"success": False, "error": "task not found"}]});
    }

    async def ok(request: any) -> any {
        mock.hit("/walker/ok");
        if mock.faults.get("waf", False) {
            return _deny();
        }
        if mock.faults.get("inside200", False) {
            return reply({"reports": [{"success": False, "error": "refused"}]});
        }
        return reply({"reports": [{"success": True}]});
    }

    async def graphql(request: any) -> any {
        mock.hit("/graphql");
        if mock.faults.get("waf", False) {
            return _deny();
        }
        return aiohttp.web.json_response({"data": {"tasks": [{"id": t} for t in sorted(mock.tasks)]}});
    }

    async def ws(request: any) -> any {
        sock = aiohttp.web.WebSocketResponse();
        await sock.prepare(request);
        mock.hit("ws_connect");
        async for msg in sock {
            if msg.type == aiohttp.WSMsgType.TEXT {
                mock.hit("ws_frame");
                await sock.send_json({"ok": True});
            }
        }
        return sock;
    }

    app = aiohttp.web.Application();
    app.add_routes([
        aiohttp.web.post("/user/login", login),
        aiohttp.web.post("/user/register", register),
        aiohttp.web.post("/walker/create_task", create_task),
        aiohttp.web.post("/walker/get_task", get_task),
        aiohttp.web.post("/walker/ok", ok),
        aiohttp.web.post("/graphql", graphql),
        aiohttp.web.get("/ws", ws),
    ]);
    return app;
}

def start_mock() -> MockServer {
    mock = MockServer();
    ready = threading.Event();

    def _serve() -> None {
        loop = asyncio.new_event_loop();
        asyncio.set_event_loop(loop);
        mock.loop = loop;
        runner = aiohttp.web.AppRunner(_build_app(mock));
        loop.run_until_complete(runner.setup());
        site = aiohttp.web.TCPSite(runner, "127.0.0.1", 0);
        loop.run_until_complete(site.start());
        mock.port = int(site._server.sockets[0].getsockname()[1]);
        mock.runner = runner;
        ready.set();
        loop.run_forever();
    }

    mock.thread = threading.Thread(target=_serve, daemon=True);
    mock.thread.start();
    ready.wait(timeout=10);
    return mock;
}

def stop_mock(mock: MockServer) -> None {
    if mock.loop is not None {
        mock.loop.call_soon_threadsafe(mock.loop.stop);
    }
}
