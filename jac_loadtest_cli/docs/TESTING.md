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
# All tests (174 total, 16 parallel workers by default)
jac test tests/

# Unit tests only
jac test tests/unit/

# Integration tests only
jac test tests/integration/

# E2E tests only (headless.jac end-to-end, full-pipeline smoke tests)
jac test tests/e2e/

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
    test_metrics.jac     # 24 tests
    test_topology.jac    # 18 tests
    test_config.jac      # 16 tests
    test_process_runner.jac  # 13 tests
  integration/
    test_engine.jac      # 13 tests — VU lifecycle against in-process aiohttp server
    test_auth.jac        # 6 tests — login flow + JWT injection
    test_reporter.jac    # 25 tests — JSON/HTML/console output validation
  e2e/
    test_headless.jac    # 7 tests — run_test_headless() driven synchronously, as a
                          #   non-async embedder (the sv walker) would call it
    test_smoke.jac       # 5 tests — full pipeline (parse → run → stats → report)
                          #   against a real in-process aiohttp server
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

### `tests/unit/test_metrics.jac` (24 tests)

All tests use `RequestResult` objects built inline. No file I/O.

| Test | What it verifies |
|------|----------------|
| percentile p50 | `[1,2,3,4,5]` → p50 = 3 |
| percentile p95/p99 | 100-element list → correct nearest-rank indices |
| percentile single element | All percentiles = that value |
| percentile empty | Returns 0.0, no exception |
| normalize path integer | `/walker/user/123` → `/walker/user/{id}` |
| normalize path uuid (with/without hyphens) | UUID segments replaced with `{id}` |
| normalize path unchanged | `/walker/search` unchanged |
| normalize path multiple ids | Multiple `{id}` segments normalized in one path |
| total count never drops | `total_count` tracks all appends; deque bounded at `maxlen` |
| generate timeseries produces snapshots | `generate_timeseries()` bins samples into `StatsSnapshot`s |
| error breakdown http | HTTP 500 → `{"500": 1}` in `error_breakdown` |
| error breakdown network | `error_type="TIMEOUT"` → `{"TIMEOUT": 1}` |
| success rate calculation | 9 success + 1 failure → `success_rate_pct = 90.0` |
| error breakdown occurrence labels | Repeated/aggregated/differently-numbered occurrence labels across VUs |
| ttfb_ms defaults / averages / zero-when-empty | `ttfb_ms` on `RequestResult` and `EndpointStats` (see TTFB below) |

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

### `tests/unit/test_config.jac` (16 tests)

| Test | What it verifies |
|------|----------------|
| parse duration seconds/minutes/hours | `parse_duration()` conversions |
| cli overrides toml | CLI `vus=10` wins over toml `vus=50` |
| cli overrides defaults | CLI value wins over built-in default when no toml present |
| toml overrides defaults | Toml `vus=50` wins over built-in default `1` |
| toml login path override | Toml `login_path` wins over default `/user/login` |
| missing toml uses defaults | No toml → all built-in defaults applied |
| load toml defaults swallows exceptions | Exception in `get_scale_config` → returns `{}` |
| cli only fields not from toml | CLI-only fields (e.g. `--url`) are never read from `jac.toml` |
| iterations defaults to one | `iterations` built-in default is `1` |
| `from_dict` — empty dict uses built-in defaults | `LoadTestConfig.from_dict({})` == all `BUILT_IN_DEFAULTS` |
| `from_dict` — applies provided overrides | Keys present in the dict override defaults |
| `from_dict` — explicit null falls back to default | `{"vus": None}` resolves to the built-in default, not `None` |
| `from_dict` — ignores unknown keys | Extra dict keys are silently dropped, no error |
| `from_dict` — never touches toml or argparse | Confirms the web-app entry point has zero CLI-context dependency |

### `tests/unit/test_process_runner.jac` (13 tests)

Pure logic tests for `_compute_slices()` VU distribution (6 tests: exact division,
remainder, contiguous offsets, full VU coverage, capped-at-VUs, single worker), merge
logic (5 tests: merging raw samples/VU-id uniqueness/error-breakdown aggregation
across workers, plus `_merge_snapshots()` combining totals/RPS/weighted percentiles
and its empty-list edge case), and `_worker_fn()` (2 tests: always reports `"ok"` on
completion, streams `worker_snapshot` messages when streaming is enabled).

---

## Integration Tests

All integration tests use `aiohttp.test_utils.TestServer` — a real HTTP server running in-process. Async test bodies are wrapped in `async def _run() { ... }` called via `asyncio.run(_run())`.

### `tests/integration/test_engine.jac` (13 tests)

