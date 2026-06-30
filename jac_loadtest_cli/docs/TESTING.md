# jac-loadtest Testing Strategy

## Overview

Tests are written alongside each implementation phase. This document defines what to test, how to test it, and what tooling to use for every module in the architecture.

**Two core rules:**
1. `core/` unit tests never touch the network. They run against dicts and JAC objects only.
2. Integration tests use a real in-process `aiohttp` test server — never a live jac-scale app, never a subprocess.

---

## Test Tooling

| Tool | Purpose |
|------|---------|
| `jac test` | Test runner — discovers and runs all `test "..." { }` blocks in `.jac` files |
| `unittest.mock` | Patching module-level functions (`mock.patch`, `mock.patch.object`) |
| `aiohttp.test_utils` | `TestServer` + `TestClient` — real in-process HTTP, no socket binding |
| `asyncio.run()` | Runs async test helpers from within synchronous `test` blocks |

No pytest, no test fixtures framework, no `testcontainers`, no subprocess server spawning — everything in-process.

### Running tests

```bash
# All tests (141 total, 16 parallel workers by default)
jac test tests/

# Unit tests only
jac test tests/unit/

# Integration tests only
jac test tests/integration/

# Single file
jac test tests/unit/test_har_parser.jac

# Single named test
jac test tests/unit/test_metrics.jac --test_name "percentile p50"
```

---

## Test Directory Layout

```
tests/
  fixtures/
    minimal.har          # 2-entry HAR: POST /user/login + POST /walker/search (has Authorization header)
    mixed_static.har     # HAR with image/png, text/css, font/woff2 entries
    microservice.toml    # jac.toml with [plugins.scale.microservices.routes]
  unit/
    test_har_parser.jac  # 47 tests
    test_metrics.jac     # 21 tests
    test_topology.jac    # 18 tests
    test_config.jac      # 11 tests
    test_process_runner.jac  # 9 tests
  integration/
    test_engine.jac      # 2 tests — VU lifecycle against in-process aiohttp server
    test_auth.jac        # 6 tests — login flow + JWT injection
    test_reporter.jac    # 21 tests — JSON/HTML/console output validation
```

---

## Helper Strategy

### `make_har()` — HAR builder (defined per test file)

A module-level JAC function that returns a valid HAR dict with configurable entries. Used by all HAR parser tests to avoid file I/O:

```jac
def make_har(entries: list | None = None) -> dict {
    default_entries = [
        {
            "request": {
                "method": "POST",
                "url": "http://recorded-host:8000/user/login",
                "headers": [],
                "postData": {"mimeType": "application/json", "text": '{"identity":...}'},
                "queryString": [],
            },
            "response": {"status": 200, "content": {"mimeType": "application/json"}},
            "timings": {"send": 1, "wait": 50, "receive": 5},
        },
        ...
    ];
    return {"log": {"version": "1.2", "entries": entries if entries is not None else default_entries}};
}
```

### `_entry()` — single HAR entry builder

Helper for test_har_parser.jac. Builds a single request/response dict with sensible defaults:

```jac
def _entry(
    method: str = "POST",
    url: str = "http://recorded-host:8000/walker/search",
    headers: list | None = None,
    mime: str = "application/json",
    body: str | None = None,
    wait_s: int = 42,
) -> dict { ... }
```

When `body=None`, `postData` is set to `None` (not an empty dict) so missing-body detection works correctly.

### `_write_har()` — writes HAR dict to a temp file

```jac
def _write_har(data: dict) -> str {
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".har", delete=False);
    json.dump(data, tmp);
    tmp.close();
    return tmp.name;
}
```

### `_capture_stderr()` — captures stderr output

Used to assert on warning messages emitted by `parse_har`:

```jac
def _capture_stderr(fn: object) -> str {
    old = sys.stderr;
    buf = io.StringIO();
    sys.stderr = buf;
    fn();
    captured = buf.getvalue();
    sys.stderr = old;
    return captured;
}
```

### Async integration tests

Async helpers are defined as `async def _run() { ... }` at module level or inside the test block, then called with `asyncio.run(_run())`:

