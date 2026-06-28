# jac loadtest — Command Reference

```
jac loadtest <har_file> [options]
```

Settings are resolved in three layers — the **Use in** column shows where each flag can be configured:

```
CLI flag (--vus 50)          ← always wins
  ↓ if not passed
jac.toml ([plugins.scale.loadtest])  ← project/team default
  ↓ if not present
Built-in default             ← shown in the Default column below
```

Flags marked **CLI only** are never read from `jac.toml` — they change per environment or contain sensitive credentials.

---

## Positional

| Argument | Required | Description |
|----------|----------|-------------|
| `har_file` | Yes | Path to the `.har` file exported from Chrome DevTools or any traffic recorder. |

---

## Load Shape

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--url` | — (required in monolith mode) | URL string, e.g. `http://localhost:8000` | CLI only | Target base URL. Replaces the origin recorded in the HAR; path and query string are preserved. Changes per environment so not suitable for `jac.toml`. |
| `--mode` | `monolith` | `monolith` \| `microservice` | CLI + jac.toml | Deployment topology. `monolith` routes all requests to `--url`. `microservice` reads service prefix→URL routing from `jac.toml` and sends each request directly to its service. |
| `--vus` | `1` | Positive integer, e.g. `50` | CLI + jac.toml | Number of virtual users (concurrent coroutines). Each VU replays the full HAR sequence independently. Practical ceiling is ~200–500 VUs per worker. |
| `--workers` | CPU count | Positive integer, e.g. `4` | CLI + jac.toml | Number of worker processes. Each worker runs its own asyncio event loop on a separate OS thread, bypassing the GIL. Capped automatically at `--vus` so no idle processes are spawned. Use `1` for single-process mode. |
| `--duration` | `30s` | Time string: `30s`, `2m`, `1h` | CLI + jac.toml | Used as the fallback display duration in reports when actual elapsed time is unavailable. Does not control when VUs stop — use `--iterations` to cap run length. In normal CLI use, the actual wall-clock elapsed time always takes precedence over this value in the report. |
| `--iterations` | `1` | Positive integer, e.g. `100` | CLI + jac.toml | Stop each VU after N complete HAR replays. Defaults to `1` (one full HAR replay per VU). The actual wall-clock time is measured and shown in the report regardless of this value. |
| `--ramp-up` | `0s` | Time string: `10s`, `1m` | CLI + jac.toml | Stagger VU startup over this duration. With `--vus 50 --ramp-up 10s`, VU 1 starts at t=0s, VU 50 starts at t=9.8s. Prevents thundering herd at test start. |
| `--rps` | `0` (unlimited) | Non-negative integer, e.g. `100` | CLI + jac.toml | Global requests-per-second cap across all VUs combined. `0` means no cap. Implemented as a per-VU inter-request sleep of `vus/rps` seconds, which distributes the cap evenly. |

---

## Request Behavior

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--timeout` | `30s` | Time string: `10s`, `1m` | CLI + jac.toml | Per-request timeout. Requests that exceed this are recorded as `TIMEOUT` errors with `status=0` and `latency_ms` equal to the timeout value. |
| `--think-time` | `none` | `none` \| `real` \| `scaled` | CLI + jac.toml | Inter-request delay between HAR entries. `none` = no delay (maximum stress). `real` = wait the recorded `timings.wait` ms. `scaled` = same as `real` but multiplied by `--think-time-scale` (useful to run faster or slower than recorded). |
| `--think-time-scale` | `1.0` | Float, e.g. `0.5`, `2.0` | CLI + jac.toml | Multiplier applied to recorded think times when `--think-time real`. Values below `1.0` speed up pacing; values above `1.0` slow it down. |
| `--include-static` | `false` | Boolean flag (no value) | CLI + jac.toml | By default, image/*, font/*, text/css, and JS bundle entries in the HAR are skipped. Pass this flag to replay everything including static assets. |
| `--csrf` | `false` | Boolean flag (no value) | CLI + jac.toml | Enable CSRF token detection and injection. After login, scans `Set-Cookie` for `csrftoken` or `_csrf` and injects `X-CSRFToken` on all non-GET requests. Not needed for standard jac-scale apps (which use JWT). |

---

## Authentication

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--username` | — | String | CLI only | Username for shared-credential auth. All VUs log in with this identity and get separate JWT tokens. **Security-sensitive — never put in jac.toml.** |
| `--password` | — | String | CLI only | Password paired with `--username`. **Security-sensitive — never put in jac.toml.** |
| `--credentials-file` | — | File path, e.g. `creds.csv` | CLI only | CSV file with `username,password` rows, one per VU. VU `i` gets row `i`; wraps around if fewer rows than VUs. Enables per-VU user identity. **Security-sensitive — never commit this file.** |
| `--login-path` | `/user/login` | URL path string | CLI + jac.toml | Path used to detect the login entry in the HAR. This entry is handled by the auth module and not replayed directly. |

---