| Test | What it verifies |
|------|----------------|
| microservice service label in metrics | `RequestResult.service` populated from topology |
| microservice routes to different service urls | Requests routed to two different `TestServer` instances by path prefix |
| iterations cap stops after exact N iterations | VU stops replaying after `--iterations` full HAR cycles |
| timeout error type recorded for slow server | Slow response past `--timeout` → `TIMEOUT` error type |
| connection refused error type recorded | Unreachable server → connection-refused error type |
| rps cap slows request rate | `--rps` cap measurably paces requests via inter-request sleep |
| think_time scaled applies time scaling | `--think-time scaled` multiplies recorded `timings.wait` by `--think-time-scale` |
| debug mode does not affect request count | `--debug` only adds stderr logging, doesn't change replay behavior |
| abort_on_fail stops test early when error threshold breached | `--abort-on-fail` + `--fail-on-error-rate` stop VUs mid-run on breach |
| ttfb_ms recorded separately from total latency for streaming response | TTFB via `aiohttp.TraceConfig` differs from full `latency_ms` |
| ttfb_ms falls back to latency_ms on timeout | No TTFB trace event fired → `ttfb_ms` defaults to `latency_ms` |
| stream_metrics_callback invoked periodically with cumulative StatsSnapshot | `on_snapshot`/`stream_metrics_callback` fires on the streaming interval |
| stream_metrics_callback none is a no-op | Omitting the callback doesn't error or change behavior |

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

### `tests/integration/test_reporter.jac` (25 tests)

Uses `RequestResult` and `EndpointStats` objects built directly (no engine needed).

| Test | What it verifies |
|------|----------------|
| json output schema | `meta`, `summary`, `endpoints` top-level keys present |
| json endpoint fields complete | `p50_ms`, `p95_ms`, `p99_ms`, `error_breakdown`, latency ratings |
| json ttfb_ms per endpoint and summary | `ttfb_ms` present in both per-endpoint and summary JSON |
| json summary aggregates multiple endpoints | Global summary correctly combines several endpoints' stats |
| json timeseries empty/populated | `timeseries` key reflects whether snapshots were passed |
| json to file with report_out | JSON written to file; no stdout |
| html contains inline chartjs | `<script>` with Chart.js inline; no external CDN `src=` |
| html self-contained | No external `<script src=` or `<link href=` |
| html contains metric values | p95 and success rate values appear in HTML |
| html shows ttfb summary card | Avg TTFB summary card rendered in HTML |
| html embeds timeseries / endpoint data | Chart datasets embedded as inline JSON, not fetched |
| html no data message when no snapshots | Empty timeseries → "no data" placeholder instead of an empty chart |
| html microservice mode shows service column | Service column only rendered when `config.mode == "microservice"` |
| console output not empty / microservice mode / empty stats does not crash | `render_console()` robustness across configs |
| render_json and render_html produce no console output / do not mutate sys.argv | Report renderers stay side-effect-free for embedder use (see headless.jac) |

---

## E2E Tests

Both e2e files spin up a real `aiohttp.web` server (via `aiohttp.test_utils` or a
background thread, per file) and drive the full pipeline end-to-end — parse → run →
compute stats → render report.

### `tests/e2e/test_headless.jac` (7 tests)

Exercises `headless.jac`'s `run_test_headless()` — the same shape a non-async
embedder (the sv walker) would call it: synchronous, calling `asyncio.run()`
internally, so it cannot run from inside an already-running event loop. These tests
run the target aiohttp server on its own event loop in a background thread and call
`run_test_headless()` directly from the main thread.

| Test | What it verifies |
|------|----------------|
| run_test_headless returns a JSON-serialisable dict | Return value matches `json.loads(render_json(...))` shape |
| run_test_headless calls on_snapshot during the run | Streaming callback fires with `StatsSnapshot` objects |
| run_test_headless produces no stdout and no sys.exit | No CLI-shaped side effects — safe for an embedder |
| run_test_headless writes no files | All I/O is the caller's responsibility |
| run_test_headless raises ValueError when url missing in monolith mode | Same validation as `cli.jac`, but as a raised exception instead of `sys.exit(2)` |
| run_test_headless raises ValueError when har_file missing | Same |
| run_test_headless propagates FileNotFoundError for missing har file | HAR parse errors propagate instead of being caught and printed |

### `tests/e2e/test_smoke.jac` (5 tests)

Full-pipeline smoke tests — not headless-specific, exercises the same
parse→engine→metrics→report path `cli.jac` uses.

| Test | What it verifies |
|------|----------------|
| smoke: full pipeline produces valid json report | End-to-end run against a real server yields a well-formed JSON report |
| smoke: apdex is 1.0 when all requests satisfy threshold | Apdex scoring correctness on an all-fast-response server |
| smoke: per-endpoint rps populated when duration provided | `rps` field is non-zero when `actual_duration_s` is passed |
| smoke: render_console runs without error after full pipeline | Console renderer doesn't crash on real (not hand-built) `EndpointStats` |
| smoke: p999 >= p99 for all endpoints | Percentile ordering invariant holds on real data |

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
jac test tests/e2e/         # full-pipeline + headless.jac end-to-end — run last
```

All three must pass before any phase is considered complete.
