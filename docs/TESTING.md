# jac-loadtest Testing Strategy

## Overview

Tests are written before (or alongside) each implementation phase — not added at the end. This document defines what to test, how to test it, and what tooling to use for every module in the architecture.

**Two core rules:**
1. `core/` unit tests never touch the network. They run against Python dicts and dataclasses only. They can run in CI with no jac-scale installed.
2. Integration tests use a real in-process `aiohttp` test server — never a live jac-scale app, never a subprocess.

---

## Test Tooling

| Tool | Purpose |
|------|---------|
| `pytest` | Test runner |
| `pytest-asyncio` | Async test support (`asyncio_mode = "auto"`) |
| `aiohttp.test_utils` | `TestServer` + `TestClient` — real in-process HTTP, no socket binding (already a transitive dep via jac-scale) |
| `pytest-mock` | `monkeypatch` for env vars; `mocker` for patching jac_scale imports in `bridge/` tests |

No `testcontainers`, no subprocess server spawning — everything in-process.

### jac.toml test dependencies

```toml
[optional-dependencies.test]
pytest = ">=8.0"
pytest-asyncio = ">=0.23"
pytest-mock = ">=3.12"
"aiohttp[speedups]" = ">=3.9.0,<4.0.0"
```

`pyproject.toml` also defines pytest configuration:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
markers = [
    "unit: pure logic, no network",
    "integration: in-process aiohttp test server",
    "e2e: full pipeline smoke test",
]
```

Install: `jac install -x test`

---

## Test Directory Layout

```
tests/
  conftest.py                    # shared fixtures: make_har(), fake_server()
  fixtures/
    minimal.har                  # 2-entry HAR: POST /user/login + POST /walker/search
    mixed_static.har             # HAR with image/png, text/css, font/woff2 entries
    microservice.toml            # jac.toml with [plugins.scale.microservices.routes]
  unit/
    test_har_parser.py
    test_metrics.py
    test_topology.py
    test_config.py
  integration/
    test_engine.py               # VU lifecycle against in-process aiohttp server
    test_auth.py                 # login flow + JWT injection
    test_reporter.py             # JSON/HTML output validation
  e2e/
    test_smoke.py                # full pipeline: HAR → engine → JSON report
```

---

## Fixture Strategy

### `make_har()` — HAR builder (conftest.py)

A Python function that returns a valid HAR dict with configurable entries. Used by all unit tests to avoid file I/O:

```python
def make_har(entries: list[dict] | None = None) -> dict:
    """Build a minimal valid HAR 1.2 dict."""
    default_entries = [
        {
            "request": {
                "method": "POST",
                "url": "http://recorded-host:8000/user/login",
                "headers": [],
                "postData": {"mimeType": "application/json", "text": '{"identity":{"type":"username","value":"u"},"credential":{"type":"password","password":"p"}}'},
                "queryString": [],
            },
            "response": {"status": 200, "content": {"mimeType": "application/json"}},
            "timings": {"send": 1, "wait": 50, "receive": 5},
        },
        {
            "request": {
                "method": "POST",
                "url": "http://recorded-host:8000/walker/search",
                "headers": [],
                "postData": {"mimeType": "application/json", "text": '{"query":"test"}'},
                "queryString": [],
            },
            "response": {"status": 200, "content": {"mimeType": "application/json"}},
            "timings": {"send": 1, "wait": 42, "receive": 8},
        },
    ]
    return {"log": {"version": "1.2", "entries": entries if entries is not None else default_entries}}
```

### `fake_server()` — aiohttp test server (conftest.py)

An `aiohttp.web.Application` fixture that returns 200 JSON by default. Integration tests override specific routes per-test:

```python
@pytest.fixture
async def fake_server(aiohttp_server):
    app = aiohttp.web.Application()
    app.router.add_route("*", "/{path_info:.*}", lambda r: aiohttp.web.json_response({"ok": True}))
    return await aiohttp_server(app)
