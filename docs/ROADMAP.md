# jac-loadtest Roadmap

HAR-based load testing tool for jac-scale applications.
Two-stage delivery: standalone PyPI package first, then native jac-scale plugin.

The command is `jac loadtest` from day one. The standalone `jac-loadtest` PyPI package
registers itself as a `jac` subcommand via `[project.entry-points."jac"]` — the same
mechanism jac-scale uses. Stage 2 moves the code into jac-scale; the command name never changes.

---

## Stage 1 — Standalone PyPI Package (`jac-loadtest`)

### Phase 0 — Foundation ✓
> Repo skeleton and import tree wired before any logic is written.

- [x] Create `jac_loadtest/` package with `core/`, `bridge/`, `output/` layout
- [x] Write `pyproject.toml` with exact pins `jaclang==0.15.2`, `jac-scale==0.2.16`, `rich>=13.0.0`
- [x] Add `plugin.py` — module-level `@registry.command(...)` on a plain function; entry-point points directly to the function
- [x] Register plugin via `[project.entry-points."jac"]` in `pyproject.toml` — same mechanism as jac-scale
- [x] Register `JacMetaImporter` at top of `cli.py` before any jac_scale imports
- [x] Add empty module stubs so the full import tree resolves from day one
- [x] Confirm `jac loadtest --help` runs without error

**Exit criterion:** `jac loadtest --help` prints usage. ✓

**Notes from implementation:**
- `Arg.create()` is the correct factory (not `Arg(...)`); uses `typ=` not `type=`; `typ=bool` for boolean flags (no `ArgKind.FLAG` needed)
- `Arg.create()` auto-generates a short flag from the first letter of the name — all args use `short=""` to disable this since 25+ args produce many first-letter conflicts
- `setuptools.backends.legacy:build` requires setuptools ≥ 70.1; use `setuptools.build_meta` for broad compatibility
- Command registration must happen at module import time via a module-level decorator; the entry-point can point directly to the registered function — no marker class needed for a standalone new command (a `JacCmd` class with `@hookimpl create_cmd` is only needed when extending *existing* jac commands)

---

### Phase 1 — MVP (HAR replay + console report)
> First working end-to-end path. No auth, no microservices.

- [ ] `core/har_parser.py` — parse HAR 1.2, filter non-API entries (skip image/font/css), URL rewrite
- [ ] `core/engine.py` — asyncio VU coroutines, duration cap, `aiohttp.ClientSession` with timeout
- [ ] `core/metrics.py` — `RequestResult` dataclass, latency collection, p50/p95/p99 calc
- [ ] `output/reporter.py` — Rich console table (per-endpoint rows + overall summary footer)
- [ ] `config.py` — `LoadTestConfig` dataclass with built-in defaults (no jac.toml yet)
- [ ] Wire `--url`, `--vus`, `--duration`, `--timeout` flags in `cli.py`
- [ ] End-to-end smoke test against a local HTTP server

**Exit criterion:** `jac loadtest recording.har --url http://localhost:8000 --vus 10 --duration 30s` completes and prints a summary table.

---

### Phase 2 — Auth + Think Time
> VUs log in independently and replay sessions realistically.

- [ ] `bridge/auth.py` — detect login entry (`POST /user/login`), JWT injection into subsequent requests
- [ ] Per-VU credentials: `--credentials-file credentials.csv` (one `username,password` row per VU)
- [ ] Shared credentials fallback: `--username` / `--password` (all VUs share one token)
- [ ] Per-VU cookie jar maintained across request sequence
- [ ] Think time in `engine.py`: `--think-time none|real` (`real` = replay `timings.wait` from HAR)
- [ ] Ramp-up in `engine.py`: `--ramp-up Ns` staggers VU startup
- [ ] Config three-layer resolution in `config.py`: jac.toml `[plugins.scale.loadtest]` → CLI flags → built-in defaults
- [ ] `--login-path` override flag (default `/user/login`)

**Exit criterion:** `jac loadtest recording.har --url http://... --vus 10 --credentials-file creds.csv` runs with 0 auth errors in report.

---

### Phase 3 — Microservice Mode
> Route requests to the correct service process, report per-service breakdown.

- [ ] `bridge/topology.py` — build prefix→URL routing table using jac-scale `ServiceRegistry`
- [ ] Longest-prefix matching (mirrors jac-scale gateway routing algorithm)
- [ ] `--mode microservice` flag
- [ ] `--services-map '{"svc":"http://host:port"}'` explicit JSON override
- [ ] Auto-discovery from `./jac.toml` `[plugins.scale.microservices]` when no `--services-map`
- [ ] Per-service `RequestResult.service` field populated
- [ ] Per-service metrics breakdown in console reporter
- [ ] Per-service column in JSON report

**Exit criterion:** `jac loadtest recording.har --mode microservice --services-map '{...}' --vus 10 --duration 30s` reports per-service latency and error rates.

---

### Phase 4 — Production Hardening
> Reliable under pressure: clean shutdown, CI-compatible exit codes, network error classification.

