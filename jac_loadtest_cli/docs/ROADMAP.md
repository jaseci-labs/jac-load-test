# jac-loadtest Roadmap

HAR-based load testing tool for jac-scale applications.
Two-stage delivery: standalone Jac package first, then native jac-scale plugin.

The command is `jac loadtest` from day one. The standalone `jac-loadtest-cli` package
registers itself as a `jac` subcommand via `[entrypoints.jac]` in `jac.toml` — the same
mechanism jac-scale uses. Stage 2 moves the code into jac-scale; the command name never changes.

---

## Stage 1 — Standalone Jac Package (`jac-loadtest-cli`)

### Phase 0 — Foundation ✓
> Repo skeleton and import tree wired before any logic is written.

- [x] Create `jac_loadtest_cli/` package with `core/`, `bridge/`, `output/` layout (in Jac)
- [x] Write `jac.toml` with dependencies `jac-scale>=0.2.16`, `aiohttp>=3.9.0`, `rich>=13.0.0`
- [x] Add `plugin.jac` — module-level `@registry.command(...)` on a plain function; entry-point points directly to the function
- [x] Register plugin via `[entrypoints.jac]` in `jac.toml` — same mechanism as jac-scale
- [x] Add empty module stubs so the full import tree resolves from day one
- [x] Confirm `jac loadtest --help` runs without error
- [x] Add `[optional-dependencies.test]` and `[tool.pytest.ini_options]` to `pyproject.toml`
- [x] Create `tests/` directory with `conftest.py` (`make_har()` + `fake_server()` fixtures)

**Exit criterion:** `jac loadtest --help` prints usage. ✓

**Notes from implementation:**
- `Arg.create()` auto-generates a short flag from the first letter of the name — all args use `short=""` to disable this since 25+ args produce many first-letter conflicts
- Command registration must happen at module import time via a module-level decorator; the entry-point can point directly to the registered function — no marker class needed for a standalone new command
- `plugin.jac` handler must use `**kwargs` signature — jaclang's `run_handler` calls `spec.handler(**filtered_args)`; a positional `args` param receives nothing. Use `types.SimpleNamespace(**kwargs)` to bridge into `from_args()`

---

### Phase 1 — MVP (HAR replay + console report) ✓
> First working end-to-end path. No auth, no microservices.

- [x] `core/har_parser.jac` — parse HAR 1.2, filter non-API entries (skip image/font/css), URL rewrite
- [x] `core/engine.jac` — asyncio VU coroutines, duration cap, `aiohttp.ClientSession` with timeout
- [x] `core/metrics.jac` — `RequestResult` dataclass, latency collection, p50/p95/p99 calc
- [x] `output/reporter.jac` — Rich console table (per-endpoint rows + overall summary footer)
- [x] `config.jac` — `LoadTestConfig` dataclass + `parse_duration()` helper (s/m/h only)
- [x] Wire `--url`, `--vus`, `--duration`, `--timeout` flags in `cli.py`
- [x] `tests/unit/test_har_parser.py` — MIME filter, URL rewrite, header sanitization, login detection, security warning, HAR 1.1 compat (15 tests)
- [x] `tests/unit/test_metrics.py` — percentile math, path normalization, three-layer storage, error breakdown (16 tests)
- [x] `tests/fixtures/minimal.har` + `tests/fixtures/mixed_static.har`
- [x] HAR version check — warn to stderr for untested versions; HAR 1.1 and 1.2 are the supported set; documented in `README.md`
- [x] GitHub Actions CI — `.github/workflows/test.yml` runs `pytest -m unit` on every PR open and merge to main; integration and e2e job placeholders commented in for Phase 2 and Phase 5

**Exit criterion:** `jac loadtest recording.har --url http://localhost:8000 --vus 10 --duration 30s` completes and prints a summary table. `pytest -m unit` passes. ✓

**Notes from implementation:**
- Several Phase 4 items were pulled forward and implemented here: `error_type`/`error_breakdown` on results, `normalize_path()`, three-layer metrics storage, and HAR security warning — see Phase 4 for the remaining hardening work
- CI job ordering enforces: unit → integration → e2e via `needs:` — heavier tests only run if lighter ones pass

---

### Phase 2 — Auth + Think Time ✓
> VUs log in independently and replay sessions realistically.

