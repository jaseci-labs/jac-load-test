# jac-loadtest Roadmap

A **CLI-first** delivery plan for `jac-loadtest-cli` (the engine).

The web app (`jac-loadtest-web`) is **frozen at its Phase 6 MVP** — it is no longer a
roadmap driver. See [Web App Status](#web-app-status) at the bottom. Every capability from
Phase 7 onward is delivered as CLI + headless engine code only; a future GUI can wrap the
headless entry points with zero engine changes.

> **This revision (2026-09) restructures the roadmap** around two decisions and one set of
> findings:
> 1. **CLI-first.** All primary features live in `jac x loadtest`. Web work stops at the
>    current MVP.
> 2. **No embedded AI.** The AI persona-assignment and `by-llm` browser-agent features are
>    removed. A bespoke AI agent baked into a load-test tool is worse than a general coding
>    agent (Claude Code, Cursor, …) that can generate a persona file, a correlation spec, or
>    drive a browser to produce a HAR — and far more flexibly. The tool's job is to expose
>    clean, deterministic, scriptable primitives that any external agent can target.
> 3. **Findings.** A market comparison (k6, JMeter, Gatling, Locust, Artillery, GoReplay,
>    Speedscale/Keploy) and an assessment of what the Jaseci ecosystem needs now.
>    See [`MARKET_COMPARISON.md`](MARKET_COMPARISON.md).
>
> The phase reorder that follows puts the **multi-user realism** and **regression-gating**
> gaps — the ones that block using this tool to validate jac-scale's own "scale-invariance"
> claim — ahead of protocol breadth and the plugin ecosystem.

---

## Architecture Principle

**The CLI is the whole product.** Everything that generates load, makes a decision, shapes a
result, or talks to a target system — protocol adapters, correlation, persona replay,
per-VU identity, spec parsing, worker coordination, every report format — lives in
`jac_loadtest_cli`, reachable as a plain function with no argparse, no `sys.exit()`, and
plain-data in/out (`headless.jac`). This has been true since Phase 0 for the HTTP engine and
holds for every capability added below.

The layering inside the package is unchanged:

```
cli.jac / plugin.jac        ← argparse surface only
headless.jac                ← plain-function entry points (run_test_headless, parse_api_spec, …)
  ↓
core/                       ← HAR parser, engines (http/ws/graphql/…), correlation, metrics
                              — ZERO jac-scale knowledge, works against any HTTP server
bridge/                     ← jac-scale-aware adapters (auth, topology) — the only jac-scale seam
output/                     ← console / JSON / HTML / (planned) junit reporters
```

The web app, if it is ever resumed, stays a presentation shell: its `sv` walkers only call a
headless function, persist the result, and stream progress over SSE. No decision, parser,
state machine, or protocol client ever lives in an `sv` walker.

---

## Phase Status Overview

| Phase | Name | Status |
|-------|------|--------|
| 0 | CLI Foundation | ✅ Done |
| 1 | CLI MVP (HAR replay + console report) | ✅ Done |
| 2 | CLI Auth + Think Time | ✅ Done |
| 3 | CLI Microservice Mode | ✅ Done |
| 4 | Production Hardening | ✅ Done |
| 5 | Reporting & Polish | ✅ Done |
| 6 | Web MVP | ✅ Done — **web development freezes here** |
| 7 | **Multi-User Realism** — correlation, per-VU accounts, test data, personas | 🔜 Next — highest priority |
| 8 | **Result Fidelity & Regression Gating** — infra-block detection, baseline diff, CI gate, multiprocess fidelity | 🔜 Next |
| 9 | GraphQL & WebSocket | ◑ Engine adapters + HAR auto-detect done; scenario files, frame-capture guidance, multiprocess, `introspect_schema()` open |
| 10 | Auth Adapters & Recording-Free Authoring — pluggable auth, proxy recorder, OpenAPI import | ⬜ Not started |
| 11 | Distributed Load Generation — worker mode, `--worker-nodes`, region aggregation | ⬜ Not started |
| 12 | Release & jac-scale Integration — PyPI, metrics sinks, JUnit, plugin registry, `jac-scale[loadtest]` | ⬜ Not started |
| 13 | Extended Protocols (demand-driven) — gRPC, DB, MQTT | ⬜ Not started — build only on real demand |

### Critical path

**7 → 8 → 12.** Multi-user realism makes a jac-scale multi-tenant load test *mean* something;
regression gating turns the tool into a CI guard for the jac-scale runtime itself;
integration ships it as a framework feature. Phases 10, 11, and 13 are adoption-driven and
follow the critical path.

### Pull-forward items (small, high-trust — land before or alongside Phase 7)

- Single-source-IP behaviour documented in `CONSTRAINTS.md` (§6) — done in this revision.
- `INFRA_BLOCK_SUSPECTED` error class (Phase 8) — cheap heuristic, high signal.
- Per-endpoint `--assert-json` scoping (Phase 8) — mirrors the existing `--slo` shape.
- Split the `--max-samples` budget across workers instead of applying it twice (Phase 8d) —
  a few lines, strictly-better retention, no design questions attached.
- Split `--rps` in whole units with largest-remainder distribution so per-worker rates sum
  exactly to the target (Phase 8d) — today's float split silently undershoots.

---

## Phase 0 — CLI Foundation ✓

> Repo skeleton and import tree wired before any logic is written.

- [x] `jac_loadtest_cli/` package with `core/`, `bridge/`, `output/` layout
- [x] `jac.toml` with dependencies; `loadtest` console script declared via `[entrypoints.scripts]`
- [x] `plugin.jac` — argparse entry point exposed as the console script; `jac x loadtest --help` works
- [x] Empty module stubs; full import tree resolves from day one
- [x] `tests/` directory with `tests/fixtures/` and JAC test blocks

**Exit criterion:** `jac x loadtest --help` prints usage. ✓

---

## Phase 1 — CLI MVP (HAR replay + console report) ✓

> First working end-to-end path. No auth, no microservices.

- [x] `core/har_parser.jac` — parse HAR 1.2, filter non-API entries, URL rewrite
- [x] `core/engine.jac` — asyncio VU coroutines, duration cap, `aiohttp.ClientSession`
- [x] `core/metrics.jac` — `RequestResult`, latency collection, p50/p95/p99
- [x] `output/reporter.jac` — Rich console table (per-endpoint rows + summary footer)
- [x] `config.jac` — `LoadTestConfig` dataclass + `parse_duration()`
- [x] `--url`, `--vus`, `--iterations`, `--timeout` CLI flags
- [x] `tests/unit/test_har_parser.jac` (47 tests), `tests/unit/test_metrics.jac` (21 tests)
- [x] GitHub Actions CI

**Exit criterion:** `jac x loadtest recording.har --url http://localhost:8000 --vus 10` completes and prints a summary table. ✓

---

## Phase 2 — CLI Auth + Think Time ✓

> VUs log in and replay sessions realistically.

- [x] `bridge/auth.jac` — detect login entry, JWT injection, identity type inference
- [x] Shared credentials: `--username` / `--password` (all VUs, same account as HAR recording)
- [x] Think time: `--think-time none|real` with `--think-time-scale` multiplier
- [x] Ramp-up: `--ramp-up Ns` staggers VU startup
- [x] Three-layer config resolution (CLI → jac.toml → built-in defaults)
- [x] `tests/integration/test_auth.jac` (12 tests), `tests/unit/test_config.jac` (11 tests)

**Exit criterion:** `jac x loadtest recording.har --username user --password pass` runs with 0 auth errors. 141 tests pass. ✓

---

## Phase 3 — CLI Microservice Mode ✓

> Route requests to the correct service process, report per-service breakdown.

- [x] `bridge/topology.jac` — `TopologyRouter`, longest-prefix matching
- [x] `--mode microservice`, `--services-map JSON` flag
- [x] Auto-discovery from `./jac.toml` `[plugins.scale.microservices.routes]` + `JAC_SV_*_URL`
- [x] Fallback to `--url` (gateway) for unmatched paths
- [x] Per-service `RequestResult.service` field; per-service column in console reporter
- [x] `tests/unit/test_topology.jac` (18 tests), microservice-mode integration tests

**Exit criterion:** `jac x loadtest recording.har --mode microservice --services-map '{...}'` reports per-service latency. ✓

---

## Phase 4 — Production Hardening ✓

> Reliable under pressure: clean shutdown, CI-compatible exit codes, error classification.

- [x] Graceful shutdown — two-signal model
- [x] Exit codes: `0` = pass, `1` = threshold failed, `2` = config/tool error
- [x] Threshold enforcement: `--fail-on-error-rate N`, `--fail-on-p95 N`, `--fail-on-p99 N`
- [x] `--abort-on-fail` — `_threshold_watcher` sets `stop_requested` on first breach
- [x] `--threshold-start-delay Ns` — watcher skips checks until elapsed ≥ delay
- [x] RPS cap: `--rps N` — per-VU sleep of `vus/rps` seconds before each request
- [x] `--think-time scaled`
- [x] `--debug` flag: `_print_debug(result)` writes per-request line to stderr
- [x] `error_type` on `RequestResult`: `TIMEOUT`, `CONNECTION_REFUSED`, `DNS_ERROR`, etc.
- [x] Multi-process VU distribution: `--workers N` + `core/process_runner.jac`
- [x] `tests/integration/test_engine.jac` — 7 new tests, 148 total

**Exit criterion:** interrupted test still generates a partial report; `$?` correctly signals threshold failures; `jac test tests/integration/` passes. ✓

---

## Phase 5 — Reporting & Polish ✓

> Machine-readable output for CI, charts for humans.

- [x] `StatsSnapshot` written every 10s; live Rich progress bar
- [x] JSON report: `--report-format json` → stdout or `--report-out` file
- [x] HTML report: `--report-format html --report-out <path>` — Chart.js charts
- [x] p99.9 latency — `EndpointStats.p999_ms`; all three report formats
- [x] Per-endpoint RPS — column in all three formats
- [x] Bytes received column
- [x] Apdex score — `--apdex-t N` flag (default 500ms); per-endpoint + global
- [x] `tests/integration/test_reporter.jac` (21 tests)
- [x] `tests/e2e/test_smoke.jac` — 5 tests

**Exit criterion:** `jac x loadtest ... --report-format html --report-out report.html` produces a self-contained HTML file with charts; `jac test tests/e2e/` passes. ✓

---

## Phase 6 — Web MVP ✓

> A user with no CLI experience can run a complete authenticated load test from a browser tab.

**This is the final web-focused phase.** Web development freezes at the state below. The
capabilities added from Phase 7 onward are CLI + headless engine only. The headless contract
(`LoadTestConfig.from_dict()`, `run_test_headless(config, on_snapshot=, stop_event=,
on_html_report=)`) is preserved so a future GUI can resume against it without engine changes.

### CLI additions (done)

- [x] `LoadTestConfig.from_dict(d: dict) -> LoadTestConfig` — construct directly from a plain
      dict using `BUILT_IN_DEFAULTS`; no toml lookup, no `get_scale_config()`, no argparse.
- [x] `run_test_headless(config, on_snapshot=None, stop_event=None, on_html_report=None) -> dict`
      — runs the full engine, fires `on_snapshot` per 10s tick, checks `stop_event` between
      requests, hands the rendered HTML to `on_html_report`; returns the `render_json()` dict.
      No `sys.exit()`, no Rich output, no file writes.
- [x] `stream_metrics_callback` wired into `run_all_vus()` and `run_multiprocess()`.
- [x] `render_json()` / `render_html()` importable as plain functions with no CLI context.
- [x] TTFB breakdown — `ttfb_ms` on `RequestResult`, `EndpointStats`, JSON report, HTML card.

### Issue #18 — harness defects (B-series) + capacity-testing gaps (H-series)

- [x] **B1** — timeouts no longer inflate p95/p99 (`latency_valid=False` on the TIMEOUT path).
- [x] **B2** — fractional `rps` from `jac.toml` no longer truncates to `0` (`_resolve_float`).
- [x] **B3** — `--max-samples` eviction warns once on stderr; `samples_evicted` / `window_limited`
      surfaced in every report format.
- [x] **B4** — non-cumulative per-interval timeseries (`generate_interval_timeseries()`).
- [x] **B5** — `--csrf` CSRF cookie detection + `X-CSRFToken` injection, per VU.
- [x] **H1** — `--open-loop` fixed-arrival-rate mode.
- [x] **H2** — `--duration` fixed wall-clock measurement window.
- [x] **H3** — `--step-load` / ramp-to-failure mode with capacity-knee reporting.
- [x] **H7** — response trace-ID capture (`extract_trace_id()`, `RequestResult.trace_id`).
- [x] **H8** — `--assert-json PATH=VALUE` response-body assertions (global).
- [x] **H9** — `--slo` per-endpoint latency SLO overrides for report ratings.
- [x] **H4** — k6 high-scale backend — **DROPPED.** Replaced by native distributed mode
      (Phase 11); a k6 shim would fork the report format, auth bridge, and metrics pipeline.
- [x] **H5** — per-VU auth (distinct token per VU) — **moved to Phase 7** (per-VU account pool).

### Web MVP (done)

Full authenticated load-test workflow from the browser: jac-scale built-in auth
(`/user/register`, `/user/login`), workspace wizard (monolith/microservice, HAR upload,
optional single credential), run creation form (VUs, iterations, ramp-up, workers, RPS,
think time, timeout, thresholds), live SSE dashboard (RPS + latency charts, error badge,
stop button), post-run report (summary table, per-endpoint bars, error breakdown), and
JSON/HTML download. Data models: `Workspace`, `LoadTestRun` as jac-scale nodes.

Not-done web bullets from the original plan (proxy recorder UI, "replace HAR", workspace
settings panel, ramp-up ring, debug log panel, "re-run with same settings") are **descoped**
by the freeze. If web resumes, they return then.

**Exit criterion:** a user registers, creates a monolith workspace with a HAR and credentials,
runs a 50-VU / 60s test, watches live charts, sees a threshold pass/fail summary, and
downloads an HTML report — without touching a terminal. ✓

---

## Phase 7 — Multi-User Realism 🔜

> Make N virtual users behave like N distinct real users instead of one recording replayed
> N times. This is the phase that turns a jac-scale "multi-tenant scalability" test from a
> claim in the docs into something the tool actually measures.

**Why this is first.** On jac-scale every request executes against the authenticated user's
own root graph. One shared token across N VUs measures *single-user contention under
concurrency*, not the multi-user profile a real traffic mix exercises. And a HAR carries the
recording user's server-generated node IDs in request bodies, so mixed create→update→delete
workflows fail ownership checks on replay. Both are the top gaps in
[`MARKET_COMPARISON.md`](MARKET_COMPARISON.md) and both are solved here.

The three user-specific things in a HAR, and the fix for each:

| In the HAR | Symptom when N VUs replay raw | Fix in this phase |
|---|---|---|
| Recording user's **token** | All VUs serialize on one user's graph | Per-VU account pool |
| **Server-generated IDs** in bodies/URLs | Later requests carry a dead ID → 404/403 | Response correlation |
| **Unique input fields** (email, idempotency key) | Second VU collides → 409 | Test-data parameterization |

### 7a — Response correlation

Extract a value from one response at runtime and inject it into a later request, **per VU**,
so each VU threads its own freshly-created IDs through the workflow.

- [ ] `--correlate "AddTodo.response.reports.0.id -> ToggleTodo.body.nd"` — explicit rule:
      `<producer>.<source-path> -> <consumer>.<target-path>`. Source paths: `response.<json-path>`,
      `response.header.<name>`. Target paths: `body.<json-path>`, `query.<name>`, `path` (regex
      capture). Repeatable. Chained creates (A→B→C) work because each VU's variable table is
      updated in request order.
- [ ] `--correlate-scan` — a single pre-run baseline pass (no load) that indexes every value
      appearing in a response body and finds values that reappear in a later request. Prints
      ready-to-paste `--correlate` flags for each candidate. Same move as JMeter's correlation
      recorder / the Gatling recorder — the tool proposes, the human confirms.
- [ ] Optional `x-jac-correlate` HAR annotation — a per-entry custom field honoured on every
      run, for teams that want to annotate a HAR once and commit it.
- [ ] `core/correlation.jac` — extraction/injection engine, per-VU variable table, applied in
      `_send_request` before dispatch. No-op when no rules and no annotations are present.
- [ ] `RequestResult` gains `correlation_applied: list[str]` for debug output.
- [ ] Tests: chained create/update/delete against a fixture server; regex path capture;
      missing-source-value handling (fail the consumer request with a clear `CORRELATION_MISS`
      error, don't send a literal `{{...}}`).

### 7b — Per-VU account pool (closes issue #20 H5)

- [ ] `--accounts accounts.csv` — CSV with a header row; `username,password` required, extra
      columns exposed to parameterization as `{{account.<col>}}`. Each VU is assigned a row
      (round-robin if VUs > rows, with a one-time stderr warning), logs in as that identity on
      the controller before the replay loop, and replays with its **own** token.
- [ ] Multiprocess: the controller authenticates the whole pool before forking and hands each
      worker its VU-id→token slice (same pre-fork model as today's single login).
- [ ] Mutually exclusive with `--username`/`--password` (which stays the "same account as the
      recording" mode and remains the default for pure-throughput runs).
- [ ] Re-authentication on 401: when a request returns 401 mid-run, that VU re-logs-in once
      and retries the request once; a second consecutive 401 is a real `AUTH_EXPIRED` failure.
      Fixes the soak-test degradation documented in `CONSTRAINTS.md` §1.
- [ ] Report: per-VU auth failures broken out from application errors.

### 7c — Test-data parameterization (`CONSTRAINTS.md` §2)

- [ ] `--param "AddTodo.body.title=titles.csv"` — substitute a CSV column into a body/query
      field. Repeatable. Row selection follows the VU's account-pool row when `--accounts` is
      set, else round-robin by `(vu_id, iteration)`.
- [ ] Substitution tokens usable anywhere in a body/query/header value:
      `{{vu_id}}`, `{{iter}}`, `{{uuid}}`, `{{randint:a,b}}`, `{{now}}`, `{{now+Ns}}`,
      `{{account.<col>}}`, `{{env.<VAR>}}`.
- [ ] `core/parameterize.jac` — token + CSV substitution, applied alongside correlation.
- [ ] Warm-cache vs. diverse-query note added to the reporter when `--param` is in use.

### 7d — Randomized think time

- [ ] `--think-time gaussian` — draw each inter-request delay from `N(recorded_wait, stddev)`;
      `--think-time-stddev` (default: 25% of the mean), floored at 0.
- [ ] `--think-time-jitter P` — apply ±P% uniform jitter to `real`/`scaled` modes.

### 7e — Personas (manual, no AI)

Split the load across distinct user archetypes, each replaying its own subset of HAR entries.
Persona definitions are **authored by the user** (or generated by an external coding agent)
as a JSON file — there is no AI assignment step in the tool.

- [ ] `PersonaConfig`: `name`, `description`, `entry_indices: list[int]`, `vus: int`,
      `weight: float` (optional; alternative to absolute `vus`).
- [ ] `--persona-file personas.json` — list of `PersonaConfig`; mutually exclusive with `--vus`.
- [ ] `run_personas()` — per persona, filter the `HarEntry` list to `entry_indices`, launch a
      VU group; all personas share one `MetricsCollector` so aggregate numbers stay correct.
- [ ] `RequestResult.persona` — populated by the engine from the active persona.
- [ ] Reports group by `(persona, protocol, endpoint)`; JSON gains a `personas[]` section;
      HTML gains a Personas tab with per-persona summary + p95 bars.
- [ ] `personas.json` schema documented in `COMMANDS.md`, with a worked example.
- [ ] `run_test_headless()` accepts a `personas` config block (mirrors Phase 9's
      `ws_scenarios`/`graphql_scenarios`).

**Exit criterion:** 50 VUs, each a distinct account from `accounts.csv`, replay a
create→update→delete workflow with `--correlate` rules and complete with **0 ownership
errors**; a `--persona-file` run with "browser" (10 VUs, read entries) and "power user"
(20 VUs, write entries) personas reports separate p95 latency per persona.

---

## Phase 8 — Result Fidelity & Regression Gating 🔜

> Make the numbers trustworthy, and turn the tool into a CI regression gate for the jac-scale
> runtime itself. (Replaces the old "Automatic Endpoint Discovery + AI Persona Assignment"
> phase — the OpenAPI-import half of that work moves to Phase 10; the AI half is removed.)

### 8a — Infrastructure-block fidelity (issue #24)

All VUs egress from one source IP. A target-side WAF or rate limiter returns an identical
HTML `403`/`429` deny page, which today is counted as a per-endpoint *application* error and
pollutes the headline error rate.

- [ ] `INFRA_BLOCK_SUSPECTED` error class — raised when an identical non-JSON response body
      (hash-matched) appears across ≥ N distinct endpoints within one time bucket. Configurable
      via `--infra-block-threshold N` (default 3).
- [ ] Report: infra-block responses are counted and shown **separately**, subtracted from the
      headline error rate, with a footnote (`"142 responses (4.1%) classified as
      infrastructure blocks — not counted as application errors. Likely WAF/rate-limit."`).
- [ ] `--proxy-pool proxies.txt` — round-robin egress across an HTTP/SOCKS5 proxy list.
      Cheap partial mitigation and a poor-man's multi-IP ahead of Phase 11's real distribution.
- [ ] `CONSTRAINTS.md` §6 — single-source-IP behaviour documented (done in this revision).

### 8b — Correctness signal beyond HTTP status

jac-scale walkers routinely return HTTP `200` with the failure inside the JSON body. Status
checking answers "is the server up?", not "is it correct under load?".

- [ ] **jac-scale-aware body check (default, no config)** — parse the JSON body; flag as
      `APP_ERROR_IN_200` when it carries an `error`/`errors` key, an inner `status >= 400`, or
      an empty `reports` array where the recorded response for that endpoint had a non-empty
      one. Lives in `bridge/` (jac-scale-specific); toggle with `--no-body-check`.
- [ ] **Per-endpoint `--assert-json`** (`CONSTRAINTS.md` §5) — scoping syntax mirroring
      `--slo`: `--assert-json "/walker/AddTodo:reports.0.id=*"` (where `*` asserts presence).
      The existing global form keeps working.
- [ ] **Baseline shape capture + diff** — during the `--correlate-scan` baseline pass, record
      each endpoint's response shape (top-level keys, `reports` non-empty, inner status).
      Under load, flag structural divergence as `SHAPE_DRIFT` (warn, not fail, unless
      `--fail-on-shape-drift`).
- [ ] Report every class separately: transport / 5xx / 4xx / infra-block / app-error-in-200 /
      shape-drift / assertion-fail. A single "error rate: 3%" hides which one is happening.

### 8c — Run-to-run regression gate

The highest-value CI feature for the Jaseci team: catch a jac-scale runtime perf regression
before it merges.

- [ ] `--baseline prev.json` — load a prior `render_json()` report.
- [ ] `--fail-on-regression "p95:10%,p99:15%,error_rate:0.5pp,rps:-10%"` — exit `1` when any
      metric regresses past its tolerance vs. the baseline (percent, percentage-points for
      rates, or absolute). Per-endpoint and global.
- [ ] JSON report gains a `baseline_comparison` block; console prints a compact diff table;
      HTML gains a "vs. baseline" column with up/down arrows.
- [ ] `docs/` — a short "perf regression gate in CI" recipe (store baseline as a CI artifact,
      compare on each PR).

### 8d — Multiprocess result fidelity

Every capability below works correctly at `--workers 1` and silently changes meaning above it.
None of them are rejected by the CLI, so the run looks successful and the numbers look
plausible — they are just not the numbers the user asked for. Phase 7b already established the
right pattern (the controller pre-authenticates the whole account pool and hands each worker
its slice); 8d applies that rule retroactively to the features that shipped before it was
written down. The two primitives introduced here — a cross-process stop signal and mergeable
latency buckets — are the same two Phase 11 needs to abort a fleet and merge per-node latency,
so this is a local rehearsal of the distributed controller, not a detour from it.

- [ ] **Global `--abort-on-fail` decision.** Today each worker runs its own `_threshold_watcher`
      (`core/engine.jac`) against its own `MetricsCollector`, so the breach check sees one
      VU-slice of traffic and each worker stops at a different moment. Move the decision to the
      controller: workers push running counts up the existing result queue unconditionally (not
      only when a live-stream callback is attached), the controller merges and runs the single
      breach check, and a shared stop event fans the decision back out. The final exit-code gate
      in `cli.jac` already runs on merged data and is correct — only the mid-run abort is wrong.
      Uses a spawn-context `multiprocessing.Event`, the mechanism the web stop button already
      proves works (`jac_loadtest_web/web/services/run_walkers.jac`, `_RunStopSignal`).
- [ ] **Cross-process stop signal for the CLI.** Falls out of the item above and closes a gap
      nobody has filed: `cli.jac` passes no `stop_requested` to `run_multiprocess()` at all, so
      a multiprocess run currently has no clean way to be stopped from outside.
- [ ] **Exact live percentiles.** `_merge_snapshots()` (`core/process_runner.jac`) combines
      `total_requests`, `rps` and `error_rate_pct` exactly but averages p50/p95/p99 weighted by
      request count — finished percentiles cannot be averaged back into a percentile. Change
      what travels, not how it is combined: each worker sends fixed log-scale latency buckets
      plus counts, and the controller reads percentiles off the summed histogram. Error becomes
      bucket-width instead of unbounded, and the message stays a fixed small size at any VU
      count. Same data feeds the global breach check above — build them together. Affects the
      live SSE dashboard and any `on_snapshot` embedder; the final report is already exact.
- [ ] **`--max-samples` applied once.** The cap runs inside each worker and again at merge
      (`_merge_worker_results()`), so the retained window is not the one requested. Give each
      worker a share of the budget, spread the remainder, and let the merge keep what it
      receives. Optional follow-on: reservoir sampling so a long run's percentiles reflect the
      whole test rather than only its tail — that helps `--workers 1` too.
- [ ] **`--rps` split that adds up.** `_worker_fn` divides the budget as a float by VU share, so
      worker rates do not sum to the target. Split in whole units with largest-remainder
      distribution. Compensating for a *lagging* worker is deliberately **not** attempted — see
      the Phase 11 non-goal note. Instead, measure achieved rate against target and warn on
      drift, so the user is told the generator is the bottleneck rather than being misled.
- [ ] **`--step-load` under `--workers > 1`** — removes the `cli.jac` / `headless.jac` rejection.
      Two problems hide behind it. The small one: `MetricsCollector.step_results` never leaves
      the worker, because the queue message carries only `_samples` and `samples_evicted`. The
      large one: N workers would each run a private ramp and judge their own slice. Cheap fix
      (do this one) — every worker ramps its own share on the shared `t_start` and the same
      `step_duration`, so steps stay in lockstep, and the controller merges the per-step records
      by step number and recomputes each window's error rate and p95 from combined samples. The
      controller-driven ramp (controller commands workers to add VUs) needs a controller→worker
      command channel and mid-run sample flushing — deferred to Phase 11, which builds that
      channel anyway. Ship the cheap version; build the channel only if steps drift in practice.

**Exit criterion for 8d:** the same test run at `--workers 1` and `--workers 4` produces the
same report shape and the same decisions — `--abort-on-fail` trips at the same breach on merged
traffic, live percentiles track the final report's, `--max-samples 100000` retains ~100k
samples not 4×, per-worker rates sum to `--rps`, and `--step-load` produces one step table.

**Exit criterion:** a run against a WAF-protected target reports the true application success
rate with the infra blocks footnoted out; a run whose p95 regressed 20% against a stored
baseline fails CI with a per-endpoint diff showing which endpoint moved; and the whole suite
above behaves identically at `--workers 4` as at `--workers 1` (8d).

---

## Phase 9 — GraphQL & WebSocket ◑

> First protocol expansion beyond HTTP. Engine adapters and HAR auto-detection are **done**;
> one CLI item remains. Web UI items are descoped by the freeze.

### CLI

- [x] `core/ws_engine.jac` — WebSocket VU coroutine: connect, send message sequence, record
      event-to-first-message latency and throughput; `ws://` and `wss://`. `WsScenarioConfig`
      + `parse_ws_scenarios()` + `run_ws_scenarios()`; one `RequestResult` per sent message,
      `protocol="ws"`.
- [x] `core/graphql_engine.jac` — `graphql-ws` handshake over the `ws_engine` primitive;
      subscription query, events/second, time-to-first-event latency; `max_events` cap;
      `GRAPHQL_ERROR`/`GRAPHQL_TIMEOUT`/`GRAPHQL_CONNECTION_ERROR` paths.
- [x] `RequestResult.protocol` (`"http"`/`"ws"`/`"graphql"`); `EndpointStats` grouped by
      `(protocol, endpoint)`; `Proto` column shown only when a run has non-HTTP samples.
- [x] `run_test_headless()` accepts `ws_scenarios` / `graphql_scenarios` blocks; runs HTTP
      entries and protocol scenarios concurrently in one `asyncio.run()` sharing one
      `MetricsCollector`; `har_file` optional when a scenario is given; rejected with
      `--workers > 1`.
- [x] **HAR-driven auto-detection** — `HarEntry.protocol` + `ws_messages`/`graphql_query`/…;
      previously-dropped `_resourceType: "websocket"` / `ws://` entries are parsed; GraphQL
      over HTTP and `graphql-ws` subscriptions sniffed from body/frames;
      `scenarios_from_har_entries()` converts tagged entries into scenario configs; `cli.jac`
      and `headless.jac` merge them automatically. A recorded WS/GraphQL connection replays
      with zero flags. `_webSocketMessages` capture is opportunistic (absent from plain Chrome
      HAR export; present from Playwright's recorder).
### Remaining

- [ ] `introspect_schema(url: str) -> dict` in `core/graphql_engine.jac` — sends the standard
      introspection query, returns the parsed schema; headless-callable. Low effort. Also
      lets the engine synthesise a valid `graphql-ws` `subscribe` frame from schema +
      operation name when a HAR recorded the connection but not the frame (see next item).

- [ ] **`--ws-scenario FILE` / `--graphql-scenario FILE`** — user-authored (or
      coding-agent-authored) scenario files, so a WebSocket/subscription test can run even
      when the HAR has no captured frames (the common case — a Chrome DevTools HAR export
      omits WebSocket frames entirely; see `CONSTRAINTS.md` §7). File shape: connect `url`,
      `subprotocol`, `vus`, an ordered `messages` list (`send` payload + optional `wait_ms`),
      and optional `expect_events` / reply matchers. The engine internals already exist
      (`WsScenarioConfig`, `parse_ws_scenarios()`, `run_ws_scenarios()` — Phase 9); this only
      adds the CLI flags + a documented file format, and merges the result with any
      HAR-auto-detected scenarios. **Small — pull forward, it unblocks WS testing now.**

- [ ] **Improve the "no frames to replay" warning** — when a HAR contains a WebSocket
      connection with no `_webSocketMessages`, the one-time stderr warning should tell the
      user what to do: record with `jac x loadtest record` (Phase 10b, captures frames), or
      supply `--ws-scenario`.

- [ ] **Multiprocess support for WS/GraphQL scenarios** — remove the `--workers 1`
      restriction. `core/process_runner.jac` already splits VUs across worker processes and
      merges every `RequestResult` (protocol-tagged) into one `MetricsCollector`; extend
      `_compute_slices()` to also slice each scenario's `vus`, move
      `scenarios_from_har_entries()` detection to the controller and pass the configs to
      workers alongside the HAR entries, and have the worker entry point call
      `run_all_protocols()` instead of just `run_all_vus()`. Medium effort, low risk.
      Both `run_ws_scenarios()` and `run_graphql_scenarios()` already accept a `vu_id_offset`,
      and every sample already carries `RequestResult.protocol`, so the merge and the
      per-protocol breakdown need no change at all.
      **Depends on Phase 8d**, which makes the same worker entry point call
      `run_all_protocols()`; if 8d lands first this shrinks to slicing each scenario's `vus`.
      **Lower urgency** than HTTP multiprocess — an idle WS connection is cheap, so one event
      loop already holds a few thousand concurrent subscriptions; this only matters past
      ~1–2k concurrent *active* WS VUs.

**Exit criterion:** a run that simultaneously hammers a REST endpoint with 50 VUs and holds
20 concurrent GraphQL subscriptions shows unified metrics in one report. ✓ (bar the remaining
items above)

---

## Phase 10 — Auth Adapters & Recording-Free Authoring ⬜

> Broaden past jac-scale's exact auth envelope and past the Chrome DevTools HAR round-trip.
> (Absorbs the non-AI half of the old Phase 8: OpenAPI/Swagger import.)

### 10a — Pluggable auth (`CONSTRAINTS.md` §4)

`bridge/auth.jac`'s `AuthProvider` is already the single seam. Add adapter selection there;
the engine and process runner stay unchanged.

- [ ] `--auth-type {jac-scale|bearer|basic|apikey|oauth2-cc|none}` (default `jac-scale`).
- [ ] `--auth-header NAME` + `--auth-value VALUE` — static API-key / bearer injection.
- [ ] `--auth-token-path PATH` — override the login-response JSON path (default
      `data.token`), for jac-scale servers with a customised auth envelope.
- [ ] `--auth-body-template FILE` — a JSON template (with substitution tokens) for the login
      request body, for non-standard login shapes.
- [ ] `--auth-adapter mypackage.auth:MyAdapter` — import a class implementing
      `async authenticate(vu_id, session, base_url) -> str`. The escape hatch for anything
      unusual (multi-step OAuth, signed requests, …).
- [ ] Tests: bearer, basic, apikey-header, apikey-query, custom token path, custom body
      template, adapter import.

### 10b — Built-in proxy recorder

- [ ] `jac x loadtest record --port 8080 --out recording.har [--scope https://staging.myapp.com]`
      — a mitmproxy-style forward proxy that writes a HAR 1.2 file directly. `--scope` filters
      captured requests to matching origins. Removes the DevTools "record → export → find the
      file" round-trip. Same tier as JMeter's / Gatling's / k6 Studio's built-in recorders.
- [ ] **Captures WebSocket frames** (send *and* receive) and GraphQL-over-WS payloads into
      `_webSocketMessages` — the frames a Chrome DevTools HAR export drops (`CONSTRAINTS.md`
      §7). This makes the proxy recorder the **recommended way to record any test involving
      WebSocket or GraphQL-subscription traffic**.
- [ ] `core/proxy_recorder.jac` — headless-callable (`start_recorder()` / `stop_recorder()`).
- [ ] Emits the same `HarEntry` shape `parse_har()` produces; the rest of the pipeline is
      unchanged.
- [ ] Optional `--via cdp` — attach to a running Chrome over the DevTools Protocol
      (`Network.webSocketFrame*` events) and assemble a full-fidelity HAR with no MITM
      certificate to trust. Needs a Chrome instance; higher fidelity, zero proxy setup.
- [ ] Security: warns on captured `Authorization`/`Cookie` headers; `--redact-headers` to
      strip them from the written file.

### 10c — OpenAPI / Swagger import (no AI)

- [ ] `jac x loadtest from-spec openapi.yaml --out recording.har` — and
      `parse_api_spec(source: str) -> list[dict]` headless-callable.
- [ ] `core/spec_parser.jac` — accepts a URL or file; parses OpenAPI 3.0 / 3.1 / Swagger 2.0
      (YAML or JSON); synthesises `HarEntry`-compatible entries (method, path, example body
      from the schema's `example`/`default`, status 200).
- [ ] Path templating (`/pets/{petId}`) is preserved and exposed to correlation /
      parameterization so a real ID can be substituted at runtime.

**Exit criterion:** load test an API-key-authenticated non-jac-scale service end to end;
generate a runnable HAR from an OpenAPI URL with no browser and no DevTools.

---

## Phase 11 — Distributed Load Generation ⬜

> Break the single-machine VU ceiling (`CONSTRAINTS.md` §3) and get genuine multi-IP egress
> for issue #24. (`--engine k6` is not pursued — a native controller/worker model keeps the
> report format, auth bridge, and metrics pipeline intact.)

### CLI

- [ ] `jac x loadtest worker --port N` — a lightweight `aiohttp` server accepting
      `POST /start` (config JSON + HAR entries), running `run_multiprocess()` locally, exposing
      `GET /health` and `GET /results`, and pushing `StatsSnapshot` updates back to the
      controller via long-poll.
- [ ] `--worker-nodes [region:]host:port,...` on the controller — split `--vus` across nodes
      (each gets a `vu_id_offset` for globally unique IDs), pre-authenticate the whole account
      pool on the controller and send each node its token slice, `GET /health` preflight
      (abort with a clear error if any node is down), merge all node results into one
      `MetricsCollector`.
- [ ] Region-labelled aggregation — the merged report groups per-node latency by the optional
      `region:` label, so "which region is slow" is a report field.
- [ ] mDNS discovery — `jac x loadtest worker --discover` advertises; controller
      `--discover` finds and lists nodes.
- [ ] Docs: a `docker-compose` example (one controller + N worker containers).
- [ ] Controller→worker command channel (add-VUs, stop) — also unblocks the controller-driven
      `--step-load` ramp deferred here from Phase 8d.
- [ ] Reuse Phase 8d's primitives over the network: the shared stop signal becomes a
      fleet-wide abort, and the mergeable latency buckets become the per-node/per-region merge.

**Non-goal — globally coordinated request pacing.** Neither across processes (Phase 8d) nor
across nodes. Compensating for a lagging worker requires every worker to check a shared rate
budget before every request, putting coordination on the hottest path in the tool; it would
cost more throughput than it recovers. `--rps` stays an exactly-split per-worker budget, with
achieved-vs-target drift surfaced in the report instead.

**Exit criterion:** a 5,000-VU test split across 3 worker nodes in different network segments
produces one unified report with per-region latency, and issue #24 no longer trips because
egress is spread across the nodes' distinct IPs.

---

## Phase 12 — Release & jac-scale Integration ⬜

> Ship it: PyPI, observability integration, and the fold into jac-scale that makes this a
> framework feature instead of a side tool.

### 12a — Observability sinks

- [ ] `--output prometheus` — expose a `/metrics` endpoint (or push via remote-write) with
      live gauges/histograms during the run, for scraping into Grafana.
- [ ] `--output influxdb --output-url ...` — line-protocol writes (k6's default Grafana path).
- [ ] `--output otlp --output-url ...` — OTLP metrics export.
- [ ] All three are additive to the existing console/JSON/HTML report; streamed from the same
      `StatsSnapshot` tick.

### 12b — Report formats & plugin surface

- [ ] `output/reporter.jac`: `render_junit()` + `--report-format junit` — one `<testcase>`
      per endpoint (or per threshold), for Jenkins / GitLab / Azure DevOps.
- [ ] `ProtocolAdapter` ABC — the Python interface every engine adapter (`http`, `ws`,
      `graphql`, and any third-party one) implements.
- [ ] Plugin registry — discovers installed adapters via Python entry-points (mirroring how
      `[entrypoints.scripts]` already exposes `loadtest`), so `run_test_headless()` / `cli.jac`
      dispatch without a hardcoded import list.
- [ ] One reference third-party adapter (e.g. Redis) as its own installable package depending
      on `jac-loadtest-cli`, proving the seam.

### 12c — Release

- [ ] `README.md` + `jac.toml` metadata polished (classifiers, description, license, version).
- [ ] Publish to PyPI as `jac-loadtest-cli` (`jac build --as wheel && twine upload dist/*`).
- [ ] Docker image — CLI only: `jac x loadtest` as the entrypoint.
- [ ] GitHub Actions plugin `jaseci-labs/jac-loadtest-action@v1` — runs a test, posts pass/fail
      + key metrics (and the baseline diff from Phase 8c) as a PR comment.

### 12d — jac-scale integration (the Stage 2 goal from `INTRO.md`)

- [ ] Move `jac_loadtest_cli/core/` and `output/` into `jac-scale/jac_scale/loadtest/`.
- [ ] `bridge/auth.jac` gains an in-process path — call `UserManager` directly, no HTTP login.
- [ ] `bridge/topology.jac` reads the in-memory `ServiceRegistry`, no disk read.
- [ ] Expose `loadtest` as a console script from jac-scale's own package;
      `jac install jac-scale[loadtest]`. The command name never changes.
- [ ] Deprecate the standalone package (keep it as a thin shim for one release).

**Exit criterion:** `jac install jac-scale[loadtest] && jac x loadtest --help` works from a
jac-scale install; the Jaseci CI pipeline gates jac-scale runtime performance regressions with
`--baseline` + `--fail-on-regression`; live metrics stream into a Grafana dashboard during a run.

---

## Phase 13 — Extended Protocols (demand-driven) ⬜

> gRPC, database, and MQTT adapters. **Build each only when a real user asks for it.** The
> engine seam (`ProtocolAdapter` ABC, Phase 12b) makes these additive — none of them changes
> the HTTP engine.

- [ ] `core/grpc_engine.jac` — unary / server-streaming / client-streaming / bidi;
      `.proto` parsing via `parse_proto(source) -> dict` (headless-callable); gRPC status-code
      breakdown; TLS config.
- [ ] `core/db_engine.jac` — PostgreSQL / MySQL / **MongoDB** (jac-scale's own datastore);
      connection-pool load testing (pool utilisation %, exhaustion events); transaction
      scenarios; `preview_query(connection_config, query) -> dict` headless entry point;
      parameterized queries via the Phase 7c token engine.
- [ ] `core/mqtt_engine.jac` — MQTT 3.1.1 and 5, QoS 0/1/2; publish/subscribe delivery
      latency, connection drops, message-loss rate.
- [ ] Mixed-protocol step lists in `run_test_headless()` — interleave adapters in one
      scenario; dependency chaining reuses the Phase 7a correlation engine.

**Exit criterion:** a scenario that logs in via HTTP, opens a WebSocket subscription, inserts
a row into PostgreSQL, calls a gRPC method, and verifies the subscription received the event —
measured end to end.

---

## Milestone Summary

| Milestone | Phase | Deliverable |
|-----------|-------|-------------|
| M1 | 0 | `jac x loadtest --help` works |
| M2 | 1 | HAR replay + console report |
| M3 | 2 | Per-VU JWT injection + username/password auth |
| M4 | 3 | Per-service routing + breakdown |
| M5 | 4 | Graceful shutdown, thresholds, exit codes, RPS cap |
| M6 | 5 | JSON + HTML reports, p99.9, Apdex, TTFB |
| M7 | 6 | `LoadTestConfig.from_dict()`, `run_test_headless()`, web MVP |
| **M8** | **7** | **Response correlation, per-VU account pool, test-data feeders, manual personas** |
| **M9** | **8** | **`INFRA_BLOCK_SUSPECTED`, body-level correctness checks, `--baseline` regression gate, multiprocess result fidelity** |
| M10 | 9 | `ws_engine.jac`, `graphql_engine.jac`, HAR auto-detect — done; `introspect_schema()` open |
| M11 | 10 | Pluggable auth adapters, `jac x loadtest record`, OpenAPI import |
| M12 | 11 | `--worker-nodes`, `jac x loadtest worker`, mDNS discovery, region aggregation |
| M13 | 12 | PyPI, Prometheus/InfluxDB/OTLP sinks, `render_junit()`, plugin registry, `jac-scale[loadtest]` |
| M14 | 13 | gRPC / DB / MQTT adapters (demand-driven) |

---

## Protocol Support Target

| Protocol | Phase | Adapter | Status |
|----------|-------|---------|--------|
| HTTP/HTTPS | 0–5 | `core/engine.jac` | Done |
| GraphQL (query/mutation) | 9 | `core/graphql_engine.jac` | Done |
| GraphQL subscriptions | 9 | `core/ws_engine.jac` (graphql-ws) | Done |
| WebSocket (raw) | 9 | `core/ws_engine.jac` | Done |
| gRPC | 13 | `core/grpc_engine.jac` | Demand-driven |
| PostgreSQL / MySQL / MongoDB | 13 | `core/db_engine.jac` | Demand-driven |
| MQTT | 13 | `core/mqtt_engine.jac` | Demand-driven |
| Redis / Kafka / AMQP | 12+ | Community plugin against the `ProtocolAdapter` registry | Not started |

---

## Removed from the roadmap (this revision)

| Removed | Was | Why |
|---|---|---|
| AI persona assignment (`core/persona_ai.jac`, `PersonaSelection`, `by-llm`) | Phase 8 Pillar 2 | A generic coding agent generates a `personas.json` more flexibly than a bespoke in-tool agent. Personas stay — as a hand/agent-authored JSON file (Phase 7e). |
| `by-llm` browser agent (`core/browser_agent.jac`, `BrowserAction`, `decide_next_action`, Playwright) | Phase 8 Pillar 1C | Same reasoning. A coding agent can drive Playwright to produce a HAR; the tool ships a non-AI proxy recorder (Phase 10b) instead. |
| `[plugins.byllm]` config, `jac-byllm` dependency, `MockLLM` tests, `jac-loadtest-cli[discovery]` extra | Phase 8 | No AI features remain. Dependency footprint stays `aiohttp` / `rich` / `requests` — no LLM SDK, no browser binary. |
| `--engine k6` high-scale backend | Phase 6 H4 / `CONSTRAINTS.md` §3 | A k6 shim forks the report format, auth bridge, and metrics pipeline. Native controller/worker (Phase 11) is the scale-out answer. |
| Per-phase web checklists (Phases 7–12) | throughout | Web is frozen at the Phase 6 MVP — see below. Capabilities land CLI + headless; a future GUI wraps them. |

---

## Web App Status

`jac-loadtest-web` is **frozen at its Phase 6 MVP.** It is a working browser GUI for standard
HTTP load testing (auth, workspace wizard, HAR upload, run form, live SSE dashboard,
JSON/HTML download) and it stays at that scope.

- No new web features are planned. The `jac_loadtest_web/docs/` roadmap now points here.
- Every Phase 7+ capability is built CLI + headless engine only. The headless contract
  (`LoadTestConfig.from_dict()`, `run_test_headless(...)`, `render_json()`, `render_html()`)
  is stable, so if the web app is ever resumed it wraps the new engine functions with thin
  `sv` walkers — no engine rewrite.
- If you need correlation, per-VU accounts, personas, regression gating, distributed load, or
  any protocol beyond HTTP/WS/GraphQL today: use the CLI.
