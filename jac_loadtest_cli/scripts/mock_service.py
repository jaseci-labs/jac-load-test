"""Minimal log server for verifying microservice ROUTING only.

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
    python mock_service.py <service_name> <port>

Prints every request it receives and always responds 200 {"ok": true}.
Run two instances on different ports, then run jac loadtest --mode microservice
pointing to them. Check which paths each service received.
"""
import sys
import json
from http.server import HTTPServer, BaseHTTPRequestHandler


class LogHandler(BaseHTTPRequestHandler):
    def _respond(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length else b""
        print(f"  [{self.server.service_name}:{self.server.server_port}]  {self.command}  {self.path}")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "service": self.server.service_name}).encode())

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _respond

    def log_message(self, *_):
        pass  # suppress default apache-style log lines


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: python mock_service.py <service_name> <port>")
        sys.exit(1)

    name, port = sys.argv[1], int(sys.argv[2])
    server = HTTPServer(("", port), LogHandler)
    server.service_name = name
    print(f"[{name}] listening on :{port}  (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[{name}] stopped")
