"""Minimal log server for verifying microservice routing only.

What this verifies:
  - Which paths arrive at which mock service (routing is correct)
  - The "Service" column and service labels in the loadtest report
  - That the tool does not crash in microservice mode

What this does NOT verify:
  - Functional compatibility with a real jac-scale app
  - Authentication (mock accepts all requests without a token)
  - Correct walker request/response shapes

For full end-to-end compatibility testing, run jac-scale locally
(jac serve) and point the loadtest at the real service ports.

Usage:
    jac run mock_service.jac <service_name> <port>

Prints every request it receives and always responds 200 {"ok": true}.
Run two instances on different ports, then run jac loadtest --mode microservice
pointing to them. Check which paths each service received.
"""
import sys;
import asyncio;
import aiohttp.web;


async def _serve(service_name: str, port: int) {
    async def _handle(request: aiohttp.web.Request) -> aiohttp.web.Response {
        print(f"  [{service_name}:{port}]  {request.method}  {request.path}");
        return aiohttp.web.json_response({"ok": True, "service": service_name});
    }

    app = aiohttp.web.Application();
    app.router.add_route("*", "/{path_info:.*}", _handle);

    runner = aiohttp.web.AppRunner(app);
    await runner.setup();
    site = aiohttp.web.TCPSite(runner, "", port);
    await site.start();

    print(f"[{service_name}] listening on :{port}  (Ctrl+C to stop)");

    try {
        await asyncio.Event().wait();
    } except asyncio.CancelledError {
    
    } finally {
        await runner.cleanup();
        print(f"\n[{service_name}] stopped");
    }
}


with entry {
    if len(sys.argv) != 3 {
        print("usage: jac run mock_service.jac <service_name> <port>");
        sys.exit(1);
    }
    name: str = sys.argv[1];
    port: int = int(sys.argv[2]);
    asyncio.run(_serve(name, port));
}
