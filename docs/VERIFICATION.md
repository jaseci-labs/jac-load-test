# jac-loadtest Verification Checklists

Phase-by-phase verification that goes beyond pytest. Each phase has two sections:

- **Automated** — run these commands; all must pass before the phase is considered done.
- **Manual** — run these against a real server and verify the described output with your own eyes. These cover UX, error messages, edge cases, and runtime behaviour that unit tests cannot prove.

Mark each item `[x]` as you verify it.

---

## Phase 0 — Foundation

### Automated

```bash
pip install -e .
jac loadtest --help
```

- [x] `pip install -e .` exits 0 with no errors
- [x] `jac loadtest --help` prints usage and all flag descriptions
- [x] No `ImportError` or `ModuleNotFoundError` on import

### Manual

- [x] `jac loadtest --help` output lists every flag (`--url`, `--vus`, `--duration`, `--timeout`, etc.)
- [x] Running `jac loadtest` with no arguments prints a usage error, not a traceback

---

## Phase 1 — MVP (HAR replay + console report)

### Automated

```bash
pytest -m unit -v
```

- [x] All 31 unit tests pass (15 har_parser + 16 metrics)
- [x] No warnings about unknown markers or import errors in pytest output

### Manual

**Happy path**

- [x] `jac loadtest <har> --url http://localhost:8000 --vus 1 --duration 10s`
  - Console table prints with columns: Endpoint, Reqs, OK%, p50, p95, p99, RPS, Errs
  - Footer line shows `Duration: 10s   VUs: 1   Ramp-up: 0s   Mode: monolith`
  - All output goes to stderr (stdout is empty)

- [x] `jac loadtest <har> --url http://localhost:8000 --vus 10 --duration 30s`
  - Table shows aggregated TOTAL row below a section divider
  - RPS is meaningfully higher than the 1-VU run

- [x] `jac loadtest <har> --url http://localhost:8000 --vus 10 --ramp-up 5s --duration 30s`
  - Run completes without error
  - Footer shows `Ramp-up: 5s`

**Graceful shutdown**

- [ ] Start a long run (`--duration 300s`) and press Ctrl+C once
  - VUs finish their current HAR replay and stop
  - Partial report still prints (table + footer)
  - Process exits cleanly (no traceback)

- [ ] Press Ctrl+C a second time during the same run (before the first takes effect)
  - Process exits immediately with code 130
  - No report prints (killed mid-run)

**Error handling — config errors (exit code 2)**

- [x] `jac loadtest <har>` (missing `--url`)
  - Prints `Error: --url is required` to stderr
  - Exits with code 2

- [x] `jac loadtest nonexistent.har --url http://localhost:8000`
  - Prints a file-not-found error to stderr
  - Exits with code 2

- [ ] `jac loadtest <har_with_only_static> --url http://localhost:8000` (HAR has only image/css/font entries)
  - Prints `Error: no API entries found in HAR file after filtering`
  - Exits with code 2

- [ ] Same HAR with `--include-static` added
  - Run proceeds and table includes the static entries

**Error handling — network errors**

- [ ] `jac loadtest <har> --url http://localhost:19999` (nothing listening on that port)
  - Run completes (does not crash)
  - Table shows `Errs` count > 0 and `OK%` < 100
  - `CONNECTION_REFUSED` visible in error breakdown (or Errs column non-zero)

- [ ] `jac loadtest <har> --url http://localhost:8000 --timeout 1ms` (timeout too short)
  - Run completes
  - Table shows TIMEOUT errors

**HAR version warning**

- [ ] Create a HAR file with `"version": "1.3"` in the `log` object and run against it
  - Warning prints to stderr: `HAR version '1.3' is not tested with this tool`
  - Parsing continues and table still prints (does not crash)

- [ ] Run with a normal HAR 1.2 file
  - No version warning appears in stderr

**HAR security warning**

- [ ] Run with a HAR file that contains `Authorization` or `Cookie` request headers
  - Warning prints to stderr about sensitive headers
  - Run still proceeds and table prints

---

## Phase 2 — Auth + Think Time

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
```

- [x] All unit tests pass — har_parser + metrics + config suites
- [x] All integration tests pass — auth suite (`tests/integration/test_auth.py`)
- [x] Total: 54 tests passing across unit + integration suites

### Manual

**Three-layer config resolution**

- [x] Create a `jac.toml` in cwd with `[plugins.scale.loadtest]` section (e.g. `vus = 5`, `duration = "10s"`)
  - Run without `--vus` or `--duration` flags
  - Footer shows `VUs: 5` and `Duration: 10s` (jac.toml values applied)

- [x] Pass `--vus 20` explicitly alongside a jac.toml with `vus = 5`
  - Footer shows `VUs: 20` (CLI wins over jac.toml)

- [x] Run with no jac.toml present
  - Built-in defaults apply (`VUs: 1`, `Duration: 30s`) — no error

**Actual vs configured duration**

- [x] Run with `--duration 30s` against a fast server (test completes in ~8s)
  - Footer shows the actual elapsed wall-clock time (e.g. `Duration: 8s`), not the configured cap

**Shared credentials**

- [ ] `jac loadtest <har> --url http://... --username testuser --password testpass --vus 5 --duration 15s`
  - All VUs authenticate successfully (each gets its own JWT, all from the same credential)
  - `OK%` is 100 for authenticated endpoints (no 401s)

