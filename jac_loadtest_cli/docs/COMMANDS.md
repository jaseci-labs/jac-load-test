# jac loadtest — Command Reference

```
jac x loadtest <har_file> [options]
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

## Protocol Support (WebSocket & GraphQL)

No flag needed — `jac x loadtest` automatically detects and replays WebSocket connections and
GraphQL traffic recorded in the HAR, alongside the regular HTTP entries, in the same run:

| What the HAR contains | What happens |
|---|---|
| A WebSocket connection (`_resourceType: "websocket"`, or any `ws://`/`wss://` URL — no `_resourceType` needed) | Replayed via the WebSocket adapter: connects, sends whatever message frames were captured, records reply latency. Rewritten to `ws://`/`wss://` under `--url`'s host, same as HTTP entries are rewritten. |
| A GraphQL subscription over that WebSocket connection (a `graphql-ws` `"start"`/`"subscribe"` frame carrying a `query`) | Replayed as a GraphQL subscription: records time-to-first-event latency and events/second, reported separately from raw WebSocket traffic. |
| A GraphQL query/mutation over plain HTTP (any JSON POST body with a top-level `query` field containing a `{` selection-set brace) | Replayed exactly like any other HTTP entry, just labeled `graphql` in the report so it doesn't blend into REST latency numbers. |

The report groups every endpoint by `(protocol, endpoint)` — a `Proto`/`Protocol` column
appears in the console/JSON/HTML output only when a run actually contains something other than
plain HTTP; a HAR with no WebSocket/GraphQL traffic produces the exact same report as before.