```jac
test "login success" {
    async def _run() {
        async with TestServer(app) as srv {
            entries = parse_har(path, target_url=str(srv.make_url("/")));
            results = await run_all_vus(entries, cfg);
        }
        assert len(results) > 0;
    }
    asyncio.run(_run());
}
```

### Fixture `.har` files

Used only for parser edge-case tests that need realistic file content:

- `minimal.har` — 2 entries: POST /user/login + POST /walker/search. Includes `Authorization` header in the recorded session (triggers security warning tests).
- `mixed_static.har` — adds entries with `image/png`, `text/css`, `font/woff2` MIME types.

### `microservice.toml`

For topology tests that exercise jac.toml-based auto-discovery:

```toml
[plugins.scale.microservices]
enabled = true

[plugins.scale.microservices.routes]
order_service = "/walker/order"
inventory_service = "/walker/inventory"
```

Tests that use this fixture also patch env vars using `os.environ`:

```jac
saved = os.environ.pop("JAC_SV_ORDER_SERVICE_URL", None);
os.environ["JAC_SV_ORDER_SERVICE_URL"] = "http://localhost:18001";
# ... test body ...
if saved is not None { os.environ["JAC_SV_ORDER_SERVICE_URL"] = saved; }
```

---

## Mocking Strategy

Use `mock.patch.object(module_ref, attr_name, ...)` rather than the string-path form `mock.patch("module.attr")` when the test relies on the patched return value being visible through `from_args` or similar call chains. This patches the live module object and is stable under xdist multi-worker runs:

```jac
import jac_loadtest_cli.config as _cfg_mod;

test "toml overrides defaults" {
    with mock.patch.object(_cfg_mod, "_load_toml_defaults", return_value={"vus": 50}) {
        cfg = from_args(...);
    }
    assert cfg.vus == 50;
}
```

---

## Unit Tests

### `tests/unit/test_har_parser.jac` (47 tests)

All tests use `make_har()` or `_entry()` helpers. File I/O via `_write_har()` only.

| Test | What it verifies |
|------|----------------|
| parse minimal | Entry count; `method`, `url`, `body`, `think_time_ms` populated |
| mime filter default | `image/png`, `text/css`, `font/woff2` dropped; `application/json` kept |
| include static flag | With `include_static=True`, static entries are kept |
| url rewriting origin | Scheme+host+port replaced; path and query string preserved |
| url rewriting port | Port in `--url` correctly replaces recorded port |
| header sanitization | `Authorization`, `Cookie`, `Host`, `Content-Length` stripped |
| login detection default | `POST /user/login` → `is_login=True`; all others `False` |
| login detection custom path | `login_path="/api/auth"` overrides default detection |
| think time extraction | `timings.wait` stored in `HarEntry.think_time_ms` |
| security warning emitted | HAR with `Authorization` header → warning to stderr |
| security warning suppressed | HAR with no auth headers → no warning |
| unsupported type warning emitted once | Two websocket entries → warning printed exactly once |
| cache buster warning emitted once | Two cache-busted URLs → warning printed exactly once |
| missing body warning emitted once | Two missing-body POSTs → warning printed exactly once |
| malformed har missing log | Missing `log` key raises `ValueError` |
| ... and more | Static resource filtering, resource type filtering, HAR version handling |

### `tests/unit/test_metrics.jac` (21 tests)

All tests use `RequestResult` objects built inline. No file I/O.

| Test | What it verifies |
|------|----------------|
| percentile p50 | `[1,2,3,4,5]` → p50 = 3 |
| percentile p95/p99 | 100-element list → correct nearest-rank indices |
| percentile single element | All percentiles = that value |
| percentile empty | Returns 0.0, no exception |
| normalize path integer | `/walker/user/123` → `/walker/user/{id}` |
| normalize path uuid | UUID segments replaced with `{id}` |
| normalize path unchanged | `/walker/search` unchanged |
| total count never drops | `total_count` tracks all appends; deque bounded at `maxlen` |
| error breakdown http | HTTP 500 → `{"500": 1}` in `error_breakdown` |
| error breakdown network | `error_type="TIMEOUT"` → `{"TIMEOUT": 1}` |
| success rate calculation | 9 success + 1 failure → `success_rate_pct = 90.0` |
| occurrence labels | `MetricsCollector` stores and retrieves per-endpoint labels |