**Per-VU credentials file**

- [ ] `jac loadtest <har> --url http://... --credentials-file creds.csv --vus 5 --duration 15s`
  - Each VU uses a different row from the CSV (VU 0 → row 0, VU 1 → row 1, etc.)
  - No auth errors in report

- [ ] Run with fewer CSV rows than VUs (e.g. 2 rows, 5 VUs)
  - VUs 0 and 1 use rows 0 and 1; VUs 2, 3, 4 wrap around to rows 0, 1, 0
  - Run completes without error (wrap-around is by design, not an error)

- [ ] Run with a credentials file that has no valid rows (empty or header-only)
  - Prints `ValueError: No credentials found in '<path>'` to stderr
  - Exits with code 2

**Think time**

- [ ] `--think-time none` (default): RPS is at maximum; VUs replay HAR entries back-to-back
- [ ] `--think-time real`: RPS is noticeably lower; sleep between requests matches HAR `timings.wait`
- [ ] `--think-time real --think-time-scale 0.5`: RPS is between `none` and full-real (half think time)
- [ ] `--think-time real --think-time-scale 2.0`: RPS is lower than full-real (double think time)

**Ramp-up**

- [ ] `--ramp-up 10s --vus 10`: first requests arrive at t=0, last VU starts near t=10s
  - Visible as a gradual RPS increase if you watch stderr during run

---