- [x] `bridge/auth.jac` — detect login entry (`POST /user/login`), JWT injection into subsequent requests; identity type inferred (`email` vs `username`) from credential value
- [x] Per-VU credentials: `--credentials-file credentials.csv` (one `username,password` row per VU; wrap-around when fewer rows than VUs)
- [x] Shared credentials fallback: `--username` / `--password` (all VUs use the same credential, each gets their own token)
- [x] Per-VU cookie jar maintained across request sequence (aiohttp `ClientSession` handles this automatically)
- [x] Think time in `engine.py`: `--think-time none|real` with `--think-time-scale` multiplier; `scaled` mode noted as separate from `real`
- [x] Ramp-up in `engine.py`: `--ramp-up Ns` staggers VU startup; VU i starts at `(i / vus) * ramp_up_s`
- [x] Config three-layer resolution in `config.py`: CLI flags → jac.toml `[plugins.scale.loadtest]` → built-in defaults; all toml-resolvable CLI args use `default=None` in `plugin.py` so argparse defaults can't mask jac.toml values
- [x] `reset_scale_config()` called before `get_scale_config(project_dir=Path.cwd())` to avoid singleton staleness from plugin startup
- [x] `--login-path` override flag (default `/user/login`)
- [x] `--iterations` moved to three-layer resolution (CLI + jac.toml)
- [x] `tests/integration/test_auth.py` — 8 tests: login flow, JWT injection, credentials file assignment, wrap-around, cookie jar, login entry skip, no-credentials path
- [x] `tests/unit/test_config.py` — 11 tests: three-layer resolution, CLI wins, missing toml fallback, `parse_duration`

**Exit criterion:** `jac loadtest recording.har --url http://... --vus 10 --credentials-file creds.csv` runs with 0 auth errors in report. `pytest -m "unit or integration"` passes — 54 tests. ✓

**Notes from implementation:**
- `plugin.py` arg defaults must be `None` for all toml-resolvable fields; built-in defaults live only in `BUILT_IN_DEFAULTS` in `config.py` — never duplicated in argparse defaults
- `--think-time real` applies `think_time_scale` multiplier (default 1.0 = exact HAR timings); the `scaled` value is a distinct mode reserved for Phase 4/5 polish where scale < 1 speeds up pacing and > 1 slows it down
- Think time sleep is outside the latency measurement — only server response time is timed

---

### Phase 3 — Microservice Mode ✓
> Route requests to the correct service process, report per-service breakdown.

- [x] `bridge/topology.jac` — `TopologyRouter` and `ServiceRoute` dataclass; longest-prefix routing that mirrors jac-scale `ServiceRegistry.match_route()` exactly
- [x] Longest-prefix matching: `path == prefix OR path.startswith(prefix + "/")` — correctly rejects `/walker` matching `/walker-admin`
- [x] `--mode microservice` flag
- [x] `--services-map '{"svc":"http://host:port"}'` explicit JSON override; keys starting with `/` used as path prefixes directly (jacBuilder pattern)
- [x] Auto-discovery from `./jac.toml` `[plugins.scale.microservices.routes]` + `JAC_SV_*_URL` env vars when no `--services-map`
- [x] Fallback to `--url` (gateway) for unmatched paths; `service` label = `"gateway"`
- [x] `core/har_parser.py` — `target_url` made optional; microservice mode keeps recorded URLs, topology handles routing
- [x] Per-service `RequestResult.service` field populated from `topology.resolve()`
- [x] Per-service "Service" column in console reporter (microservice mode only)
- [x] `tests/unit/test_topology.py` — 20 unit tests: monolith routing, services-map JSON, longest-prefix wins, false-match prevention, jac.toml discovery, missing env var error, fallback, jacBuilder path-prefix key pattern
- [x] `tests/integration/test_engine.py` — 2 microservice-mode tests: service label in metrics, routing to different server URLs verified with real in-process aiohttp servers
- [x] `tests/fixtures/microservice.toml` — fixture jac.toml with `[plugins.scale.microservices.routes]`

**Exit criterion:** `jac loadtest recording.har --mode microservice --services-map '{...}' --vus 10 --duration 30s` reports per-service latency and error rates. `pytest -m unit` passes. ✓

**Notes from implementation:**
- `_load_toml_routes()` is a module-level function (not a method) so tests can monkeypatch it without importing `jac_scale` — critical for unit test isolation
- jacBuilder's `jac.toml` routes (`/api/builder_sv`) do NOT match HAR paths (`/walker/...`) — this is the "gateway abstraction" pattern; use `--services-map` with `/`-starting keys for that app
- Microservice mode is only useful locally or inside a cluster; from outside production, monolith mode through the gateway is the correct choice
- `--services-map` keys without leading `/` get `"/" + key` prepended as prefix; keys with leading `/` are used as-is; leading slash is stripped from the display name in the report