```

### Fixture `.har` files

Used only for parser edge-case tests that need realistic file content:

- `minimal.har` — 2 entries: POST /user/login + POST /walker/search. Used for security warning tests (includes `Authorization` header in the recorded session).
- `mixed_static.har` — adds entries with `image/png`, `text/css`, `font/woff2` MIME types. Used for MIME filter tests.

### Fixture `microservice.toml`

For topology tests that exercise jac.toml-based auto-discovery. Uses the correct jac-scale format — routes are a flat `[plugins.scale.microservices.routes]` table; ports are NOT in `jac.toml` (they come from `JAC_SV_<MODULE>_URL` env vars set by jac-scale at service startup):

```toml
[plugins.scale.microservices]
enabled = true

[plugins.scale.microservices.routes]
order_service = "/walker/order"
inventory_service = "/walker/inventory"
```

Tests that use this fixture also patch env vars:
```python
monkeypatch.setenv("JAC_SV_ORDER_SERVICE_URL", "http://localhost:18001")
monkeypatch.setenv("JAC_SV_INVENTORY_SERVICE_URL", "http://localhost:18002")
```

---

## Unit Tests

### `tests/unit/test_har_parser.py`

All tests use `make_har()` or inline dicts. No file I/O, no network.

| Test | What it verifies |
|------|----------------|
| `test_parse_minimal` | Entry count matches HAR entries; `method`, `url`, `body`, `think_time_ms` fields populated |
| `test_mime_filter_default` | `image/png`, `text/css`, `font/woff2` entries dropped; `application/json` kept |
| `test_include_static_flag` | With `include_static=True`, static entries are kept |
| `test_url_rewriting_origin` | Scheme+host+port replaced; path and query string preserved exactly |
| `test_url_rewriting_port` | Port in `--url` correctly replaces recorded port |
| `test_header_sanitization` | `Authorization`, `Cookie`, `Host`, `Content-Length` stripped from replay headers |
| `test_login_detection_default` | `POST /user/login` entry has `is_login=True`; all others `is_login=False` |
| `test_login_detection_custom_path` | `login_path="/api/auth"` overrides default detection |
| `test_think_time_extraction` | `timings.wait` value stored in `HarEntry.think_time_ms` |
| `test_security_warning_emitted` | HAR with `Authorization` header → warning printed to stderr |
| `test_security_warning_suppressed` | HAR with no auth headers → no warning |
| `test_har_1_1_compat` | HAR without `ssl` timings field parses without error |
| `test_entry_order_preserved` | Output list order matches HAR `entries` array order |
| `test_empty_har` | HAR with zero entries returns empty list, no exception |
| `test_malformed_har_missing_log` | Missing `log` key raises `ValueError` with clear message |

### `tests/unit/test_metrics.py`

All tests use `RequestResult` dataclasses built inline.

| Test | What it verifies |
|------|----------------|
| `test_percentile_p50` | Known sorted list [1,2,3,4,5] → p50 = 3 |
| `test_percentile_p95_p99` | 100-element list → p95 and p99 at correct nearest-rank indices |
| `test_percentile_single_element` | Single-element list → all percentiles = that value |
| `test_percentile_empty` | Empty list returns 0.0, no exception |
| `test_normalize_path_integer` | `/walker/user/123` → `/walker/user/{id}` |
| `test_normalize_path_uuid_with_hyphens` | `/walker/order/550e8400-e29b-41d4-a716-446655440000` → `/walker/order/{id}` |
| `test_normalize_path_uuid_no_hyphens` | 32-char hex segment replaced with `{id}` |
| `test_normalize_path_unchanged` | `/walker/search` unchanged (no numeric/UUID segments) |
| `test_normalize_path_multiple_ids` | `/a/123/b/456` → `/a/{id}/b/{id}` |
| `test_total_count_never_drops` | Append 2M results → `total_count` = 2M; deque bounded at `maxlen` |
| `test_deque_bounded` | Appending past `maxlen` drops oldest; `total_count` stays accurate |
| `test_timeseries_generated_post_run` | `generate_timeseries(t_start)` bins samples into 10s buckets; returns one `StatsSnapshot` per bucket; empty list when no samples exist |
| `test_error_breakdown_http` | HTTP 500 response → `{"500": 1}` in `error_breakdown` |
| `test_error_breakdown_network` | `error_type="TIMEOUT"` → `{"TIMEOUT": 1}` in `error_breakdown` |
| `test_success_rate_calculation` | 9 success + 1 failure → `success_rate_pct = 90.0` |
| `test_error_type_http_vs_network` | 4xx/5xx: `error_type=None`; network failure: `error_type="TIMEOUT"` |

### `tests/unit/test_topology.py`

All tests use Python dicts for config. File-based tests use `tmp_path` + fixture `microservice.toml`.

| Test | What it verifies |
|------|----------------|
| `test_monolith_routes_all_to_url` | Every path → single `--url` value |
| `test_monolith_preserves_path_and_query` | Path and query string unchanged after routing |
| `test_services_map_json_parsed` | `--services-map '{"order_service":"http://a:1"}'` builds routing table without disk read |
| `test_longest_prefix_wins` | `/walker/order/create` matches `/walker/order` not `/walker` |
| `test_shorter_prefix_fallback` | Path `/walker/order/create` does not match prefix `/walker/inventory` |
| `test_no_match_routes_to_gateway` | Path with no matching prefix → `--url` (gateway fallback) |
| `test_jac_toml_discovery` | Fixture `microservice.toml` + patched `JAC_SV_*_URL` env vars → correct routing table |
| `test_services_map_overrides_toml` | `--services-map` wins when both `jac.toml` and JSON flag present |
| `test_missing_toml_and_no_services_map` | Clear `ValueError` listing what was tried |
| `test_service_label_on_result` | Routed request has `service` field set to matching service name |

### `tests/unit/test_config.py`

Uses `tmp_path` for jac.toml file tests.

| Test | What it verifies |
|------|----------------|
| `test_cli_wins_over_toml` | CLI `vus=50` overrides jac.toml `vus=20` |
| `test_toml_wins_over_defaults` | jac.toml `duration=60s` overrides built-in default `30s` |
| `test_built_in_defaults_applied` | No toml, no CLI flags → all built-in defaults present |
| `test_missing_toml_no_error` | No `jac.toml` in CWD → silently falls back to defaults |
| `test_none_cli_does_not_override_toml` | CLI `vus=None` does not overwrite toml `vus=20` |
| `test_security_flags_cli_only` | `--credentials-file`, `--url`, `--services-map`, `--report-out` absent from toml schema |

---

## Integration Tests

All integration tests use `aiohttp.test_utils.TestServer` — a real HTTP server running in-process with no socket binding. The server is created per-test via `aiohttp_server` fixture from `pytest-aiohttp`.

### `tests/integration/test_engine.py`

| Test | What it verifies |
|------|----------------|
| `test_single_vu_single_iteration` | 1 VU, `iterations=1`, 2 HAR entries → 2 `RequestResult` records |
| `test_multiple_vus_correct_total` | 5 VUs × 2 entries × 3 iterations = 30 total records |
| `test_iteration_cap_stops_engine` | Engine exits after each VU completes `iterations` replays; `--duration` does not stop VUs — only `--iterations` and stop signal do |
| `test_iteration_cap_stops_vu` | VU stops after `iterations=2`; does not start a third loop |
| `test_ramp_up_stagger` | With `--ramp-up 0.5s --vus 5`, first request timestamps span ≥ 0.5s range |
| `test_stop_requested_event` | Set `stop_requested` event mid-run → VUs finish current iteration then exit |
| `test_partial_report_after_shutdown` | Records from before `stop_requested` are in metrics; no data loss |
| `test_rps_cap_respected` | `--rps 5`, run for 2s → total requests ≤ 12 (allowing 20% variance) |
| `test_timeout_error_type` | Fake server sleeps past `--timeout` → `error_type="TIMEOUT"`, `status=0` |
| `test_connection_refused_error_type` | Port with nothing listening → `error_type="CONNECTION_REFUSED"` |
| `test_http_500_not_network_error` | Fake server returns 500 → `status=500`, `error_type=None` |
| `test_per_vu_cookie_isolation` | Cookie set for VU 0 is not present in VU 1's requests |
| `test_think_time_none` | `--think-time none` → no `asyncio.sleep` delays between requests |
| `test_think_time_real` | `--think-time real` → elapsed time per request ≥ `think_time_ms` from HAR |

### `tests/integration/test_auth.py`

Uses a fake server with explicit `/user/login` handler returning jac-scale's response shape:
```json
{"ok": true, "data": {"token": "test-jwt-token", "user_id": "...", "role": "user"}}
```

| Test | What it verifies |
|------|----------------|
| `test_login_success_token_extracted` | Fake `/user/login` returns token → `Authorization: Bearer test-jwt-token` on next request |
| `test_login_non_2xx_records_auth_error` | 401 from `/user/login` → VU exits with auth error in metrics |
| `test_shared_credentials_single_username` | All VUs call `/user/login` with same username; each gets its own token |
| `test_credentials_file_row_assignment` | VU 0 → row 0 creds; VU 1 → row 1 creds |
| `test_credentials_wrap_around` | 3 VUs, 2-row creds file → VU 2 wraps to row 0 |
| `test_no_credentials_no_auth_header` | No `--username` / `--credentials-file` → no `Authorization` header sent |
| `test_cookie_jar_persists_across_requests` | `Set-Cookie` from login response included in second request |
| `test_login_entry_not_replayed_as_load` | `is_login=True` entries are not sent again during the load phase |

### `tests/integration/test_reporter.py`

Uses `RequestResult` and `EndpointStats` objects built directly (no engine needed).

| Test | What it verifies |
|------|----------------|
| `test_json_output_schema` | Output contains `meta`, `summary`, `endpoints` top-level keys |
| `test_json_endpoint_fields_complete` | Each endpoint object has `p50_ms`, `p95_ms`, `p99_ms`, `completion_p50_s`, `completion_p95_s`, `completion_p99_s`, `error_breakdown`, latency ratings; note: per-endpoint `rps` is not present — only global `total_rps` in `meta` and `summary` |
| `test_json_to_stdout_without_report_out` | JSON written to stdout; stderr is empty |
| `test_json_to_file_with_report_out` | JSON written to `tmp_path/results.json`; stdout is empty |
| `test_html_contains_inline_chartjs` | HTML has `<script>` with Chart.js content; no `src=` to external CDN |
| `test_html_self_contained_no_external_links` | No `http://` or `https://` in `<script src=` or `<link href=` tags |
| `test_html_contains_metric_values` | HTML string contains the p95 and success rate from the input data |
| `test_console_table_goes_to_stderr` | `capsys.readouterr().out` is empty; `capsys.readouterr().err` contains table |