## Microservice Mode

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--services-map` | — | JSON string, e.g. `'{"svc":"http://host:port"}'` | CLI only | Explicit service name → URL mapping. Bypasses `jac.toml` auto-discovery entirely. Required when running in `--mode microservice` without a `jac.toml` in the current directory (e.g. CI, remote hosts). Environment-specific — CLI only. |

---

## CI Thresholds

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--fail-on-error-rate` | — (disabled) | Float (percent), e.g. `1.0` | CLI + jac.toml | Exit with code `1` if the overall error rate exceeds N percent. `1.0` means "fail if more than 1% of requests return non-2xx or network errors". Printed to stderr as `THRESHOLD FAILED: error_rate X% > limit N%`. |
| `--fail-on-p95` | — (disabled) | Float (milliseconds), e.g. `500` | CLI + jac.toml | Exit with code `1` if the global p95 latency across all requests exceeds N milliseconds. |
| `--fail-on-p99` | — (disabled) | Float (milliseconds), e.g. `1000` | CLI + jac.toml | Exit with code `1` if the global p99 latency across all requests exceeds N milliseconds. |
| `--abort-on-fail` | `false` | Boolean flag (no value) | CLI + jac.toml | Stop the test immediately when any threshold is first breached, rather than waiting for all iterations. A partial report is generated from data collected so far. |
| `--threshold-start-delay` | `0s` | Time string: `30s`, `1m` | CLI + jac.toml | Defer threshold evaluation until N seconds into the run. Metrics are collected from t=0 and appear in the report — only the pass/fail check is delayed. Useful to skip cold-start latency spikes. |

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | Test completed; all thresholds passed (or none configured) |
| `1` | One or more thresholds failed |
| `2` | Tool or config error (bad HAR, missing required flag, auth failure, invalid flag value) |

---

## Output

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--report-format` | `console` | `console` \| `json` \| `html` | CLI + jac.toml | Output format. `console` prints a Rich table to stderr. `json` writes machine-readable output to stdout (or `--report-out`). `html` writes a self-contained HTML file with charts — requires `--report-out`. |
| `--report-out` | — | File path, e.g. `results.html` | CLI only | Output file path for `json` or `html` reports. Output path changes per run — CLI only. |
| `--max-samples` | `1000000` | Positive integer | CLI + jac.toml | Maximum raw request records kept in memory for percentile calculation. Oldest records are dropped when this limit is reached. `1,000,000` is sufficient for most runs under several hours. |
| `--debug` | `false` | Boolean flag (no value) | CLI only | Print one line per request to stderr: `[VU NNN] /endpoint  STATUS  latency_ms ms`. Useful for verifying replay is hitting the right endpoints. Do not use in CI — output is very verbose with many VUs. |

---

## jac.toml Example

Settings appropriate for team-wide defaults can be committed in `jac.toml`. CLI flags always override these.

```toml
[plugins.scale.loadtest]
# Load shape
vus                   = 20
workers               = 4          # worker processes (default: CPU core count)
duration              = "60s"
ramp_up               = "10s"
timeout               = "30s"
mode                  = "monolith"

# Traffic
think_time            = "none"
rps                   = 0          # 0 = unlimited
include_static        = false

# Auth
login_path            = "/user/login"

# CI thresholds (team SLOs)
fail_on_error_rate    = 1.0        # percent
fail_on_p95           = 500        # ms
fail_on_p99           = 1000       # ms
threshold_start_delay = "30s"

# Output
report_format         = "console"
max_samples           = 1000000
```

**Flags intentionally excluded from jac.toml** (CLI only):

| Flag | Reason |
|------|--------|
| `har_file` | Positional arg, different every run |
| `--url` | Changes between dev / staging / prod |
| `--username` / `--password` | Security-sensitive — never commit |
| `--credentials-file` | Security-sensitive — never commit |
| `--services-map` | Environment-specific URL overrides |
| `--report-out` | Output path changes per run |
| `--debug` | Too noisy for committed defaults |

---

## Quick Examples

```bash
# Minimal: 1 VU, 30s
jac loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up
jac loadtest recording.har --url http://localhost:8000 \
  --vus 50 --ramp-up 10s --duration 60s

# Per-VU credentials
jac loadtest recording.har --url http://localhost:8000 \
  --vus 20 --credentials-file creds.csv

# Realistic pacing from recorded think times
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --think-time real

# Microservice mode (reads routing from jac.toml)
jac loadtest recording.har --mode microservice --vus 30 --duration 60s

# Microservice mode with explicit service URLs (no jac.toml needed)
jac loadtest recording.har --mode microservice \
  --services-map '{"order_service":"http://order.svc:8001","inventory_service":"http://inv.svc:8002"}' \
  --vus 30 --duration 60s

# CI gate: fail if p95 > 500ms or error rate > 1%
jac loadtest recording.har --url http://staging:8000 \
  --vus 10 --duration 30s \
  --fail-on-p95 500 --fail-on-error-rate 1 --threshold-start-delay 10s

# HTML report
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 30s --report-format html --report-out results.html

# JSON report
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 30s --report-format json --report-out results.json
```