## Phase 3 — Microservice Mode

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
```

- [x] All unit tests pass (including `tests/unit/test_topology.py`) — 89 unit tests total
- [x] All integration tests pass (including `tests/integration/test_engine.py` topology tests) — 14 integration tests total
- [x] Total: 103 tests passing across unit + integration suites

### Manual

> **Routing verification without a real jac-scale app**
> Use `scripts/mock_service.py` to spin up two minimal HTTP servers that log every
> request they receive. This lets you confirm routing is correct without needing jac-scale running.
>
> ```bash
> # Terminal 1 — handles /walker/* requests
> python scripts/mock_service.py builder_sv 18001
>
> # Terminal 2 — handles /user/* requests
> python scripts/mock_service.py gateway 18002
>
> # Terminal 3 — run the load test
> jac loadtest <har> --mode microservice \
>   --services-map '{"/walker":"http://localhost:18001","/user":"http://localhost:18002"}' \
>   --vus 1 --iterations 1
> ```
>
> Check that `/walker/*` paths appear only in Terminal 1 and `/user/*` paths only in Terminal 2.
> The mock verifies routing only — not auth or actual jac walker behaviour.

**`--services-map` mode**

- [x] `jac loadtest <har> --mode microservice --services-map '{"/api/products":"http://localhost:18643","/api/orders":"http://localhost:18882","/api/cart":"http://localhost:18397"}' --vus 5 --duration 30s`
  - Table shows a "Service" column (first column, before Endpoint)
  - Separate rows appear per service; service names match keys without leading slash (`api/products`, not `/api/products`)
  - Endpoint column shows original HAR path (`/api/products/function/list_products`), not the internal service path
  - Footer shows `Mode: microservice`
  - Verified against k8s_e2e fixture — 100% OK, real latency breakdown visible

- [ ] Same command with two walker paths routed to the same service
  - Both path rows show the same service name in the Service column

**jacBuilder pattern (path-prefix keys starting with `/`)**

- [ ] `jac loadtest <har> --mode microservice --url https://gateway:8000 --services-map '{"/walker/ai_chat":"http://jac-coder:18002","/walker":"http://builder:18001"}' --vus 5 --duration 15s`
  - `/walker/ai_chat` requests route to `jac-coder:18002` (longest prefix wins)
  - Other `/walker/...` requests route to `builder:18001`
  - `/user/login` falls through to gateway (`--url`) — service label `gateway`

**jac.toml auto-discovery**

- [x] Run from k8s_e2e fixture directory with `JAC_SV_*_URL` env vars set:
  - `jac loadtest <har> --mode microservice --url http://localhost:8000 --vus 5 --duration 30s`
  - Routes discovered from `jac.toml`; service names and latency breakdown match per-service reality
  - Note: env vars must be set in the same terminal as the load test (jac-scale sets them in its own process)

**Error paths (exit code 2)**

- [ ] `--mode microservice` with no `--services-map` and no `jac.toml`
  - Error message mentions both `--services-map` and `jac.toml`
  - Exits with code 2

- [ ] `--mode microservice` with jac.toml routes but missing `JAC_SV_*_URL` env vars
  - Error message lists the specific missing env var name(s)
  - Exits with code 2

- [ ] `--mode microservice --username u --password p` without `--url`
  - Error mentions `--url` required for authentication gateway
  - Exits with code 2

- [ ] `--mode microservice --services-map '{not json}'`
  - Error mentions invalid JSON
  - Exits with code 2

**Monolith mode unchanged**

- [ ] `--mode monolith --url http://localhost:8000` (or default, no `--mode`)
  - No "Service" column in output table
  - `--url` still required; missing `--url` → error, exit 2
  - Footer shows `Mode: monolith`

**Auth in microservice mode**

- [ ] `jac loadtest <har> --mode microservice --services-map '...' --url http://gateway:8000 --username u --password p --vus 5 --duration 15s`
  - Auth request (`POST /user/login`) goes to gateway (`--url`)
  - Subsequent walker requests go to individual services
  - No 401 errors in report (assuming valid credentials)

---

## Phase 4 — Production Hardening

> Fill in after Phase 4 is implemented.

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
```

- [ ] All unit tests pass
- [ ] All integration tests pass (`tests/integration/test_engine.py`)

### Manual

**Exit codes**

- [ ] Successful run with all thresholds passing → exit code 0
- [ ] `--fail-on-error-rate 1` with an error rate above 1% → exit code 1
- [ ] `--fail-on-p95 100` with p95 above 100ms → exit code 1
- [ ] Bad config (missing `--url`) → exit code 2

**Threshold flags**

- [ ] `--fail-on-p95 <value_below_actual_p95>`: run completes, exits 1, table still prints
- [ ] `--abort-on-fail --fail-on-error-rate 0`: stops test immediately on first error, partial report prints
- [ ] `--threshold-start-delay 10s`: errors in first 10s do not trigger threshold; errors after 10s do

**RPS cap**

- [ ] `--rps 10 --vus 10`: actual RPS in table is at or below 10 regardless of VU count

**Network error classification**

- [ ] Dead server → `CONNECTION_REFUSED` in error breakdown
- [ ] `--timeout 1ms` → `TIMEOUT` in error breakdown

---

## Phase 5 — Reporting + Polish

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
pytest -m e2e -v
```

- [x] All unit tests pass
- [x] All integration tests pass — includes `tests/integration/test_reporter.py` (22 tests covering JSON schema, HTML structure, file routing, console stderr)
- [x] Total: 149 tests passing across unit + integration suites
- [ ] e2e tests pass (`tests/e2e/test_smoke.py` — not yet written)

### Manual

**JSON report — stdout**

- [ ] `jac loadtest <har> --url http://... --report-format json`
  - Valid JSON printed to stdout
  - stderr shows nothing (no console table — JSON format replaces console output)
  - JSON has four top-level keys: `meta`, `endpoints`, `summary`, `timeseries`
  - `endpoints` array contains per-endpoint rows with `min_ms`, `max_ms`, `mean_ms`, `p50_ms`, `p95_ms`, `p99_ms`, `error_breakdown`
  - `summary` contains aggregated totals across all endpoints
  - `timeseries` is an empty array for short runs (< 10s); contains 10s-interval snapshots for longer runs

- [ ] `jac loadtest <har> --url http://... --report-format json --report-out report.json`
  - `report.json` created with valid JSON
  - Nothing printed to stdout

**HTML report**

- [ ] `jac loadtest <har> --url http://... --report-format html --report-out report.html`
  - `report.html` created; stderr prints `HTML report written to report.html`
  - Open in browser (internet required — Chart.js loaded from CDN)
  - Six summary cards visible: Total Requests, Success Rate, p50/p95/p99, Avg RPS
  - For runs ≥ 10s: latency-over-time and RPS-over-time line charts render
  - For runs < 10s: "No time-series data collected" message shown instead of line charts
  - Per-endpoint latency bar chart (p50/p95/p99 grouped) renders for all run lengths
  - Endpoint table shows TOTAL footer row

- [ ] `jac loadtest <har> --url http://... --report-format html` (missing `--report-out`)
  - Prints `Error: --report-out <path> is required for --report-format html` to stderr
  - Exits with code 2

**Debug flag**

- [ ] `--debug`: each request prints method, URL, status, and latency to stderr during run
- [ ] Without `--debug`: no per-request lines appear

**Live progress**

- [ ] During a 30s run, a Rich progress bar updates on stderr showing elapsed time and request count

---

## Phase 6 — Package + Release

> Fill in before publishing to PyPI.

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
pytest -m e2e -v
python -m build --wheel
pip install dist/jac_loadtest-*.whl
jac loadtest --help
```

- [ ] All test suites pass on a clean Python 3.12 environment
- [ ] Wheel builds without errors
- [ ] Installing the wheel (not editable) and running `jac loadtest --help` works

### Manual

- [ ] `pip install jac-loadtest` from PyPI and `jac loadtest --help` works on a machine with no prior install
- [ ] Full end-to-end: HAR capture from Chrome → `jac loadtest` → console report with accurate numbers
- [ ] Auth end-to-end: register test user, run with `--username`/`--password`, verify 0 auth errors