---

## End-to-End Smoke Test

### `tests/e2e/test_smoke.py`

One test that exercises the full pipeline in-process with no shortcuts:

```
make_har(entries=[login_entry, search_entry, get_users_entry])
  → HarParser (filter, URL rewrite)
  → TopologyRouter (monolith mode)
  → AuthProvider (no credentials)
  → LoadEngine (5 VUs, 3 iterations, duration=10s)
  → MetricsCollector (collect all RequestResults)
  → Reporter (JSON format)
```

**Assertions:**
- Exit code = 0
- JSON parseable and matches schema
- `total_requests` = 5 VUs × 3 iterations × 2 non-login entries = 30
- All requests have `status = 200` (fake server returns 200)
- `p95_ms > 0` (latency was measured)
- `error_breakdown` is empty
- `success_rate_pct = 100.0`

---

## What We Do NOT Test

| Skipped | Reason |
|---------|--------|
| Rich console rendering pixel accuracy | Test data structure and routing, not visual layout |
| aiohttp internals (connection pooling, redirect following) | Framework responsibility |
| jac-scale server behavior | jac-scale has its own test suite |
| HTML visual appearance | Assert on key content strings, not full DOM |
| HAR files > 1 MB | Performance characteristic, not correctness regression |
| > 50 VUs in CI tests | Covered by 5-VU tests for correctness; high-VU is a performance question |
| `--debug` per-request stderr output | Low-value, high-coupling test |

---

## CI Run Order

```bash
pytest -m unit         # fast, no async setup — run first, fail fast
pytest -m integration  # in-process aiohttp servers — run second
pytest -m e2e          # full pipeline — run last
```

All three must pass before any phase is considered complete.