### `tests/unit/test_topology.jac` (18 tests)

All tests use inline config dicts. File-based tests use `tests/fixtures/microservice.toml`.

| Test | What it verifies |
|------|----------------|
| monolith routes all to url | Every path → single `--url` value |
| services map json parsed | `--services-map '{"svc":"http://a:1"}'` builds routing table |
| longest prefix wins | `/walker/order/create` matches `/walker/order` not `/walker` |
| no match routes to gateway | Unmatched path → `--url` (gateway fallback) |
| jac toml discovery | `microservice.toml` + `JAC_SV_*_URL` env vars → routing table |
| services map overrides toml | `--services-map` wins when both present |
| missing toml and no services map | Clear `ValueError` |
| service label on result | Routed request has `service` set to matching service name |

### `tests/unit/test_config.jac` (11 tests)

| Test | What it verifies |
|------|----------------|
| parse duration seconds/minutes/hours | `parse_duration()` conversions |
| cli overrides toml | CLI `vus=10` wins over toml `vus=50` |
| toml overrides defaults | Toml `vus=50` wins over built-in default `1` |
| toml login path override | Toml `login_path` wins over default `/user/login` |
| missing toml uses defaults | No toml → all built-in defaults applied |
| load toml defaults swallows exceptions | Exception in `get_scale_config` → returns `{}` |

### `tests/unit/test_process_runner.jac` (9 tests)

Pure logic tests for `_compute_slices()` VU distribution.

---

## Integration Tests

All integration tests use `aiohttp.test_utils.TestServer` — a real HTTP server running in-process. Async test bodies are wrapped in `async def _run() { ... }` called via `asyncio.run(_run())`.

### `tests/integration/test_engine.jac` (2 tests)

| Test | What it verifies |
|------|----------------|
| service labels in results | `RequestResult.service` populated from topology |
| multi-server routing | Requests routed to two different `TestServer` instances by path prefix |

### `tests/integration/test_auth.jac` (6 tests)

Uses a fake `/user/login` handler returning jac-scale's response shape:
```json
{"ok": true, "data": {"token": "test-jwt-token"}}
```

| Test | What it verifies |
|------|----------------|
| login success token extracted | Token → `Authorization: Bearer test-jwt-token` on next request |
| login non-2xx records auth error | 401 → VU exits with auth error in metrics |
| no credentials no auth header | No `--username`/`--password` → no `Authorization` sent |
| cookie jar persists | `Set-Cookie` from login included in second request |
| login entry not replayed | `is_login=True` entries not sent during load phase |

### `tests/integration/test_reporter.jac` (21 tests)

Uses `RequestResult` and `EndpointStats` objects built directly (no engine needed).

| Test | What it verifies |
|------|----------------|
| json output schema | `meta`, `summary`, `endpoints` top-level keys present |
| json endpoint fields complete | `p50_ms`, `p95_ms`, `p99_ms`, `error_breakdown`, latency ratings |
| json to file with report_out | JSON written to file; no stdout |
| html contains inline chartjs | `<script>` with Chart.js inline; no external CDN `src=` |
| html self-contained | No external `<script src=` or `<link href=` |
| html contains metric values | p95 and success rate values appear in HTML |
| console output not empty | `render_console()` produces non-empty output |

---

## What We Do NOT Test

| Skipped | Reason |
|---------|--------|
| Rich console rendering pixel accuracy | Test data structure and routing, not visual layout |
| aiohttp internals | Framework responsibility |
| jac-scale server behavior | jac-scale has its own test suite |
| HTML visual appearance | Assert on key content strings, not full DOM |
| HAR files > 1 MB | Performance characteristic, not correctness regression |
| > 50 VUs in CI tests | 5-VU tests cover correctness; high-VU is a performance question |

---

## CI Run Order

```bash
jac test tests/unit/        # fast, no network — run first, fail fast
jac test tests/integration/ # in-process aiohttp servers — run second
```

Both must pass before any phase is considered complete.