- [ ] Graceful shutdown — two-signal model: first `Ctrl+C` sets `asyncio.Event(stop_requested)`, VUs finish current iteration then exit and generate report; second `Ctrl+C` kills immediately
- [ ] Exit codes: `0` = completed + all thresholds pass, `1` = threshold failed, `2` = config/tool error
- [ ] Threshold flags: `--fail-on-error-rate N`, `--fail-on-p95 N`, `--fail-on-p99 N`
- [ ] `--abort-on-fail` — stop test immediately when any threshold is first breached
- [ ] `--threshold-start-delay Ns` — delay pass/fail evaluation (cold-start protection); metrics still collected from t=0
- [ ] RPS cap: `--rps N` via token bucket (`asyncio.Semaphore`)
- [ ] `error_type` on `RequestResult`: `None` | `"TIMEOUT"` | `"CONNECTION_REFUSED"` | `"DNS_ERROR"` | `"SSL_ERROR"`
- [ ] `error_breakdown` in `EndpointStats`: `{"500": 3, "TIMEOUT": 2}`
- [ ] Endpoint normalization: `normalize_path()` replaces UUID/integer segments with `{id}`
- [ ] HAR security warning: scan for `Authorization`/`Cookie` headers at startup, warn to stderr
- [ ] Three-layer metrics storage: `total_count` int (RPS) + `deque(maxlen=N)` (percentiles) + `list[StatsSnapshot]` every 5s (time-series)
- [ ] `--max-samples N` flag to bound deque size

**Exit criterion:** interrupted test at minute 9 of 10 still generates a partial report. CI pipeline `if [ $? -ne 0 ]` correctly detects threshold failures.

---

### Phase 5 — Reporting + Polish
> Machine-readable output for CI, charts for humans.

- [ ] `StatsSnapshot` written every 5s during run (p50/p95/p99, RPS, error_rate per interval)
- [ ] Live progress bar during run using Rich `Progress` → stderr
- [ ] JSON report: `--report-format json` → stdout (stderr stays human-only)
- [ ] HTML report: `--report-format html` → file; self-contained with Chart.js RPS-over-time and latency charts
- [ ] `--report-out path` flag for JSON/HTML destination
- [ ] `--debug` flag: per-request lines to stderr
- [ ] `--include-static` flag: include image/font/css entries in replay

**Exit criterion:** `jac loadtest ... --report-format html --report-out report.html` produces a self-contained HTML file with charts.

---

### Phase 6 — Package + Release
> Ready for PyPI and supervisor review.

- [ ] Unit tests: `tests/test_har_parser.py`, `tests/test_metrics.py`, `tests/test_topology.py`
- [ ] Integration test: local jac-scale app + HAR capture → `jac loadtest` end-to-end
- [ ] Auth integration test: register test user, run with `--username`/`--password`, verify 0 auth errors
- [ ] `README.md` with install instructions and usage examples
- [ ] `DESIGN.md` finalized (rationale behind key decisions)
- [ ] `pyproject.toml` polished: classifiers, description, license, version
- [ ] Publish to PyPI as `jac-loadtest`

**Exit criterion:** `pip install jac-loadtest && jac loadtest --help` works from PyPI.

---

## Stage 2 — jac-scale Integration (`jac-scale[loadtest]`)

### Phase 7 — Native jac-scale Plugin
> Code moves into jac-scale. The command `jac loadtest` stays the same.

- [ ] Move `jac_loadtest/core/` and `jac_loadtest/output/` into `jac-scale/jac_scale/loadtest/`
- [ ] Move `bridge/auth.py` + `bridge/topology.py` to native jac-scale internals; swap HTTP auth call for in-process `UserManager`; swap disk read for in-memory `ServiceRegistry`
- [ ] Register `jac loadtest` in `jac-scale/jac_scale/plugin.jac` using `@registry.command("loadtest", ...)` (replacing the standalone `plugin.py` entry point)
- [ ] Add `[plugins.scale.loadtest]` schema block to `JacScalePluginConfig.get_config_schema()`
- [ ] Deprecate or thin-wrap the `jac-loadtest` standalone PyPI package
- [ ] Update `jaseci/docs/docs/reference/plugins/jac-scale.md` with `## Load Testing` section

**Exit criterion:** `pip install jac-scale` (no `jac-loadtest`) and `jac loadtest` still works end-to-end.

---

### Phase 8 — Jac Rewrite (future)
> CLI and config modules ported to Jac for full language consistency.

- [ ] Rewrite `cli.py` and `config.py` as `.jac` modules
- [ ] Use `JacRuntime` for walker execution where applicable
- [ ] `cli.py` becomes `plugin.jac` entry point
- [ ] Validate no Python interop regressions

**Exit criterion:** tool runs entirely as Jac source with no Python shim in the critical path.

---

## Milestone Summary

| Milestone | Phase | Key Deliverable |
|-----------|-------|-----------------|
| M1 — CLI boots | 0 | `jac loadtest --help` works (via entry-points) |
| M2 — First load test | 1 | HAR replay with console report |
| M3 — Authenticated tests | 2 | Per-VU JWT injection, credentials file |
| M4 — Microservice support | 3 | Per-service routing and breakdown |
| M5 — Production-grade | 4 | Graceful shutdown, thresholds, exit codes |
| M6 — Full reporting | 5 | JSON + HTML reports with charts |
| M7 — PyPI release | 6 | `pip install jac-loadtest && jac loadtest --help` |
| M8 — jac-scale native | 7 | Code moves into jac-scale; command unchanged |
| M9 — Full Jac rewrite | 8 | No Python shim |