**Bug fixes discovered during real-world verification (k8s_e2e fixture):**
- **Prefix stripping in `resolve()`**: jac-scale gateway strips the route prefix before forwarding to the service (e.g. `/api/products/function/list` → `/function/list`). Without this, services return 405. The tool now replicates this stripping.
- **`normalize_path()` returned full URL**: was returning `http://host/path` instead of `/path`. Fixed to strip origin so endpoint labels are consistent across both modes.
- **Font files not filtered**: Chrome records font files with `_resourceType="font"` but `mimeType="application/octet-stream"`. Added `"font"` to `_SKIP_RESOURCE_TYPES` to catch them regardless of MIME.
- **Engine crash on unrouted entries**: entries that slip through the filter with no matching topology route now warn once per path and skip, instead of crashing the entire test with a traceback.

---

### Phase 4 — Production Hardening
> Reliable under pressure: clean shutdown, CI-compatible exit codes, network error classification.

- [x] Graceful shutdown — two-signal model: first `Ctrl+C` sets `asyncio.Event(stop_requested)`, VUs finish current iteration then exit and generate report; second `Ctrl+C` kills immediately *(implemented in Phase 1)*
- [ ] Exit codes: `0` = completed + all thresholds pass, `1` = threshold failed, `2` = config/tool error — **flags are parsed and stored in `LoadTestConfig` but enforcement logic is not yet wired in `cli.py`; currently all runs exit `0` unless a config error triggers `sys.exit(2)`**
- [ ] Threshold flags: `--fail-on-error-rate N`, `--fail-on-p95 N`, `--fail-on-p99 N` — **parsed, not yet enforced**
- [ ] `--abort-on-fail` — stop test immediately when any threshold is first breached — **parsed, not yet enforced**
- [ ] `--threshold-start-delay Ns` — delay pass/fail evaluation (cold-start protection); metrics still collected from t=0 — **parsed, not yet enforced**
- [ ] RPS cap: `--rps N` via token bucket (`asyncio.Semaphore`) — **`config.rps` is stored but the token-bucket check does not exist in `engine.py`; the flag is accepted but has no effect**
- [ ] `--think-time scaled` — currently `engine.py` only checks `config.think_time == "real"`; passing `--think-time scaled` behaves identically to `none` (no delay); needs its own branch so `scaled` can be used without `real` semantics
- [x] `error_type` on `RequestResult`: `None` | `"TIMEOUT"` | `"CONNECTION_REFUSED"` | `"DNS_ERROR"` | `"SSL_ERROR"` | `"SERVER_DISCONNECTED"` | `"CONNECTION_RESET"` — all catch blocks implemented in `engine.py`
- [x] `error_breakdown` in `EndpointStats`: `{"500": 3, "TIMEOUT": 2}` *(implemented in Phase 1)*
- [x] Endpoint normalization: `normalize_path()` replaces UUID/integer segments with `{id}` *(implemented in Phase 1)*
- [x] HAR security warning: scan for `Authorization`/`Cookie` headers at startup, warn to stderr *(implemented in Phase 1)*
- [x] Three-layer metrics storage: `total_count` int (RPS) + `deque(maxlen=N)` (percentiles) + `list[StatsSnapshot]` every 10s (time-series) *(implemented in Phase 1)*
- [x] `--max-samples N` flag to bound deque size *(implemented in Phase 1)*
- [x] Multi-process VU distribution: `--workers N` flag + `core/process_runner.py` — splits VUs evenly across N worker processes (each with its own asyncio loop), authenticates all credentials once in the main process before spawning workers, merges samples from all workers into a single `MetricsCollector`; worker count capped at VU count; uses `spawn` context for asyncio compatibility
- [ ] `tests/integration/test_engine.py` — VU lifecycle, duration/iteration caps, ramp-up stagger, graceful shutdown, RPS cap, TIMEOUT/CONNECTION_REFUSED error types, per-VU session isolation

**Exit criterion:** interrupted test at minute 9 of 10 still generates a partial report. CI pipeline `if [ $? -ne 0 ]` correctly detects threshold failures. `pytest -m integration` passes.

---