**WebSocket message capture is opportunistic.** A HAR entry's WebSocket frames live in a
non-standard `_webSocketMessages` field that a plain Chrome DevTools "Export HAR" does **not**
include — some other recorders (e.g. Playwright's HAR recorder) do. Without it, the connection
is still detected and replayed, just with no message sequence to send; a one-time warning on
stderr explains this when it happens.

Combining WebSocket/GraphQL entries with `--workers > 1` is not supported — protocol adapters
run in-process alongside the HTTP engine, not across worker processes. Use `--workers 1` (the
tool exits with an error otherwise) for a HAR that contains any.

---

## Load Shape

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--url` | — (required in monolith mode) | URL string, e.g. `http://localhost:8000` | CLI only | Target base URL. Replaces the origin recorded in the HAR; path and query string are preserved. Changes per environment so not suitable for `jac.toml`. |
| `--mode` | `monolith` | `monolith` \| `microservice` | CLI + jac.toml | Deployment topology. `monolith` routes all requests to `--url`. `microservice` reads service prefix→URL routing from `jac.toml` and sends each request directly to its service. |
| `--vus` | `1` | Positive integer, e.g. `50` | CLI + jac.toml | Number of virtual users (concurrent coroutines). Each VU replays the full HAR sequence independently. Practical ceiling is ~200–500 VUs per worker. |
| `--workers` | CPU count | Positive integer, e.g. `4` | CLI + jac.toml | Number of worker processes. Each worker runs its own asyncio event loop on a separate OS thread, bypassing the GIL. Capped automatically at `--vus` so no idle processes are spawned. Use `1` for single-process mode. |
| `--iterations` | `1` | Positive integer, e.g. `100` | CLI + jac.toml | Stop each VU after N complete HAR replays. Defaults to `1` (one full HAR replay per VU), unless `--duration` is set with no explicit `--iterations` — see below. The actual wall-clock time is measured and shown in the report regardless of this value. |
| `--duration` | — (disabled) | Time string: `10s`, `1m`, `5m` | CLI + jac.toml | Hard wall-clock cutoff for the whole run — stops all VUs once elapsed, regardless of `--iterations`. If set without an explicit `--iterations`, VUs loop indefinitely until the duration elapses instead of stopping after 1 replay, so the run length is a fixed, comparable measurement window rather than an emergent product of `vus × iterations × replay time`. Works with the default closed-loop mode and `--open-loop`. Not compatible with `--step-load`, which has its own step-based timing via `--step-duration`/`--step-max-vus`/`--fail-on-*`. |
| `--ramp-up` | `0s` | Time string: `10s`, `1m` | CLI + jac.toml | Stagger VU startup over this duration. With `--vus 50 --ramp-up 10s`, VU 1 starts at t=0s, VU 50 starts at t=9.8s. Prevents thundering herd at test start. |
| `--rps` | `0` (unlimited) | Non-negative integer, e.g. `100` | CLI + jac.toml | Global requests-per-second cap across all VUs combined. `0` means no cap. Implemented as a per-VU inter-request sleep of `vus/rps` seconds, which distributes the cap evenly. |
| `--open-loop` | `false` | Boolean flag (no value) | CLI + jac.toml | Fixed-arrival-rate mode. Launches a new session every `1/rps` seconds on a fixed schedule, regardless of how long earlier sessions are still taking to respond — unlike the default closed-loop mode, where each VU's next request is paced from its *previous response*, so achieved throughput silently degrades once the target slows down. Requires `--rps` to be a positive value; `--rps 0` (unlimited) has no fixed rate to schedule against. In this mode `--rps` means sessions/iterations per second, not a per-request cap — each session still replays its full HAR sequence once launched. Concurrency is not bounded — a slow target causes in-flight sessions to pile up, which is the point (it reveals real queueing instead of hiding it). |
| `--step-load` | `false` | Boolean flag (no value) | CLI + jac.toml | Step-load / ramp-to-failure mode. Starts at `--vus`, holds for `--step-duration`, adds `--step-vus` more, and repeats — until a `--fail-on-*` threshold breaches that step's own traffic window or `--step-max-vus` is reached. Finds the capacity knee (the last passing VU count) instead of testing at one fixed VU count; the report gets a per-step table plus a "Capacity knee" line. Each step is judged only on requests that landed *during that step*, not the cumulative run, so a breach isn't diluted by earlier passing steps. Single-process only (`--workers 1`); cannot be combined with `--open-loop`. Requires `--step-vus`, and requires `--step-max-vus` or at least one `--fail-on-*` flag as the stopping condition. |
| `--step-vus` | `0` | Positive integer, e.g. `10` | CLI + jac.toml | VUs added at each step in `--step-load` mode. |
| `--step-duration` | `30s` | Time string: `10s`, `1m` | CLI + jac.toml | How long to hold each step before evaluating thresholds and advancing to the next one, in `--step-load` mode. |
| `--step-max-vus` | `0` (no ceiling) | Non-negative integer, e.g. `200` | CLI + jac.toml | Ceiling on total VUs during the `--step-load` ramp. `0` means no ceiling — in that case at least one `--fail-on-*` threshold must be set so the ramp has a stopping condition. |

---

## Request Behavior

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--timeout` | `30s` | Time string: `10s`, `1m` | CLI + jac.toml | Per-request timeout. Requests that exceed this are recorded as `TIMEOUT` errors with `status=0` and `latency_ms` equal to the timeout value. |
| `--assert-json` | — (disabled) | `PATH=VALUE`, e.g. `'ok=true'` | CLI only, repeatable | Requires a JSON response-body field to equal a value for a request to count as successful, in addition to the status code — closes the gap where a `200` carrying an application-level error payload (e.g. `{"ok": false}`) would otherwise always count as success. Dotted path traverses objects and array indices, e.g. `'reports.0.ctx.success=true'`. Repeat the flag for multiple assertions — all must pass. `VALUE` is parsed as JSON when possible (`true`/`false`/`null`/numbers), else compared as a literal string, so `--assert-json 'status=ok'` works without shell-quoting JSON. Only evaluated when the status code already matched `expected_status` — a status mismatch is already a failure on its own. Applies globally to every response in the run, not per-endpoint; a HAR with structurally different endpoint responses may need a field common to all of them, or should skip this flag. |
| `--think-time` | `none` | `none` \| `real` \| `scaled` | CLI + jac.toml | Inter-request delay between HAR entries. `none` = no delay (maximum stress). `real` = wait the recorded `timings.wait` ms. `scaled` = same as `real` but multiplied by `--think-time-scale` (useful to run faster or slower than recorded). |
| `--think-time-scale` | `1.0` | Float, e.g. `0.5`, `2.0` | CLI + jac.toml | Multiplier applied to recorded think times when `--think-time real`. Values below `1.0` speed up pacing; values above `1.0` slow it down. |
| `--include-static` | `false` | Boolean flag (no value) | CLI + jac.toml | By default, image/*, font/*, text/css, and JS bundle entries in the HAR are skipped. Pass this flag to replay everything including static assets. |
| `--csrf` | `false` | Boolean flag (no value) | CLI + jac.toml | Detects a CSRF cookie (`csrftoken` or `_csrf`) on any response and injects it as an `X-CSRFToken` header on subsequent non-GET requests, per VU. The stored value rotates automatically if a later response sets a new cookie value. Useful when the target sits behind a reverse proxy that adds CSRF protection (jac-scale itself uses JWT, not CSRF). |

---

## Authentication

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--username` | — | String | CLI only | Username for auth. All VUs log in with this identity and get separate JWT tokens. **Security-sensitive — never put in jac.toml.** |
| `--password` | — | String | CLI only | Password paired with `--username`. **Security-sensitive — never put in jac.toml.** |
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
| `--apdex-t` | `500` | Float (milliseconds), e.g. `300` | CLI + jac.toml | Apdex satisfaction threshold T, in ms. A request is *satisfied* if `latency_ms <= T`, *tolerating* if `T < latency_ms <= 4T`, and *frustrated* otherwise (or on error). Apdex score = `(satisfied + 0.5 * tolerating) / total`, shown per-endpoint and globally in every report format. |

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
| `--slo` | — | JSON string, e.g. `'{"/walker/chat": {"p95": {"good": 2000, "bad": 8000}}}'` | CLI only | Per-endpoint latency SLO overrides for report ratings (Good/Acceptable/Bad). Without this, every endpoint is judged against the same built-in bar (`p50` good&lt;100ms/bad&gt;500ms, `p95` good&lt;500ms/bad&gt;2000ms, `p99` good&lt;1000ms/bad&gt;5000ms, `p999` good&lt;2000ms/bad&gt;10000ms) — unfair to both a fast health-check endpoint and a slow LLM-backed one judged the same way. Keys are endpoint strings as they appear in the report; metrics/endpoints not listed keep the global default. Validated before the run starts — invalid JSON or `good >= bad` fails fast with a clear error. |

---

## jac.toml Example

Settings appropriate for team-wide defaults can be committed in `jac.toml`. CLI flags always override these.

```toml
[plugins.scale.loadtest]
# Load shape
vus                   = 20
workers               = 4          # worker processes (default: CPU core count)
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
| `--services-map` | Environment-specific URL overrides |
| `--report-out` | Output path changes per run |
| `--debug` | Too noisy for committed defaults |

---

## Quick Examples

```bash
# Minimal: 1 VU, 30s
jac x loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 50 --ramp-up 10s

# Realistic pacing from recorded think times
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --think-time real

# Microservice mode (reads routing from jac.toml)
jac x loadtest recording.har --mode microservice --vus 30

# Microservice mode with explicit service URLs (no jac.toml needed)
jac x loadtest recording.har --mode microservice \
  --services-map '{"order_service":"http://order.svc:8001","inventory_service":"http://inv.svc:8002"}' \
  --vus 30

# CI gate: fail if p95 > 500ms or error rate > 1%
jac x loadtest recording.har --url http://staging:8000 \
  --vus 10 --fail-on-p95 500 --fail-on-error-rate 1 --threshold-start-delay 10s

# HTML report
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --report-format html --report-out results.html

# JSON report
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --report-format json --report-out results.json
```

---

## Planned flags (roadmap — not yet implemented)

These are scheduled in [`COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md). Listed here so the
intended surface is visible; **none of them work today.**

