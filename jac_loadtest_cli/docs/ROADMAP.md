# jac-loadtest Roadmap

What is built and what is planned for `jac-loadtest-cli` (the CLI and its headless engine). The web
app has its own roadmap: [`../../jac_loadtest_web/docs/ROADMAP.md`](../../jac_loadtest_web/docs/ROADMAP.md).
The open items aim at one goal: reliably load testing an application with HTTP walker endpoints
and WebSocket channels, with HAR replay kept as the smoke test.

Principles: CLI-first (front ends wrap `headless.jac`); no embedded AI; the load engine is Locust
(no second engine; scale-out is Locust master and workers).

`[x]` done · `[ ]` open. Open items are in priority order, highest first.

---

## Open (priority order)

### 1. Make results trustworthy
- [ ] Body check reads `data.reports` first so `reports[].success: false` is caught on jac 0.37+ (#38)
- [x] A `--correlate` rule that never captured a value is reported and fails the run (`--fail-on-correlation-miss`), including a rule that captured but never injected (#36)
- [x] `--correlate` source paths work on both response envelopes, `data.result.reports.*` and `data.reports.*` (#37)
- [x] Auto-correlation threads an id that several recorded responses carried from the earliest one, and prints the choice at startup (#47)
- [ ] Poll blocks stay out of the global p95/p99 and `--fail-on-p99`; time-to-ready, attempts and outcome reported as a separate series
- [ ] `--fail-on-error-rate` and `--abort-on-fail` use the same error rate and latency pool as the report: no infra blocks, no health-check samples (#41)
- [ ] `--check-shape` drift is reported as a warning, and `--fail-on-shape-drift` decides the exit code (#43)
- [ ] Mid-run re-auth refreshes the VU's own account after `--skip-failed-accounts` (#40)
- [x] WebSocket / GraphQL scenario `duration` is removed: scenarios run per user iteration under the run's own `--duration` (#42)
- [ ] Fix help text and docs drift: `--assert-json` scope; `--poll-until` example that never matches

### 2. Scenario files (HTTP)
- [ ] Scenario file format (YAML/JSON): ordered named steps with method, path and templated body, reusing the existing tokens, account pool and `--param` data
- [ ] `extract`: capture values from a response (JSON path or header) into per-VU variables for later steps
- [ ] `check` per step: status, field equals / exists / contains, including against extracted values
- [ ] `wait_until` step: re-send a named step until a condition holds or a timeout; works on a single request
- [ ] Reports, thresholds and assertions keyed by step name, not URL path
- [ ] Per-VU and once-per-test `setup` / `teardown` steps that always run, even after a failure
- [ ] Per-scenario load model and weight (closed, open, ramp, duration), several scenarios in one run as a traffic mix
- [ ] Coverage report: which endpoint actions ran, against an inventory file
- [ ] Generate a scenario skeleton from a HAR

### 3. WebSocket conversations
- [ ] Validate WebSocket replies: error frames fail, replies matched to requests by id or action, pings ignored, "no reply" and "error reply" reported separately
- [ ] WebSocket steps in scenarios: templated `connect` URL, `send` with per-VU token, user id and request id, `expect` with checks and timeout, `close`
- [ ] `extract` into frames (e.g. an auth token returned by an HTTP response); WebSocket flow runs in the same VU as the HTTP flow
- [ ] `--ws-scenario` / `--graphql-scenario` files for HARs with no frames; `introspect_schema()`; clearer "no frames" warning

### 4. Real load and CI gating
- [ ] Overlap requests within one VU (`parallel:` group, or derived from HAR timings); serial stays the default
- [ ] Baseline regression gate: `--baseline prev.json`, `--fail-on-regression "p95:10%,error_rate:0.5pp"`, per-endpoint diff in the report
- [ ] Report the register / login burst as its own rows, with an option to run it concurrently
- [ ] Continuous health probe for the whole run (`--health-check-interval`)
- [ ] JUnit report (`--report-format junit`)

### 5. Later
- [ ] Per-VU target host (a correlated value selects the host), for per-VU service URLs
- [ ] Request signing hook (HMAC / JWS) for webhook endpoints
- [ ] Randomised think time: `--think-time gaussian`, `--think-time-stddev`, `--think-time-jitter` (7d)
- [ ] Personas: `--persona-file` splits load across user archetypes, reports group by persona (7e; overlaps scenario weights)
- [ ] Pluggable auth: `--auth-type`, `--auth-header/--auth-value`, `--auth-token-path`, `--auth-body-template`, `--auth-adapter` (10a)
- [ ] Built-in recorder: `jac x loadtest record --port N --out r.har`, captures WebSocket frames, optional `--via cdp`, `--redact-headers` (10b)
- [ ] Workers on other hosts: expose Locust's master/worker mode over the network (`jac x loadtest worker`, `--worker-nodes [region:]host:port`); same-machine `--workers N` already works, including `--step-load` (11)
- [ ] Metrics sinks: `--output prometheus|influxdb|otlp` (12)
- [ ] `ProtocolAdapter` interface and plugin registry; PyPI release, Docker image, GitHub Action with the baseline diff as a PR comment (12)
- [ ] gRPC, database and MQTT adapters, only on demand (13)

---

## Done

### Locust engine (issue #46)
- [x] Load generation, scheduling, workers, statistics, console tables and the HTML report moved to Locust; our code is HAR replay, correlation, jac-scale auth, body check, WAF classification, thresholds and the JSON report
- [x] Dropped as Locust-native or not worth rebuilding: proxy pool, open-loop and `--rps`, login-burst pacing, scaled think time, Apdex and SLO bands, TTFB, exact percentiles (see UPGRADING.md)
- [x] `--step-load` works with `--workers`; each step judged on its own traffic window
- [x] `run_test_headless()` runs the test in a child process, so an embedder never imports Locust
- [ ] Automated step-load and `--abort-on-fail` tests; `--csv` output; parity tests were done by hand and retired with the old engine

### Foundation (phases 0–5)
- [x] HAR parsing and filtering (static assets, non-API resource types, cache-busters, missing bodies)
- [x] asyncio VU engine, ramp-up, `--rps`, graceful shutdown (two-signal)
- [x] Per-VU JWT auth, think time (`none`, `real`, `scaled`), three-layer config (CLI, `jac.toml`, defaults)
- [x] Microservice mode: path-prefix routing, per-service reporting, `--services-map`
- [x] Threshold gates (`--fail-on-error-rate`, `--fail-on-p95/p99`), `--abort-on-fail`, `--threshold-start-delay`, exit codes
- [x] Multi-process workers (`--workers`)
- [x] Console, JSON and self-contained HTML reports; p99.9, Apdex, TTFB, per-endpoint RPS

### Headless contract and harness (phase 6)
- [x] `LoadTestConfig.from_dict()`, `run_test_headless()` with live snapshots, `render_json()` / `render_html()`
- [x] `--open-loop`, `--duration`, `--step-load` with capacity knee, `--csrf`
- [x] `--assert-json`, `--slo`, response trace-ID capture
- [x] Fixes: timeouts no longer skew percentiles, fractional `rps` from `jac.toml`, visible sample eviction, per-interval time series

### Multi-user realism (phase 7)
- [x] 7a Response correlation: auto-detected from the HAR, `--correlate`, `x-jac-correlate`, `--no-auto-correlate`
- [x] 7b Per-VU account pool (`--accounts`), register on demand, mid-run re-auth on 401, `--skip-failed-accounts`, auth-burst pacing (`--auth-delay`, `--auth-batch-size/-delay`)
- [x] 7c Test data: `--param` files and `{{uuid}}`, `{{vu_id}}`, `{{iter}}`, `{{randint}}`, `{{now}}`, `{{account.<col>}}`, `{{env.<VAR>}}`
- [x] 7F `--health-check` side channel with endpoint-scoped `--fail-on-p95/p99`

### Result fidelity (phase 8)
- [x] 8a `INFRA_BLOCK_SUSPECTED` (WAF and rate-limit pages excluded from the error rate), `--proxy-pool`
- [x] 8b Body check for failures inside HTTP 200 (`APP_ERROR_IN_200`), `--check-shape`, scoped `--assert-json`
- [x] `--poll-until` / `--poll-error-until` wait-until polling
- [x] 8d Multi-process fidelity: fleet-wide `--abort-on-fail`, exact live percentiles, `--max-samples` split

### Protocols (phase 9)
- [x] WebSocket and GraphQL (query, mutation, subscription) auto-detected from the HAR
- [x] Replay at any `--workers` count; WebSocket handshake reported as a `[connect]` row

### Toolchain
- [x] Runs on jac 0.39.2: keyword identifiers, typed generics, `jac.toml` lookup through `jaclang.project.config`, service-app routing; supported version stated in the README (#39). 0.34 is no longer supported, so there is no multi-version CI matrix

---

## Removed

| Removed | Why |
|---|---|
| AI persona assignment and `by-llm` browser agent | A general coding agent does this better; personas stay as a hand-authored file |
| `--engine k6` backend | Would fork the report format, auth and metrics; native distributed mode replaces it |
| OpenAPI import (`--spec`, `from-spec`) | One placeholder request per operation, no field values, cannot tell actions apart |