### Phase 5 — Reporting + Polish
> Machine-readable output for CI, charts for humans.

- [x] `StatsSnapshot` written every 10s during run (p50/p95/p99, RPS, error_rate per interval)
- [x] Live progress bar during run using Rich `Progress` → stderr
- [x] JSON report: `--report-format json` → stdout or `--report-out` file; stderr stays human-only
- [x] HTML report: `--report-format html --report-out <path>` → self-contained file with Chart.js RPS-over-time, latency-over-time, and per-endpoint latency bar charts
- [x] `--report-out path` flag for JSON/HTML destination (CLI only — already wired in plugin.py and config.py)
- [ ] `--debug` flag: per-request lines to stderr — **`config.debug` is stored but never read in `engine.py` or `cli.py`; has no effect yet**
- [x] `--include-static` flag: include image/font/css entries in replay
- [x] `tests/integration/test_reporter.py` — JSON schema (22 tests), stdout/file routing, HTML self-contained, console to stderr
- [ ] `tests/e2e/test_smoke.py` — full pipeline: HAR → engine → JSON report, exit code 0, total request count correct

**Missing metrics (not yet tracked or reported):**
- [ ] **p99.9 latency** — add to `MetricsCollector.compute_endpoint_stats`, `EndpointStats`, and all three report formats; exposes tail outliers that p99 misses under high concurrency
- [ ] **Per-endpoint RPS** — currently only global RPS is derived (`total_count / duration`); needs per-endpoint `sample_count / actual_duration_s` computed in `compute_endpoint_stats()` and exposed in console table and JSON `endpoints[]`
- [ ] **`bytes_received` in console output** — `RequestResult.bytes_received` is tracked and present in JSON, but the Rich console table omits it; add a Bandwidth column to `render_console()` showing total KB transferred per endpoint
- [ ] **Apdex score** — satisfaction index computed as `(satisfied + 0.5 × tolerating) / total` where satisfied = latency ≤ T, tolerating = T < latency ≤ 4T; requires a configurable threshold `--apdex-t N` (ms); expose per-endpoint and in summary
- [ ] **TTFB breakdown** — separate Time To First Byte from total request latency; `HarEntry.think_time_ms` already captures `timings.wait` from the HAR recording but it is only used for think-time pacing; recording it as a second metric during live replay requires injecting the TTFB measurement point in `_send_request()` using `aiohttp`'s trace API
- [ ] **Per-endpoint timeout override** — `--timeout` applies globally; no way to set a longer timeout for known slow endpoints (e.g. file upload) while keeping a tight timeout for health-check endpoints

**Notes from implementation:**
- `render_json()` returns a JSON string; `cli.py` routes it to stdout (default) or a file when `--report-out` is set
- `render_html()` requires `--report-out`; exits with code 2 if omitted; prints "HTML report written to <path>" to stderr
- HTML charts use Chart.js from CDN (requires network access when opening the report)
- Timeseries data is generated post-run by `MetricsCollector.generate_timeseries(t_start)` in `cli.py`, which bins all collected `RequestResult` samples into 10-second buckets; there is no in-run snapshot loop
- Timeseries charts display a "No time-series data collected" message when the run is shorter than 10 seconds (no complete bucket exists)

**Exit criterion:** `jac loadtest ... --report-format html --report-out report.html` produces a self-contained HTML file with charts. `pytest -m e2e` passes.

---

### Phase 5b — Distributed Load Generation (Future)
> Overcome single-machine network/CPU limits by coordinating load across multiple machines.

Single-machine `--workers` splits VUs across local CPU cores. Distributed mode sends load from **different machines**, multiplying the achievable RPS ceiling beyond what one NIC or one CPU cluster can generate — the same problem JMeter solves with its Remote Testing feature.

**Architecture:**

```
[Controller machine]
  jac loadtest --worker-nodes host1:7070,host2:7070 recording.har ...
        │
        │  POST /start  (config + serialised HAR entries)
        ▼
 [Worker node 1]          [Worker node 2]
 jac loadtest worker      jac loadtest worker
 --port 7070              --port 7070
 runs run_multiprocess()  runs run_multiprocess()
        │                       │
        │  GET /results         │
        └───────────┬───────────┘
                    ▼
           Controller merges MetricsCollector
           samples and renders final report
```