### Phase 7 — Multi-User Realism

| Flag | Purpose |
|------|---------|
| `--correlate "A.response.<path> -> B.body.<path>"` | Extract a value from one response, inject into a later request, per VU. Repeatable. |
| `--correlate-scan` | No-load baseline pass that finds correlation candidates and prints ready-to-paste `--correlate` flags. |
| `--accounts accounts.csv` | Per-VU account pool — each VU logs in as its own identity with its own token. CSV header row; `username,password` required. Mutually exclusive with `--username`/`--password`. |
| `--param "Endpoint.body.field=values.csv"` | Substitute a CSV column into a body/query field. Repeatable. |
| `--think-time gaussian` / `--think-time-stddev` / `--think-time-jitter P` | Randomized inter-request delay. |
| `--persona-file personas.json` | Split load across manually-defined user archetypes (name, description, entry indices, VUs). Mutually exclusive with `--vus`. |

### Phase 8 — Result Fidelity & Regression Gating

| Flag | Purpose |
|------|---------|
| `--infra-block-threshold N` | Classify byte-identical non-JSON bodies seen across ≥ N endpoints as infrastructure blocks (WAF/rate-limit), reported separately from application errors. Default 3. |
| `--proxy-pool proxies.txt` | Round-robin egress across an HTTP/SOCKS5 proxy list. |
| `--assert-json "/walker/AddTodo:reports.0.id=*"` | Per-endpoint response assertion (scoped form of the existing global `--assert-json`). |
| `--no-body-check` | Disable the default jac-scale-aware body-level error check. |
| `--baseline prev.json` | Load a prior JSON report for comparison. |
| `--fail-on-regression "p95:10%,error_rate:0.5pp,rps:-10%"` | Exit 1 when a metric regresses past tolerance vs. `--baseline`. |
| `--fail-on-shape-drift` | Treat response-shape divergence from the baseline as a failure (default: warn only). |

### Phase 10 — Auth Adapters & Authoring

| Flag / command | Purpose |
|------|---------|
| `--auth-type {jac-scale\|bearer\|basic\|apikey\|oauth2-cc\|none}` | Select the auth adapter. |
| `--auth-header NAME` / `--auth-value VALUE` | Static API-key / bearer injection. |
| `--auth-token-path PATH` | Override the login-response JSON path (default `data.token`). |
| `--auth-body-template FILE` | JSON template for a non-standard login request body. |
| `--auth-adapter pkg.mod:Class` | Import a custom auth adapter class. |
| `jac x loadtest record --port 8080 --out r.har [--scope URL]` | Built-in forward-proxy recorder — no DevTools export. |
| `jac x loadtest from-spec openapi.yaml --out r.har` | Generate a HAR-compatible entry list from an OpenAPI 3.0/3.1 or Swagger 2.0 document. |

### Phase 11 — Distributed Load Generation

| Flag / command | Purpose |
|------|---------|
| `jac x loadtest worker --port N [--discover]` | Run a worker node. |
| `--worker-nodes [region:]host:port,...` | Controller — split VUs across nodes, merge metrics, group latency by region. |

### Phase 12 — Observability & Release

| Flag | Purpose |
|------|---------|
| `--output {prometheus\|influxdb\|otlp}` / `--output-url URL` | Stream live metrics to an external sink alongside the normal report. |
| `--report-format junit` | JUnit XML report for Jenkins / GitLab / Azure DevOps. |
