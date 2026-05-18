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

> Fill in after Phase 2 is implemented.

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
```

- [ ] All unit tests still pass
- [ ] All integration tests pass (`tests/integration/test_auth.py`)

### Manual

**Shared credentials**

- [ ] `jac loadtest <har> --url http://... --username testuser --password testpass --vus 5 --duration 15s`
  - All VUs authenticate successfully
  - `OK%` is 100 for authenticated endpoints (no 401s)

**Per-VU credentials file**

- [ ] `jac loadtest <har> --url http://... --credentials-file creds.csv --vus 5 --duration 15s`
  - Each VU uses a different row from the CSV
  - No auth errors in report

- [ ] Run with fewer CSV rows than VUs (e.g. 3 rows, 5 VUs)
  - Tool prints a clear error about insufficient credentials
  - Exits with code 2, does not start the test

**Think time**

- [ ] `--think-time none` (default): RPS is at maximum
- [ ] `--think-time real`: RPS is noticeably lower; inter-request delay matches HAR `timings.wait`
- [ ] `--think-time scaled --think-time-scale 0.5`: RPS is between `none` and `real`

**Ramp-up**

- [ ] `--ramp-up 10s --vus 10`: first requests arrive at t=0, last VU starts near t=10s
  - Visible as a gradual RPS increase if you watch stderr during run

---

## Phase 3 — Microservice Mode

> Fill in after Phase 3 is implemented.

### Automated

```bash
pytest -m unit -v
```

- [ ] All unit tests pass (including `tests/unit/test_topology.py`)

### Manual

- [ ] `jac loadtest <har> --mode microservice --services-map '{"walker":"http://host:8001","user":"http://host:8002"}' --vus 5 --duration 15s`
  - Table shows separate rows per service
  - Each row shows the correct service name

- [ ] Run with `--mode microservice` and no `--services-map` and no `jac.toml`
  - Clear error about missing service configuration
  - Exits with code 2

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

> Fill in after Phase 5 is implemented.

### Automated

```bash
pytest -m unit -v
pytest -m integration -v
pytest -m e2e -v
```

- [ ] All unit, integration, and e2e tests pass

### Manual

**JSON report**

- [ ] `jac loadtest <har> --url http://... --report-format json`
  - Valid JSON printed to stdout
  - stderr still shows the console table
  - JSON contains `endpoints` array with per-endpoint stats

- [ ] `jac loadtest <har> --url http://... --report-format json --report-out report.json`
  - `report.json` created with valid JSON
  - Nothing printed to stdout

**HTML report**

- [ ] `jac loadtest <har> --url http://... --report-format html --report-out report.html`
  - `report.html` is self-contained (open in browser with no internet required)
  - RPS-over-time and latency charts render correctly
  - File size is reasonable (< 2MB)

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