**Planned items:**
- [ ] `jac loadtest worker --port N` — start a lightweight `aiohttp` HTTP server that accepts a `POST /start` job (config JSON + HAR entries) and runs `run_multiprocess()` locally; returns `GET /results` as a list of `RequestResult` dicts on completion
- [ ] Controller-side `--worker-nodes host:port,...` flag — instead of spawning local processes, POST the serialised config + HAR to each node, wait for all to complete, GET results, and merge into a single `MetricsCollector`
- [ ] VU distribution across nodes — split total `--vus` evenly across nodes (matching `_compute_slices()` logic); each node receives its `vu_id_offset` so VU IDs are globally unique
- [ ] Pre-authentication on controller — same `_pre_authenticate_all()` pattern; controller sends per-VU token slices to each worker so no auth burst happens at the nodes
- [ ] Worker health check before test start — `GET /health` on each node; abort with clear error if any node is unreachable
- [ ] Result streaming (optional) — workers can push `StatsSnapshot` updates to controller via a long-poll or WebSocket; enables live per-node progress during the run

**Key difference from `--workers`:**

| | `--workers N` | `--worker-nodes` |
|---|---|---|
| Processes run on | Same machine | Different machines |
| Bottleneck overcome | GIL / single event loop | Single NIC + CPU ceiling |
| Communication | `multiprocessing.Queue` (IPC) | HTTP over LAN/cluster |
| Typical scale | 4–16 cores | 10–100+ machines |

**Exit criterion:** `jac loadtest recording.har --url http://target --vus 1000 --worker-nodes node1:7070,node2:7070` distributes 500 VUs to each node, merges results, and reports aggregate latency and RPS as a single test run.

---

### Phase 6 — Package + Release
> Ready for PyPI and supervisor review.

- [ ] All `pytest -m unit`, `pytest -m integration`, `pytest -m e2e` must pass cleanly
- [ ] Integration test: local jac-scale app + HAR capture → `jac loadtest` end-to-end (manual verification)
- [ ] Auth integration test: register test user, run with `--username`/`--password`, verify 0 auth errors (manual verification)
- [ ] `README.md` with install instructions and usage examples
- [ ] `jac.toml` polished: classifiers, description, license, version
- [ ] Publish to PyPI as `jac-loadtest-cli` via `jac bundle && twine upload dist/*`

**Exit criterion:** `jac install jac-loadtest-cli && jac loadtest --help` works from PyPI.

---

## Stage 2 — jac-scale Integration (`jac-scale[loadtest]`)

### Phase 7 — Native jac-scale Plugin
> Code moves into jac-scale. The command `jac loadtest` stays the same.

- [ ] Move `jac_loadtest_cli/core/` and `jac_loadtest_cli/output/` into `jac-scale/jac_scale/loadtest/`
- [ ] Move `bridge/auth.jac` + `bridge/topology.jac` to native jac-scale internals; swap HTTP auth call for in-process `UserManager`; swap disk read for in-memory `ServiceRegistry`
- [ ] Register `jac loadtest` in `jac-scale/jac_scale/plugin.jac` using `@registry.command("loadtest", ...)` (replacing the standalone `plugin.jac` entry point)
- [ ] Add `[plugins.scale.loadtest]` schema block to `JacScalePluginConfig.get_config_schema()`
- [ ] Deprecate or thin-wrap the `jac-loadtest-cli` standalone package
- [ ] Update `jaseci/docs/docs/reference/plugins/jac-scale.md` with `## Load Testing` section

**Exit criterion:** `jac install jac-scale` (no `jac-loadtest-cli`) and `jac loadtest` still works end-to-end.

---

## Milestone Summary

| Milestone | Phase | Key Deliverable |
|-----------|-------|-----------------|
| M1 — CLI boots | 0 | `jac loadtest --help` works (via entry-points) |
| M2 — First load test | 1 | HAR replay with console report |
| M3 — Authenticated tests | 2 | Per-VU JWT injection, credentials file |
| M4 — Microservice support | 3 | Per-service routing and breakdown |
| M5 — Production-grade | 4 | Graceful shutdown, thresholds, exit codes, RPS cap |
| M6 — Full reporting | 5 | JSON + HTML reports, p99.9, per-endpoint RPS, bytes, Apdex |
| M7 — Distributed mode | 5b | Multi-machine load generation via `--worker-nodes` |
| M8 — PyPI release | 6 | `jac install jac-loadtest-cli && jac loadtest --help` |
| M9 — jac-scale native | 7 | Code moves into jac-scale; command unchanged |
