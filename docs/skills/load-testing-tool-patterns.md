# Load Testing Tool Patterns

Research findings from k6 (grafana/k6) and Locust (locustio/locust).
Relevant for production-grade design decisions in jac-loadtest.

Sources:
- https://grafana.com/docs/k6/latest/using-k6/thresholds/
- https://github.com/grafana/k6/issues/2804
- https://docs.locust.io/en/stable/configuration.html

---

## Graceful Shutdown (k6 two-signal model)

k6 uses a two-signal SIGINT pattern — the best approach for load testing tools:

| Signal | Behaviour |
|--------|-----------|
| First Ctrl+C | Graceful stop: signal all VUs to finish their current iteration, then exit and generate report |
| Second Ctrl+C | Immediate abort: kill everything now, no report |

**Why this matters:** a 10-minute test interrupted at minute 9 should still produce a partial report.
Without graceful stop, the user loses all collected data.

Locust equivalent: `--stop-timeout N` — wait N seconds for in-flight tasks to complete.

**Our design:** adopt k6's two-signal model. On first SIGINT, set a shared
`asyncio.Event(stop_requested)`. VUs check this flag at the start of each new iteration.
After all VUs exit, generate the report from data collected so far.

---

## Exit Codes (k6 model)

k6 rule: exit code `0` only if test completes normally AND all thresholds pass.

| Exit code | Meaning |
|-----------|---------|
| `0` | Test completed, all thresholds passed |
| `1` | One or more thresholds failed |
| `2` | Tool/config error (bad HAR, connection refused at start, invalid flags) |

Locust: `--exit-code-on-error` flag (defaults to 1).

**Our design:** adopt k6's exit code model. CI pipelines use `if [ $? -ne 0 ]` to detect failures.

---

## Thresholds / Pass-Fail Criteria (k6 model)

k6 syntax: `p(95) < 200`, `rate < 0.01`, `avg < 100`

Thresholding metrics:
- **Counter**: `count`, `rate`
- **Gauge**: `value`
- **Trend/latency**: `avg`, `min`, `max`, `med`, `p(N)`

**Our CLI flags:**
```bash
--fail-on-error-rate 5      # fail if >5% of requests are non-2xx
--fail-on-p95 500           # fail if p95 latency exceeds 500ms
--fail-on-p99 1000          # fail if p99 latency exceeds 1000ms
--abort-on-fail             # stop test immediately when any threshold is breached
```

`--abort-on-fail` maps to k6's `abortOnFail: true`.

---

## Threshold Start Delay (k6 delayAbortEval pattern)

k6 `delayAbortEval: '10s'` — don't evaluate thresholds until N seconds into the test.

**Purpose:** server is cold at test start (cold JIT, empty caches, no warm connections).
Early latency spikes would falsely fail the threshold. Delay evaluation until steady state.

**Our design:** `--threshold-start-delay 30s` (default `0s`).
- Metrics are still collected from t=0 (visible in the report)
- Threshold pass/fail is only assessed after the delay
- This replaces a separate `--warmup` flag — cleaner, same effect

---

## Periodic Stats Flushing (Locust pattern)

Locust writes stats every second to:
- `_stats.csv` — current aggregate per endpoint
- `_stats_history.csv` — time-series of aggregates (one row per interval)
- `_failures.csv` — error breakdown

**Why this matters for our deque design:**
Raw `RequestResult` samples are stored in `deque(maxlen=N)`. When the deque is full,
old samples are dropped — but we still need accurate total counts for RPS.

**Our design (three-layer metrics storage):**

```
Layer 1: total_count: int
  - Incremented on every request, never dropped
  - Used for RPS: total_count / elapsed_seconds

Layer 2: deque(maxlen=--max-samples) of RequestResult
  - Bounded raw samples for percentile calculation
  - May drop oldest results on very long runs

Layer 3: StatsSnapshot written every 5s
  - Aggregated stats at each interval (p50, p95, p99, rps, error_rate)
  - Stored as list[StatsSnapshot] in memory
  - Used for the RPS-over-time chart in HTML report
  - Never dropped (small, one entry per 5 seconds)
```

---

## Error Types (network vs HTTP)

Production load testers distinguish network-level errors from HTTP errors:

| Error type | HTTP status | Cause |
|------------|-------------|-------|
| HTTP error | 4xx / 5xx | Server responded with error |
| TIMEOUT | 0 | Server did not respond within timeout |
| CONNECTION_REFUSED | 0 | Nothing listening on target port |
| DNS_ERROR | 0 | Hostname could not be resolved |
| SSL_ERROR | 0 | TLS handshake failure |

**Our design:** `RequestResult.error_type: str | None`
- `None` = successful HTTP response (any status code)
- `"TIMEOUT"`, `"CONNECTION_REFUSED"`, `"DNS_ERROR"`, `"SSL_ERROR"` = network failure

Network errors appear in `error_breakdown` as `{"TIMEOUT": 3, "CONNECTION_REFUSED": 1}`.

---

## Endpoint Normalization

Without normalization, `/walker/user/123` and `/walker/user/456` become two separate
rows in the report table. At scale this produces hundreds of meaningless unique endpoints.

**Production approach:** replace UUID and integer path segments with `{id}`.

```
/walker/user/123         → /walker/user/{id}
/walker/order/abc-def-0  → /walker/order/{id}
/walker/search           → /walker/search        (unchanged)
```

Detection rules:
- Pure integer segment: `^\d+$`
- UUID segment: `^[0-9a-f-]{32,36}$` (with or without hyphens)

**Our design:** `normalize_path(url: str) -> str` in `core/metrics.py`.
Applied when constructing `RequestResult.endpoint`.

---

## stdout vs stderr Separation

**Rule:** stderr = human output (progress, logs, debug). stdout = machine output (JSON report).

| Output | Stream |
|--------|--------|
| Rich live progress bar | stderr |
| `--debug` per-request lines | stderr |
| Console summary table | stderr |
| `--report-format json` content | stdout (or file if `--report-out` set) |
| HTML report | file only (never stdout) |
| Error messages | stderr |

**Why:** CI pipelines capture stdout for JSON parsing. If progress output goes to stdout,
`jq` on the output breaks. Always write machine-readable output to stdout or a file,
never mix with human-readable output.

---

## HAR File Security Warning

HAR files captured in Chrome contain the original session's:
- `Authorization` headers (JWT tokens, API keys)
- `Cookie` headers (session cookies)
- Any other auth credentials from the recording

The tool strips these at replay time (header sanitization). But the HAR file on disk
still contains them — committing a HAR file to git exposes credentials.

**Our design:** at startup, scan HAR headers for `Authorization` or `Cookie` values.
If found, print a warning to stderr:

```
Warning: HAR file contains Authorization/Cookie headers from the recording session.
These are stripped before replay but the file contains sensitive data.
Do not commit this HAR file to version control.
```

---

## Request Timeout

All VUs use `aiohttp.ClientSession` with a configured timeout. Without a timeout,
a VU waiting on a hung server blocks indefinitely — the test never ends.

```python
timeout = aiohttp.ClientTimeout(total=config.timeout_seconds)
session = aiohttp.ClientSession(timeout=timeout)
```

**CLI flag:** `--timeout 30s` (default 30s). Timed-out requests are recorded as
`error_type="TIMEOUT"` with `status=0` and `latency_ms` = timeout value.
