# jac-loadtest Combined Roadmap

A unified delivery plan covering both `jac-loadtest-cli` (the engine) and `jac-loadtest-web`
(the visual frontend). Each phase lists what must be built at the CLI level and what must be
built at the web level, in dependency order.

---

## Architecture Principle

**Every core feature lives in the CLI (`jac_loadtest_cli`).** "Core feature" means anything
that generates load, makes a decision, produces or shapes a result, or talks to a target
system — protocol adapters, persona replay logic, endpoint discovery (spec parsing, browser
automation), AI-assisted decisions (persona assignment, browsing choices), schema
introspection, worker coordination, report rendering in every format. None of that is ever
implemented as `sv`-side business logic. This has been true since Phase 0 for the HTTP engine
and stays true for every capability added from Phase 7 onward — **as of this revision, phases
7 and 8 have been re-scoped from their original "lives in the web layer" design specifically
to bring them in line with this principle** (see the note at the top of each).

The web app (`jac-loadtest-web`) is a presentation and orchestration shell — nothing more. Its
`sv` walkers exist only to: call a CLI headless entry point (`headless.jac`, or a
headless-style function alongside it — same no-argparse, no-`sys.exit()`, plain-data-in/
plain-data-out contract), persist the resulting records as jac-scale nodes, and stream
progress over SSE. Its `cl` pages exist only to collect user input (forms, file uploads,
buttons) and render whatever the CLI returned (tables, charts, logs). A `sv` walker containing
a decision, a parser, a state machine, or a call to an LLM/browser/target system is a bug in
this architecture, not a design choice — that logic belongs in `jac_loadtest_cli` instead,
exposed as a plain function the walker calls. **The engine is never rewritten; it is only
extended.**

```
Browser (cl codespace — Vite/React)        ←  web phases — forms, uploads, buttons,
                                                tables/charts/logs. Zero decision logic.
  ↕ HTTP walker calls (jac-client fullstack)
jac-loadtest sv walkers (sv codespace)     ←  web phases — thin adapters ONLY:
                                                call a CLI headless function, persist
                                                the result, stream progress. No parsing,
                                                no LLM calls, no protocol clients here.
  ↓ imports as Python module, calls a headless-style function
jac-loadtest engine (jac_loadtest_cli)     ←  CLI phases — ALL core logic: protocol
                                                adapters, persona replay, endpoint
                                                discovery, AI decisions, worker
                                                coordination, every report format
  ↓ extended by
Protocol / capability adapters              ←  CLI phases (per protocol/capability)
```

---

## Phase Status Overview

| Phase | Name | CLI | Web |
|-------|------|-----|-----|
| 0 | CLI Foundation | ✓ Done | — |
| 1 | CLI MVP | ✓ Done | — |
| 2 | CLI Auth + Think Time | ✓ Done | — |
| 3 | CLI Microservice Mode | ✓ Done | — |
| 4 | Production Hardening | ✓ Done | — |
| 5 | Reporting & Polish | ✓ Done | — |
| 6 | Web MVP | Minor extensions — done | Full UI shell — done |
| 7 | Persona-Based Testing | Not started — persona replay logic | Display/config only, once CLI ships |
| 8 | Automatic Endpoint Discovery + AI Persona Assignment | Not started — discovery + AI logic (re-scoped from web/sv, see phase note) | Display/trigger only |
| 9 | GraphQL & WebSocket | Partially done — engine adapters shipped, HAR auto-detection shipped; schema introspection still open | Protocol UI — not started |
| 10 | gRPC & Database Connections | Not started — protocol/DB adapters, `.proto` parsing, query preview | Editors/panels only |
| 11 | Distributed Testing | Not started — worker coordination, MQTT adapter | Status/management display only |
| 12 | Release & Ecosystem | Not started — PyPI, jac-scale integration, report formats, plugin registry | Not started — thin CI trigger, Docker, UX polish |

---

## Phase 0 — CLI Foundation ✓

> Repo skeleton and import tree wired before any logic is written.

### CLI
- [x] `jac_loadtest_cli/` package with `core/`, `bridge/`, `output/` layout
- [x] `jac.toml` with dependencies; `loadtest` console script declared via `[entrypoints.scripts]`
- [x] `plugin.jac` — argparse entry point exposed as the console script; `jac x loadtest --help` works
- [x] Empty module stubs; full import tree resolves from day one
- [x] `tests/` directory with `tests/fixtures/` and JAC test blocks

### Web
None — CLI must be functional before web development begins.

**Exit criterion:** `jac x loadtest --help` prints usage. ✓

---

## Phase 1 — CLI MVP (HAR replay + console report) ✓

> First working end-to-end path. No auth, no microservices.

### CLI
- [x] `core/har_parser.jac` — parse HAR 1.2, filter non-API entries, URL rewrite
- [x] `core/engine.jac` — asyncio VU coroutines, duration cap, `aiohttp.ClientSession`
- [x] `core/metrics.jac` — `RequestResult`, latency collection, p50/p95/p99
- [x] `output/reporter.jac` — Rich console table (per-endpoint rows + summary footer)
- [x] `config.jac` — `LoadTestConfig` dataclass + `parse_duration()`
- [x] `--url`, `--vus`, `--iterations`, `--timeout` CLI flags
- [x] `tests/unit/test_har_parser.jac` (47 tests), `tests/unit/test_metrics.jac` (21 tests)
- [x] GitHub Actions CI

### Web
None — web depends on a working engine.

**Exit criterion:** `jac x loadtest recording.har --url http://localhost:8000 --vus 10` completes and prints a summary table. ✓

---

## Phase 2 — CLI Auth + Think Time ✓

> VUs log in independently and replay sessions realistically.

### CLI
- [x] `bridge/auth.jac` — detect login entry, JWT injection, identity type inference
- [x] Shared credentials: `--username` / `--password` (all VUs, same account as HAR recording)
- [x] Think time: `--think-time none|real` with `--think-time-scale` multiplier
- [x] Ramp-up: `--ramp-up Ns` staggers VU startup
- [x] Three-layer config resolution (CLI → jac.toml → built-in defaults)
- [x] `tests/integration/test_auth.jac` (12 tests), `tests/unit/test_config.jac` (11 tests)

### Web
None — auth and think-time features are surfaced in the Web MVP UI (Phase 6).

**Exit criterion:** `jac x loadtest recording.har --username user --password pass` runs with 0 auth errors. 141 tests pass. ✓

---

## Phase 3 — CLI Microservice Mode ✓

> Route requests to the correct service process, report per-service breakdown.

### CLI
- [x] `bridge/topology.jac` — `TopologyRouter`, longest-prefix matching
- [x] `--mode microservice`, `--services-map JSON` flag
- [x] Auto-discovery from `./jac.toml` `[plugins.scale.microservices.routes]` + `JAC_SV_*_URL`
- [x] Fallback to `--url` (gateway) for unmatched paths
- [x] Per-service `RequestResult.service` field; per-service column in console reporter
- [x] `tests/unit/test_topology.jac` (18 tests), microservice-mode integration tests

### Web
None — microservice mode is surfaced in the Web MVP settings panel (Phase 6).

**Exit criterion:** `jac x loadtest recording.har --mode microservice --services-map '{...}'` reports per-service latency. ✓

---

## Phase 4 — Production Hardening

> Reliable under pressure: clean shutdown, CI-compatible exit codes, error classification.

### CLI
- [x] Graceful shutdown — two-signal model (implemented in Phase 1)
- [x] Exit codes: `0` = pass, `1` = threshold failed, `2` = config/tool error
- [x] Threshold enforcement: `--fail-on-error-rate N`, `--fail-on-p95 N`, `--fail-on-p99 N` — checked in `cli.jac` after report; prints `THRESHOLD FAILED: …` to stderr and exits 1
- [x] `--abort-on-fail` — `_threshold_watcher` async task in `engine.jac` sets `stop_requested` on first breach
- [x] `--threshold-start-delay Ns` — watcher skips checks until elapsed ≥ delay
- [x] RPS cap: `--rps N` — per-VU sleep of `vus/rps` seconds before each request in `_run_vu`
- [x] `--think-time scaled` — `config.think_time in ("real", "scaled")` branch in `_run_vu`
- [x] `--debug` flag: `_print_debug(result)` writes per-request line to stderr
- [x] `error_type` on `RequestResult`: `TIMEOUT`, `CONNECTION_REFUSED`, `DNS_ERROR`, etc.
- [x] Multi-process VU distribution: `--workers N` + `core/process_runner.jac`
- [x] `tests/integration/test_engine.jac` — iterations cap, TIMEOUT, CONNECTION_REFUSED, RPS cap, think_time scaled, debug mode, abort_on_fail (7 new tests, 148 total)

### Web
None — these CLI fixes are prerequisites for the web's threshold UI and debug panel.

**Exit criterion:** interrupted test still generates a partial report; `$?` correctly signals threshold failures; `jac test tests/integration/` passes.

---

## Phase 5 — Reporting & Polish

> Machine-readable output for CI, charts for humans.

### CLI
- [x] `StatsSnapshot` written every 10s; live Rich progress bar
- [x] JSON report: `--report-format json` → stdout or `--report-out` file
- [x] HTML report: `--report-format html --report-out <path>` — Chart.js charts
- [x] `--debug` flag: per-request lines to stderr
- [x] **p99.9 latency** — `EndpointStats.p999_ms`; console, JSON, HTML table + bar chart dataset; latency benchmark thresholds: good &lt;2000ms, bad &gt;10000ms
- [x] **Per-endpoint RPS** — `total / actual_duration_s` in `compute_endpoint_stats(actual_duration_s=)`; column in all three report formats
- [x] **Bytes received column** — `EndpointStats.bytes_received`; formatted as B/KB/MB in console and HTML; raw bytes in JSON
- [x] **Apdex score** — `(satisfied + 0.5 × tolerating) / total`; `--apdex-t N` flag (default 500ms); errors always frustrated; per-endpoint + global; colour-coded in all formats; summary card in HTML
- [x] `tests/integration/test_reporter.jac` (21 tests)
- [x] `tests/e2e/test_smoke.jac` — 5 tests: full pipeline, Apdex=1.0, per-endpoint RPS, console no-crash, p99.9≥p99

### Web
None — the reporting enhancements are surfaced in the web's results panel and dashboard (Phase 6).

**Exit criterion:** `jac x loadtest ... --report-format html --report-out report.html` produces a self-contained HTML file with charts; `jac test tests/e2e/` passes.

---

## Phase 6 — Web MVP

> Replace the CLI entirely for standard HTTP load testing. A user with no CLI experience
> can run a complete authenticated load test from a browser tab.

---

### Note on the jac.toml Config Layer in Web Mode

The CLI's three-layer config resolution calls `get_scale_config(project_dir=Path.cwd())`
to read `[plugins.scale.loadtest]` defaults from the target app's `jac.toml`. When the
web server runs (`jac serve` from `jac_loadtest_web/`), `cwd()` is the web project
directory — its `jac.toml` has no `[plugins.scale.loadtest]` section, so this layer
returns `{}` silently. The same applies to `_load_toml_routes()` in topology.jac.

**The toml layer is incidentally bypassed in web mode, but this is fragile.** The clean
fix (first CLI item below) is to add `LoadTestConfig.from_dict()` that constructs a
complete config from a plain dict with no toml lookup, no args parsing, and no
`get_scale_config()` call. All workspace and run settings come from the web database;
the sv walker builds the complete dict and passes it directly to the engine.

**Two separate auth systems exist and must never be confused:**

| Auth System | Purpose | Stored Where |
|---|---|---|
| Web app auth | Log in to the jac-loadtest website | jac-scale `UserManager` on the sv codespace |
| Load test target auth | VU credentials used to log into the *app being tested* | Workspace record (optional username/password — same account used during recording) |

---

### Data Models

These are the persistent records that the sv walkers create and read. They live as
jac-scale nodes in the sv codespace graph.

```
User  (managed by jac-scale built-in auth)
├── id
├── email
└── hashed_password

Workspace  (one user → many workspaces)
├── id
├── owner_id               ← User.id
├── name                   ← human label, e.g. "Checkout flow staging"
├── description            ← optional freetext
├── mode                   ← "monolith" | "microservice"
│
│   ── monolith fields ──
├── target_url             ← e.g. "http://staging.myapp.com"
│
│   ── microservice fields ──
├── services_map_json      ← JSON string, e.g. '{"order":"/walker/order","inv":"/walker/inv"}'
│                            keys starting with "/" are used as path prefixes directly
│
│   ── shared ──
├── har_file_path          ← server-side path to uploaded .har file
├── har_entries_json       ← parsed + filtered entries stored as JSON for quick load
├── username               ← optional; must match the account used during HAR recording
├── password               ← optional; paired with username (never stored plaintext)
├── login_path             ← default "/user/login"; overridable per workspace
├── include_static         ← bool; include image/font/CSS entries in replay
├── created_at
└── updated_at

LoadTestRun  (one workspace → many runs)
├── id
├── workspace_id
├── label                  ← optional human name, e.g. "50 VUs smoke test"
│
│   ── engine settings (all map directly to LoadTestConfig fields) ──
├── vus                    ← int
├── duration               ← str, e.g. "60s"
├── iterations             ← int (stop per-VU after N replays)
├── ramp_up                ← str, e.g. "10s"
├── workers                ← int (multiprocess worker count)
├── rps                    ← int (0 = unlimited)
├── think_time             ← "none" | "real" | "scaled"
├── think_time_scale       ← float
├── timeout                ← str, e.g. "30s"
├── max_samples            ← int
│
│   ── thresholds ──
├── fail_on_error_rate     ← float | None  (percent)
├── fail_on_p95            ← float | None  (ms)
├── fail_on_p99            ← float | None  (ms)
├── abort_on_fail          ← bool
├── threshold_start_delay  ← str
│
│   ── lifecycle ──
├── status                 ← "pending" | "running" | "completed" | "failed" | "stopped"
├── started_at
├── completed_at
├── passed_thresholds      ← bool | None
└── results_json           ← full JSON report from render_json(); populated on completion
```

---

### CLI

These additions make the engine callable from the sv codespace without any CLI context
or jac.toml lookups.

- [x] `LoadTestConfig.from_dict(d: dict) -> LoadTestConfig` — construct directly from a
      plain dict using `BUILT_IN_DEFAULTS` for any missing keys; **no `_load_toml_defaults()`
      call, no `get_scale_config()`, no argparse**. This is the canonical web entry point
      into the config layer.
- [x] `run_test_headless(config: LoadTestConfig, on_snapshot=None, stop_event=None,
      on_html_report=None) -> dict` — public Jac function; runs the full engine
      (`run_multiprocess` or `run_all_vus`), calls `on_snapshot(snapshot)` after each
      10s tick so the sv walker can push SSE events, checks `stop_event` between
      requests so a run can be cancelled early (`run_walkers.jac`'s `stop_run` sets
      this), and hands the rendered HTML report to `on_html_report(html)` so
      `run_walkers.jac` can persist `results_html` without calling `render_html()`
      itself — returns the JSON-serialisable result dict produced by `render_json()`.
      No `sys.exit()`, no Rich console output, no file writes — caller controls all I/O.
- [x] `stream_metrics_callback` parameter wired into `run_all_vus()` and
      `run_multiprocess()` — called with each `StatsSnapshot` object; no-op when `None`.
- [x] Verify `render_json()` and `render_html()` are importable as plain Python functions
      with no CLI context required (no `sys.argv`, no Rich console initialisation at
      import time).
- [x] **TTFB breakdown** — separate Time To First Byte from total latency via aiohttp
      trace API (`aiohttp.TraceConfig`); adds `ttfb_ms` field to `RequestResult`,
      `EndpointStats`, JSON report, and HTML summary card

**Issue #18 — Load-test harness defects (B-series) and capability gaps (H-series).**
Audited upstream against three real load-test runs against jac-scale apps; fixes and
new capacity-testing capabilities landed directly in the CLI engine, config, and
reporting layers. Full flag reference in `docs/COMMANDS.md`.

- [x] **B1** — timeouts no longer inflate p95/p99: the `TIMEOUT` error path now sets
      `latency_valid=False` so the fabricated timeout-length latency is excluded from
      percentile aggregation (`core/engine.jac`).
- [x] **B2** — `rps` read from `jac.toml` no longer silently truncates fractional
      values to `0`; `LoadTestConfig.rps` now resolves through a float-aware resolver
      (`config.jac: _resolve_float`).
- [x] **B3** — long runs that exceed `--max-samples` now warn once on stderr when
      sample eviction begins, and every report format surfaces `samples_evicted` /
      `window_limited` so percentiles are never silently misread as covering the
      full run (`core/metrics.jac`, `output/reporter.jac`).
- [x] **B4** — added non-cumulative per-interval timeseries
      (`generate_interval_timeseries()`, `interval_timeseries` report field)
      alongside the existing cumulative series, so a burst confined to one bucket
      is visible without hand-differencing consecutive points.
- [x] **H7** — response trace-ID capture: `extract_trace_id()` reads
      `traceparent`/B3/X-Ray/request-id headers, surfaced on `RequestResult.trace_id`
      and in error breakdowns for jumping from a red cell straight into a trace backend.
- [x] **H1** — `--open-loop` fixed-arrival-rate mode: launches new sessions on a fixed
      schedule instead of pacing each VU from its own completions, so a slow target
      shows growing concurrency instead of a silently degrading achieved rate
      (`core/engine.jac: _run_open_loop`, `_run_iteration`).
- [x] **H3** — `--step-load` / ramp-to-failure mode: steps VU count up on a timer,
      evaluates each step's own traffic window against `--fail-on-*` thresholds, and
      reports the capacity knee — the last VU count that passed
      (`core/engine.jac: _run_step_load`, `StepResult`).
- [x] **H9** — `--slo` per-endpoint latency SLO overrides for report ratings, so a
      slow-but-fine LLM-backed endpoint and a fast health-check endpoint aren't judged
      against the same global bar (`output/reporter.jac: parse_slo_map`).
- [x] **H8** — `--assert-json PATH=VALUE` JSON response-body assertions as an
      additional, optional success condition beyond the HTTP status code, closing the
      gap where a `200` carrying `{"ok": false}` always counted as success
      (`core/engine.jac: parse_assert_json`, `_check_json_assertions`).
- [x] **H2** — `--duration` fixed wall-clock measurement window: implemented as a
      `_duration_watcher` task that sets the existing `stop_requested` event once
      elapsed — every run mode (`_run_vu`, `_run_open_loop`, `_run_step_load`)
      already loops on that event, so no run-mode loop changes were needed.
      Setting `--duration` without an explicit `--iterations` resolves
      `config.iterations` to `None` (unbounded), so run length is a fixed,
      comparable window instead of `vus × iterations × replay time`. Not
      compatible with `--step-load` (`config.jac: _resolve_iterations`,
      `core/engine.jac: _duration_watcher`).
- [x] **B5** — `--csrf` CSRF token detection and injection: after every response,
      scans `Set-Cookie` for a `csrftoken`/`_csrf` cookie and injects it as
      `X-CSRFToken` on subsequent non-GET requests, per VU, rotating the value
      whenever a later response sets a new one. Keyed per-VU via
      `csrf_token_by_vu` threaded through the same dispatch paths as the
      existing per-VU auth token (`core/engine.jac: _send_request`).
- [ ] **H4** — k6/high-scale load-generator backend remains open; scope/priority
      not yet decided.
- [ ] **H5** — per-VU auth (distinct token per VU instead of one shared token per
      run) remains open; scope/priority not yet decided.
- H6 (WebSocket/SSE coverage) is tracked under Phase 9 — GraphQL & WebSocket, not
  here, since that phase already covers it.
- H4, H5 are tracked individually in follow-up issue #20.

---

### Web

#### Project Layout

```
jac_loadtest_web/web/
├── jac.toml                              ← project config (npm deps, jac-shadcn theme)
├── main.jac                             ← app entry point — mounts <App />
├── frontend.cl.jac                      ← root client component with router + routes
│
├── pages/                               ← route-level page components (.cl.jac)
│   ├── Login.cl.jac
│   ├── Register.cl.jac
│   ├── WorkspaceList.cl.jac
│   ├── WorkspaceCreate.cl.jac           ← multi-step wizard
│   ├── WorkspaceDetail.cl.jac           ← HAR viewer + run history
│   ├── RunCreate.cl.jac                 ← run settings form
│   └── RunDetail.cl.jac                 ← live dashboard + final report
│
├── components/                          ← reusable client components (.cl.jac)
│   ├── ui/                              ← jac-shadcn components (auto-generated, do not edit)
│   ├── WorkspaceCard.cl.jac
│   ├── HarEntryTable.cl.jac
│   ├── RunSettingsForm.cl.jac
│   ├── RunControl.cl.jac
│   ├── MetricsDashboard.cl.jac
│   ├── LatencyChart.cl.jac
│   ├── RpsChart.cl.jac
│   ├── ReportViewer.cl.jac
│   ├── ThemeProvider.cl.jac             ← shared dark/light theme context, mounted at app root
│   └── ThemeToggle.cl.jac               ← theme toggle button, in every protected page's header
│
├── services/                            ← server walkers/streams (plain .jac, addressed via
│   │                                       `root spawn <name>(...)`) — no auth walkers here;
│   │                                       the app runs on jac-scale's BUILT-IN auth endpoints
│   │                                       (/user/register, /user/login, /user/me, /user/logout)
│   ├── workspace_walkers.jac            ← create/list/get/update/delete workspace
│   ├── file_walkers.jac                 ← upload_har()
│   ├── run_walkers.jac                  ← create_run(), start_run(), stop_run(),
│   │                                       get_run(), list_runs(), delete_run(), get_run_html()
│   └── stream_walkers.jac               ← stream_metrics(run_id) → SSE
│
├── models/                              ← node / dataclass definitions (.sv.jac)
│   ├── workspace.sv.jac                 ← Workspace node
│   └── run.sv.jac                       ← LoadTestRun node
│
├── lib/                                 ← utility modules
│   ├── utils.cl.jac                     ← shadcn cn() helper
│   └── theme.cl.jac                     ← dark/light theme persistence (localStorage + <html> class)
│
└── styles/
    └── global.css                       ← Tailwind + jac-shadcn theme tokens
```

---

#### Web App Authentication

Runs entirely on jac-scale's **built-in** auth endpoints — an earlier revision of this
app had hand-rolled `register_user`/`login_user`/`logout_user`/`me` sv walkers backing
this section, but those were removed in favour of the framework's own `/user/*`
endpoints and client helpers (see `jac guide jac-cl-auth` / `jac-sv-auth`). No
app-level auth walkers exist in `services/` anymore.

- [x] Built-in `/user/register` endpoint — creates a jac-scale `User` node; called via
      `jacSignup(email, password)` (`@jac/runtime`), returns `{"success": ..., "error"?: ...}`
      (does **not** establish a session by itself)
- [x] Built-in `/user/login` endpoint — authenticates against jac-scale's identity store;
      called via `jacLogin(email, password)`, a plain `bool` that stores the JWT under
      `localStorage["jac_token"]` internally on success (no manual token plumbing needed)
- [x] Logout — `jacLogout()` clears the stored token client-side; jac-scale issues
      stateless JWTs with no server-side revocation list, so there's nothing to
      invalidate server-side (no custom `logout_user`/`me` walkers needed)
- [x] `cl` login page (`pages/Login.cl.jac`): email + password form; on success (`jacLogin`
      returns `True`) redirects to `/workspaces`
- [x] `cl` register page (`pages/Register.cl.jac`): email + password + confirm form;
      `jacSignup` then `jacLogin` with the same credentials (signup alone does not log in)
- [x] Auth guard: all `cl` routes except `/login` and `/register` are wrapped in
      `<AuthGuard redirect="/login">` (`@jac/runtime`, wired in `frontend.cl.jac`);
      unauthenticated requests redirect to `/login`
- [x] JWT attached to every `root spawn` walker call as `Authorization: Bearer <token>`
      header automatically by the generated client runtime

---

#### Workspace Management

**Create Workspace — Multi-Step Wizard**

Step 1 — Basic info:
- [x] Workspace name (required)
- [x] Description (optional)
- [x] Mode selector: **Monolith** / **Microservice** — determines which subsequent steps appear

Step 2 — Target (mode-dependent):
- [x] *Monolith*: single "Target URL" field (e.g. `http://staging.myapp.com`); validated
      with a reachability ping from the sv walker before proceeding
- [x] *Microservice*: service map builder — add rows of `service name → URL` pairs
      (or paste a raw JSON map); path prefix auto-derived or manually overridden per row;
      equivalent to `--services-map` JSON

Step 3 — HAR file:
- [x] Drag-and-drop or file picker for `.har` upload → multipart POST to `upload_har`
      sv walker → returns parsed entries preview
- [ ] Alternatively: proxy recorder — "Start Recording" button calls `start_proxy`
      sv walker (spins up a local HTTP proxy on configurable port); "Stop Recording"
      calls `stop_proxy`, which returns the captured entries directly
- [ ] URL scope filter for proxy: enter a base URL so only matching requests are captured
- [x] HAR entry viewer table: method, path, status code, MIME type, response time from
      recording; per-entry enable/disable toggle
- [x] HAR security warning banner when `Authorization` or `Cookie` headers are detected
- [ ] "Export recorded HAR" button — downloads the proxy capture as a `.har` file

Step 4 — Credentials (target app auth):
- [x] **None** — target app has no authentication; VUs send requests unauthenticated
- [x] **Single credential** — one username + password shared by all VUs, matching the
      account used when the HAR was recorded (maps to `--username` / `--password`)
- [x] Login path field (default `/user/login`; overridable)

Step 5 — Review & Create:
- [x] Summary card: mode, target, HAR entry count, credential mode
- [x] "Create Workspace" → `create_workspace` sv walker; redirects to workspace detail page

**Workspace Detail Page:**
- [x] HAR entry table with enable/disable toggles; "Save" persists the selection to
      `har_entries_json` on the workspace
- [ ] "Replace HAR" button — re-runs Step 3 of the wizard against the existing workspace
- [ ] "Update Credentials" button — re-runs Step 4
- [ ] Run history list: all `LoadTestRun` records for this workspace, sorted newest first,
      showing label, status badge, VUs, duration, p95, error rate, started_at — currently
      lists label, VUs, iterations, and status only, with no newest-first sort
- [x] "New Run" button → run create page
- [ ] Workspace settings panel: edit name, description, URL/services-map, login path,
      include_static
- [x] Delete workspace (with confirmation dialog)

---

#### Load Test Run

**Create Run Page (`/workspaces/{id}/runs/new`):**

The run form shows which settings it inherits from the workspace (greyed out, editable
via override) and which are run-specific.

*Inherited from workspace (display only, no override needed):*
- Mode, target URL / services map, HAR entries, credentials, login path

*Run-specific settings — required:*
- [x] VUs (virtual users) — integer input
- [x] Stop condition — **Iterations** (N replays per VU)

*Run-specific settings — optional (collapsible "Advanced" section):*
- [x] Ramp-up duration (default `0s`)
- [x] Worker processes (default: CPU count)
- [x] RPS cap (default: 0 = unlimited)
- [x] Think time: None / Real / Scaled + scale multiplier
- [x] Per-request timeout (default `30s`)

*Thresholds (collapsible):*
- [x] Fail if error rate exceeds N%
- [x] Fail if p95 latency exceeds N ms
- [x] Fail if p99 latency exceeds N ms
- [x] Abort immediately on first threshold breach (checkbox)
- [x] Threshold evaluation delay (default `0s` — cold-start protection)

- [x] *Label:* optional freetext name for this run (e.g. "50 VU smoke test")

**"Start Run" button:**
- [x] `create_run` walker (`services/run_walkers.jac`): creates a `LoadTestRun` node
      with `status = "pending"`; returns `run_id`
- [x] `start_run` walker (`services/run_walkers.jac`): builds `LoadTestConfig` via
      `_build_config(...)`; hands the engine off to a background thread
      (`flow _execute_run(...)`) calling `jac_loadtest_cli.headless.run_test_headless()`
      so the HTTP request returns immediately; sets `status = "running"`; returns
      `{"ok": true, "stream_url": ...}`
- [x] `cl` redirects to run detail page immediately after `start_run` succeeds
      (`pages/RunCreate.cl.jac`)

**Run Detail Page (`/workspaces/{id}/runs/{run_id}`):**

*During run:*
- [x] Status bar: status badge (`RUNNING`/`COMPLETED`/`STOPPED`/`FAILED`, colour-coded)
      + elapsed time counter (`components/RunControl.cl.jac`)
- [x] Stop button → `stop_run` walker → engine graceful shutdown via a stop event
      checked between requests; sets `status = "stopped"`; partial report is still
      rendered from collected metrics
- [x] Live RPS counter and error rate badge (SSE, updated every ~10s snapshot tick)
- [ ] Ramp-up progress ring: live VU count rising to target during ramp-up — currently
      shown as a plain "Active VUs" number in `RunControl.cl.jac`, not a ring visual
      (the `Progress` primitive is imported there but unused)
- [x] RPS-over-time line chart (live SSE) — `components/MetricsDashboard.cl.jac`
- [x] p50/p95/p99 latency-over-time chart (live SSE) — `components/LatencyChart.cl.jac`
- [ ] Per-endpoint latency bar chart during a live run (updates every 10s) — the
      per-endpoint bar chart that exists today (`ReportViewer.cl.jac`) is post-run only
- [x] Error rate indicator: colour-coded badge, not a gauge — destructive (red) > 5%,
      default (amber) > 1%, secondary (green) otherwise (`RunControl.cl.jac`)
- [ ] Debug log panel (shown only when run was created with debug=true): per-request
      lines streamed via SSE

*After run completes or is stopped:*
- [x] Status badge changes to `COMPLETED` / `STOPPED` / `FAILED`
- [x] Threshold pass/fail summary banner (badge: "All thresholds passed" /
      "One or more thresholds failed" / "unavailable")
- [x] Full report rendered inline from `results_json` (`components/ReportViewer.cl.jac`):
      — Summary table: elapsed, VUs, total requests, RPS, success rate, error rate,
        p50/p95/p99/p99.9 latency, Apdex, p50/p95/p99 completion times
      — Latency-over-time chart + cumulative RPS-over-time chart
        (`components/RpsChart.cl.jac`)
      — Per-endpoint latency bar chart (p50/p95/p99/p99.9) and a full per-endpoint
        metrics table (reqs, RPS, OK%, latency percentiles, Apdex, completions, errors)
      — Error breakdown table
- [x] "Download JSON" button (browser Blob from `results_json`)
- [x] "Download HTML" button: `get_run_html` walker returns the stored `results_html`
      (rendered once, at run completion, via `render_html()` inside `run_test_headless`'s
      `on_html_report` callback — not re-rendered per download); browser triggers a
      file download
- [ ] "Re-run with same settings" button — the current "Re-run" button
      (`pages/RunDetail.cl.jac`) navigates to a blank `/runs/new` form; it does not
      yet pre-fill the previous run's settings

**SSE Streaming Architecture:**
- [x] `stream_metrics(run_id)` (`services/stream_walkers.jac`, a plain streaming `def`,
      not a walker — see note below): the `on_snapshot` callback registered in
      `run_test_headless()` writes each `StatsSnapshot` into a `queue.Queue`
      (`_stream_queues[run_id]`); `stream_metrics` polls that queue and sends
      `data: {json}\n\n` SSE frames (adding a derived `active_vus`); connection closes
      when the run ends
- [x] `cl` `MetricsDashboard` component subscribes to the SSE endpoint on mount
      (raw `fetch` + reader loop, not the walker RPC stub — streaming can't go through
      the buffered stub); unsubscribes when the run detail page unmounts or run status
      is terminal

---

**Exit criterion:** A user registers an account, creates a workspace (monolith mode,
uploads a HAR, optionally provides credentials), creates a load test run (50 VUs, 60s),
watches live RPS and latency charts in the browser, sees a threshold pass/fail summary,
and downloads an HTML report — without touching a terminal.

---

## Phase 7 — Persona-Based Testing

> Simulate realistic user behaviour by splitting the load across distinct user archetypes, each replaying their own subset of HAR entries.

**Architecture note:** this phase already fits the CLI-first principle as originally written
— all persona *replay* logic (filtering entries, launching VU groups, per-persona metrics)
is a `jac_loadtest_cli` engine change, reachable from the web layer only through
`run_test_headless()`/`headless.run_all_protocols()`-style entry points once `PersonaConfig`
support lands there too. The web layer's persona *builder* (name, description, which HAR
entries a persona covers, VU count) is genuine user input collection, not core logic — no
change needed to the CLI/Web split described below, just confirmation it already follows the
Architecture Principle above.

### CLI

- [ ] `PersonaConfig` dataclass: `name: str`, `description: str`, `entry_indices: list[int]`, `vus: int`
- [ ] `run_personas()` orchestrator: for each persona, filters `HarEntry` list to `entry_indices`, then launches a `run_all_vus()` coroutine; all personas share a single `MetricsCollector` so aggregate metrics are correct
- [ ] `RequestResult` gains `persona: str` field — populated by the engine from the active `PersonaConfig.name`
- [ ] `MetricsCollector.endpoint_stats()` groups results by `(persona, endpoint)` — console, JSON, and HTML reports include per-persona rows
- [ ] JSON report gains `"personas": [{ "name", "vus", "summary", "endpoints" }]` section
- [ ] HTML report gains a **Personas** tab with per-persona summary cards and p95 latency bars
- [ ] `--persona-file` flag: path to a JSON file defining persona list; mutually exclusive with `--vus` (persona mode replaces flat VU count)
- [ ] `run_test_headless()` gains a `personas` config block (mirrors Phase 9's `ws_scenarios`/`graphql_scenarios` pattern) so the web layer can start a persona-based run through the same headless entry point instead of a bespoke one

### Web

Config-collection and result-display only — every bullet below calls into the CLI bullets
above via a thin `sv` walker; none of them contain persona-splitting or metrics logic of
their own.

**Run Creation Page — mode toggle:**
- [ ] "Run mode" radio at the top of the run form: **Standard** (existing VU form, unchanged) | **Persona-based**
- [ ] Selecting Persona-based hides the flat VU count input and shows the persona builder panel

**Built-in personas (always available, read-only name and description):**
- [ ] **New User** — first-time visitor who explores the app cautiously; browses content, registers or logs in, performs one core action, then exits. Tends to hit onboarding and discovery endpoints.
- [ ] **Power User** — experienced user who navigates directly to their goal; performs complex multi-step workflows (create → update → delete) in rapid succession with minimal think time.
- [ ] **Casual Visitor** — bounces between a few pages without completing a core flow; high read-to-write ratio, short sessions, frequently hits list/search endpoints without acting on results.

**Persona builder panel (one card per persona):**
- [ ] Persona name + description — read-only for built-in personas; editable text fields for custom personas
- [ ] HAR entry selector: checklist showing every entry from the workspace HAR (`METHOD /path` rows); user ticks which entries this persona replays — unticked entries are not sent by this persona's VUs
- [ ] VU count input: absolute number of virtual users for this persona
- [ ] Collapse/expand toggle per card to manage screen space with many personas

**Persona management:**
- [ ] "Add Custom Persona" button — appends a blank persona card with empty entry selection
- [ ] Delete button on custom personas (built-in personas cannot be deleted)
- [ ] Total VU summary strip below the persona cards: `N personas · X total VUs · Y HAR entries covered`
- [ ] Validation: at least one persona must have VU count > 0 and at least one HAR entry selected before the run can start

**Remaining run settings (same for both modes):**
- [ ] Ramp-up, timeout, think-time, RPS cap, thresholds — identical controls as Standard mode, applied globally across all personas

**Run detail page:**
- [ ] Per-persona rows in the live endpoint table (persona name as first column)
- [ ] Final report section: per-persona summary cards showing VUs, RPS, error rate, p95

**Exit criterion:** A user creates a run in Persona-based mode, assigns login+browse entries to "New User" (10 VUs) and create+update entries to "Power User" (20 VUs), runs the test, and sees separate p95 latency per persona in the report.

---

## Phase 8 — Automatic Endpoint Discovery + AI Persona Assignment

> Two AI-powered capabilities: discover every endpoint the app exposes without manual effort, then let AI decide which endpoints belong to each persona.

**Re-scoped from the original design.** This phase was originally written with both pillars
living entirely in the `sv` codespace — spec parsing, Playwright browser automation, and every
`by-llm` call as `sv`-side business logic, with an explicit "the CLI gains no new code in this
phase" boundary. That contradicted the Architecture Principle at the top of this document:
spec parsing, browser automation, and AI decision-making are all core, target-facing logic,
not UI plumbing, so they don't belong in the web layer any more than the HTTP/WebSocket/
GraphQL engines do. Both pillars now live in `jac_loadtest_cli` instead, exposed as plain
headless-callable functions; the `sv` layer's job shrinks to calling those functions,
persisting results, and streaming progress — the same shape `run_walkers.jac` already uses
for a live load test in Phase 6 (`run_test_headless(..., on_snapshot=...)`).

**Consequence for CLI dependencies.** Today `jac_loadtest_cli`'s only third-party dependencies
are `aiohttp`, `rich`, and `requests` (see `jac.toml`). This phase adds real ones —
`jac-byllm` for both pillars, `playwright` (plus a browser binary download) for Pillar 1C. A
user who only wants HAR-replay load testing should not be forced to install either. These
should ship as optional extras (e.g. `jac-loadtest-cli[discovery]`) and be imported lazily
inside the discovery/AI modules, so `jac x loadtest recording.har ...` keeps working with zero
new dependencies for anyone who never touches those modules.

---

### Pillar 1 — Automatic Endpoint Discovery

**Goal:** give users three progressively automated paths to populate the workspace endpoint list. Every path ultimately produces the same thing: a list of `HarEntry`-compatible records. The run pipeline is identical regardless of which path was used.

#### Path A — HAR file upload (already built in Phase 6)
The existing workspace wizard HAR upload path already calls `core/har_parser.jac`'s
`parse_har()` and stores the result in `har_entries_json`. No new work — this path already
followed the CLI-first principle from day one. Displayed first in the discovery UI as the
recommended fast path.

#### Path B — API specification document

### CLI
- [ ] `core/spec_parser.jac` — accepts a URL or file path; fetches/reads and parses OpenAPI 3.0 / 3.1 or Swagger 2.0 YAML/JSON; emits a flat list of `{ method, path, summary, request_schema, response_schema }` records
- [ ] Synthesises `HarEntry`-compatible dicts from the spec (method, path, empty body, status 200) — same shape `parse_har()` already produces, so the rest of the pipeline (persona splitting, `run_all_vus()`, reporting) needs no changes
- [ ] Headless entry point (alongside `run_test_headless()` in `headless.jac`): `parse_api_spec(source: str) -> list[dict]` — plain function, no CLI context, no `sys.exit()`, callable from a `sv` walker exactly like `run_test_headless()` is today
- [ ] Accepted formats: OpenAPI 3.0, OpenAPI 3.1, Swagger 2.0

### Web
Thin wrapper around the CLI bullets above — no parsing logic on this side.
- [ ] Workspace creation wizard: **Discovery source** step added between HAR upload and credentials; options are **Upload HAR** (existing) | **API spec URL or file** | **Browser agent** (below)
- [ ] API spec option: URL text input (e.g. `https://api.example.com/openapi.json`) or file upload (`.yaml` / `.json`); "Import spec" calls a `sv` walker whose entire body is "call `parse_api_spec()`, write the result to `workspace.har_entries_json`"
- [ ] Parsed endpoints appear in the HAR entry table (same `HarEntryTable` component from Phase 6); method badge, path, and spec summary shown as a tooltip on the path cell

#### Path C — Browser-agent recording (when no HAR or spec is available)

If a user has neither a recorded HAR file nor an API spec, they can instruct a headless browser agent to visit the target URL, navigate the app automatically, and capture all network traffic — producing a real `.har` file that is then parsed by the existing `parse_har()` function.

### CLI
- [ ] `core/browser_agent.jac` — spawns a headless Chromium session via `playwright` (Python); attaches network interception to capture every API request/response; writes the captured traffic as a `.har` file
- [ ] `start_browser_agent(target_url, max_pages=20, idle_timeout_s=30, username=None, password=None, on_progress=None) -> str` — headless entry point launching the agent as a background asyncio task; `on_progress` is a plain callback (mirrors `run_test_headless()`'s `on_snapshot` — no `sv`/SSE assumptions baked in), returns a `recording_id`
- [ ] `stop_browser_agent(recording_id)` — signals graceful shutdown; agent flushes the HAR file and returns captured entry count
- [ ] Navigation decisions powered by `by-llm`, called from `jac_loadtest_cli` directly — a `BrowserAction` structured return type ensures the model always produces a valid, parseable action:
  ```jac
  import from byllm.lib { Model }
  glob llm = Model(model_name="claude-sonnet-4-6");

  obj BrowserAction {
      has selector: str;   # CSS selector or href to interact with
      has action: str;     # "click" | "fill" | "submit"
      has value: str;      # for fill actions; empty string otherwise
      has reason: str;     # one-line explanation for the action choice
  }

  """You are an exploratory QA tester. Choose the next page interaction most
  likely to reveal new API traffic. Never target elements whose href or form
  action contains: /delete, /destroy, /reset, /drop, /wipe, /purge."""
  def decide_next_action(page_url: str, elements: list[str]) -> BrowserAction
      by llm(temperature=0.3);
  ```
- [ ] `by-llm` automatically coerces the model's JSON output to `BrowserAction`; malformed output triggers up to 3 automatic retries with corrective feedback before the agent skips the page
- [ ] The `reason` field is passed through `on_progress` per page action, so a `sv` walker can push it onto an SSE stream without knowing anything about how it was produced
- [ ] Safety rule baked into the docstring prompt: never interact with elements matching the destructive path pattern list
- [ ] On completion: the `.har` file is handed to the existing `parse_har()` function — the browser agent feeds into the exact same pipeline every other discovery path uses, with zero special-casing downstream

### Web
- [ ] `start_browser_agent`/`stop_browser_agent` `sv` walkers — call the CLI functions above and nothing else; each `on_progress` event is pushed into a `queue.Queue` the same way `stream_metrics_callback` is in Phase 6, drained by an SSE stream (`stream_agent_progress`) sending `{ page, url, action, reason, captured_count }`
- [ ] **Browser agent** option in the discovery source step with a config panel: max pages, idle timeout, credentials toggle; "Start Recording" / "Stop Recording" buttons; live log panel rendering the `reason` field from each SSE event; entry count badge
- [ ] On completion: resulting entries are written to `workspace.har_entries_json`; user is redirected to the HAR entry table to review before proceeding
- [ ] Security notice banner shown before recording starts: lists the destructive path patterns the agent will never interact with (mirrors the CLI's own docstring-baked rule, shown for user transparency — the enforcement itself is entirely CLI-side)

---

### Pillar 2 — AI Persona Assignment

**Goal:** once the endpoint list is populated (by any path above), users describe a persona's personality in plain English and AI pre-selects the relevant endpoints — replacing the manual checklist step from Phase 7. VU counts and all other run configuration remain manual.

### CLI
- [ ] `core/persona_ai.jac` — uses `by-llm` with a `PersonaSelection` structured return type so the model's output is automatically parsed and validated without any manual JSON extraction:
  ```jac
  import from byllm.lib { Model }
  glob llm = Model(model_name="claude-sonnet-4-6");

  obj PersonaSelection {
      has indices: list[int];          # positions in the entries list to include
      has rationale: dict[str, str];   # index (as str) -> one-line reason
  }

  """Select the HAR entry indices that a user matching the given persona
  description would most likely exercise during a real session."""
  def assign_persona_endpoints(description: str, entries: list[dict]) -> PersonaSelection
      by llm(temperature=0.0, incl_info={"entries": entries});
  ```
- [ ] `by-llm` coerces the model output to `PersonaSelection`; malformed output triggers automatic retries (up to 3); if all retries fail the function raises a plain exception, matching `run_test_headless()`'s "raise, don't `sys.exit()`" contract, for the caller to translate into whatever error shape it needs
- [ ] Headless entry point: `assign_persona_endpoints(description: str, entries: list[dict]) -> dict` — same plain-function, no-CLI-context contract as everything else on this list

### Web
- [ ] "Auto-assign endpoints" button on each persona card calls a `sv` walker whose entire body is "call `assign_persona_endpoints()`, pre-tick the returned `indices`" in the HAR entry checklist
- [ ] Rationale tooltip on each auto-selected row: shows `rationale[str(idx)]` from the CLI function's response
- [ ] User retains full manual control after auto-assignment — they can add or remove ticks freely; AI output is a starting point, not a lock
- [ ] Safety gate: if the model selects a destructive endpoint (DELETE, or path matching the destructive pattern list), that row is highlighted amber and requires an explicit manual tick to confirm inclusion
- [ ] "Reassign" button with free-text feedback field: user types a correction ("this persona never deletes items"); the correction is appended to `description` and the CLI function is called again; updated indices replace the previous selection
- [ ] Save the finalised persona (description + selected indices + VU count) as a `.jacpersona` JSON template; "Export" and "Import" buttons on the persona builder for reuse across workspaces

---

**`by-llm` configuration (shared by both pillars, CLI-side now):**
- [ ] All AI calls use the `by-llm` plugin from `jac-byllm`; configured via `[plugins.byllm]` in `jac_loadtest_cli`'s own `jac.toml` — not the web project's, since the calls themselves now live in the CLI package:
  ```toml
  [plugins.byllm]
  system_prompt = "You are a load-testing assistant helping design realistic traffic patterns."

  [plugins.byllm.model]
  default_model = "claude-sonnet-4-6"

  [plugins.byllm.call_params]
  temperature = 0.0
  max_tokens = 2000
  ```
- [ ] API key set via `ANTHROPIC_API_KEY` env var (consumed by LiteLLM under the hood — no direct `anthropic` SDK calls in application code); whichever process imports `jac_loadtest_cli` (CLI shell or the web `sv` process) just needs this in its own environment
- [ ] Model override without config file: set `BYLLM_DEFAULT_MODEL` env var; web Settings panel writes both `ANTHROPIC_API_KEY` and `BYLLM_DEFAULT_MODEL` into the `sv` process's environment
- [ ] Offline mode: if `ANTHROPIC_API_KEY` is absent, the CLI function raises/returns a clear "no_api_key" error; the `sv` walker forwards it unchanged and the `cl` side shows a banner — "Configure your API key in Settings to use AI features"; manual HAR upload and manual persona checklist (Phase 7) remain fully functional
- [ ] Testing: `MockLLM` (from `byllm.lib`) swaps in deterministic outputs during unit tests so AI-path tests run without API calls — as `jac_loadtest_cli`'s own `tests/unit/`, matching this project's existing "core logic is unit-tested in the CLI package" pattern, not a web-side test suite:
  ```jac
  import from byllm.lib { MockLLM }
  glob llm = MockLLM(
      model_name="mockllm",
      config={"outputs": ['{"indices":[0,2],"rationale":{"0":"GET /todos","2":"POST /todos"}}']},
  );
  ```

**Exit criterion (browser-agent path):** A user with no HAR file and no spec enters their app URL, clicks "Start Recording", watches the live log as the agent browses 15 pages, reviews the 40-entry table, types "an experienced user who creates and manages todos" into a persona card, clicks "Auto-assign endpoints", reviews the pre-ticked 12 entries (including one amber destructive entry they manually un-tick), and launches a 30-VU persona-based run — without recording a single request or ticking a single checkbox manually.

**Exit criterion (spec path):** A user pastes an OpenAPI URL, the spec is parsed into 25 endpoints, they describe two personas and click "Auto-assign" for each, and launch a mixed persona test in under 3 minutes.

---

## Phase 9 — GraphQL & WebSocket

> First protocol expansion beyond HTTP.

This phase already matches the Architecture Principle: every protocol adapter, the
mixed-protocol config wiring, and — as of the HAR auto-detection item below — even the
"which endpoints in this HAR are GraphQL/WebSocket" decision are CLI-side. The one leftover
item that hadn't been re-scoped (GraphQL schema introspection, for editor autocomplete) is
moved into the CLI checklist below; the Web section is otherwise UI-only as originally
written.

### CLI
New engine adapter files — the existing HTTP engine is not changed.

- [x] `core/ws_engine.jac` — WebSocket VU coroutine: connect, send message sequence, record event-to-first-message latency and throughput; supports `ws://` and `wss://`. `WsScenarioConfig` + `parse_ws_scenarios()` + `run_ws_scenarios()`; one `RequestResult` per sent message, `protocol="ws"`, latency from send to first reply.
- [x] `core/graphql_engine.jac` — wraps `ws_engine`'s aiohttp `ws_connect` primitive with a `graphql-ws` handshake (`connection_init`/`connection_ack`/`start`/`data`/`complete`); sends subscription query, records events/second (via aggregate `rps`) and time-to-first-event latency (first recorded sample's `latency_ms`). `GraphQLScenarioConfig` + `parse_graphql_scenarios()` + `run_graphql_scenarios()`, with a `max_events` cap and `GRAPHQL_ERROR`/`GRAPHQL_TIMEOUT`/`GRAPHQL_CONNECTION_ERROR` failure paths.
- [x] `RequestResult` gains `protocol: str` field (`"http"`, `"ws"`, `"graphql"`, default `"http"`) for mixed-protocol metric breakdown (`core/metrics.jac`).
- [x] `EndpointStats` grouped by `(protocol, endpoint)` in `MetricsCollector.compute_endpoint_stats()` — an HTTP and a GraphQL row that share an endpoint label no longer blend latencies; console/HTML reports gain a `Proto`/`Protocol` column, shown only when a run actually contains a non-HTTP sample.
- [x] `run_test_headless()` accepts protocol-specific config blocks (`ws_scenarios`, `graphql_scenarios` on `LoadTestConfig`) alongside HTTP config — runs HTTP entries and any protocol scenarios concurrently in one `asyncio.run()` call sharing a single `MetricsCollector`/`stop_requested`/`t_start`; `har_file` becomes optional when at least one protocol scenario is given (ws/graphql-only runs); mixing protocol scenarios with `--workers > 1` is rejected, same restriction shape as `--step-load`.
- [x] **HAR-driven auto-detection (no config needed)** — `core/har_parser.jac`'s `HarEntry` gains a `protocol` field (`"http"` | `"graphql"` | `"ws"` | `"graphql_ws"`) plus `ws_messages`/`graphql_query`/`graphql_variables`/`graphql_operation_name`; entries that used to be unconditionally dropped (`_resourceType: "websocket"` / `ws://`+`wss://` URLs) are now parsed instead, with a GraphQL query/mutation-over-HTTP or subscription-over-`graphql-ws` sniffed from the body/frame (requires a `{` selection-set brace, to avoid misclassifying an unrelated `"query"` JSON field). `ws_engine.jac`/`graphql_engine.jac` each add `scenarios_from_har_entries()` to convert the tagged entries into scenario configs (`vus`/`iterations` default to the main run's own); both `cli.jac` and `headless.jac` call this automatically and merge the result ahead of any explicitly-configured scenarios — a recorded WebSocket connection or GraphQL subscription replays with zero extra flags. `cli.jac` now shares `headless.jac`'s async orchestrator (`run_all_protocols()`, made non-private for this) instead of duplicating it. WebSocket frame capture (`_webSocketMessages`) is opportunistic — absent from a plain Chrome DevTools HAR export, present from some third-party recorders (e.g. Playwright); a HAR lacking it still auto-detects the connection but has no message sequence to replay, with a one-time stderr warning.
- [ ] `core/graphql_engine.jac`: `introspect_schema(url: str) -> dict` — sends the standard GraphQL introspection query to the target and returns the parsed schema; headless-callable like everything else in this table, so a `sv` walker can offer it to the `cl` editor for autocomplete without implementing the introspection request itself (re-scoped here from an original `sv`-side design — talking to the target app's GraphQL endpoint is core, target-facing logic)

### Web
- [ ] Protocol selector tab on test builder: **HTTP | GraphQL | WebSocket**
- [ ] GraphQL request editor: query/mutation text area with syntax highlighting
- [ ] Variables panel: JSON editor with schema validation
- [ ] Schema introspection: `sv` walker calls the CLI's `introspect_schema()` (see CLI checklist above) and forwards the result; `cl` editor uses it for autocomplete — no introspection request logic on this side
- [x] Auto-detect GraphQL endpoints in imported HAR — detection is CLI-side (`HarEntry.protocol`, done, see CLI checklist above)
- [ ] Render detected GraphQL entries with a dedicated GraphQL UI (the remaining `cl` rendering work on top of the already-done detection)
- [ ] GraphQL subscription builder: enter subscription query, expected event schema
- [ ] Raw WebSocket scenario builder: connect, send message sequence, record response latencies
- [ ] Message templates with variable substitution (`{"user_id": "{{vu_id}}"}`)
- [ ] Metrics panel gains **Connections** tab for active WebSocket connection count
- [ ] Side-by-side scenario editor: define an HTTP flow + a WebSocket subscription in the same test run

**Exit criterion:** A user can run a test that simultaneously hammers a REST endpoint with 50 VUs and holds 20 concurrent GraphQL subscriptions, seeing unified metrics in one dashboard.

---

## Phase 10 — gRPC & Database Connections

> Match JMeter's multi-protocol coverage in a modern interface.

Both new protocols already fit the Architecture Principle as originally scoped — engine
adapters and file/query parsing are CLI work, the web layer only builds forms and renders
what the CLI returns. Two bullets below have been tightened for that: `.proto` parsing (was
duplicated — listed under both CLI and, contradictorily, as an `sv`-walker job under Web) now
lives only in the CLI list with the Web bullet pointing at it; "Result preview" (running a
query against the real DB, i.e. talking to a target system) moves from an unscoped Web bullet
to an explicit CLI headless function.

### CLI
New engine adapter files — the existing HTTP engine is not changed.

**gRPC:**
- [ ] `core/grpc_engine.jac` — VU coroutine: connect to gRPC endpoint, call method, record latency; supports unary, server-streaming, client-streaming, bidirectional
- [ ] `.proto` file parsing module (headless-callable, e.g. `parse_proto(source: str) -> dict`): parses service definitions and methods; returns schema for the `cl` editor — the *only* place `.proto` parsing happens; the web layer never parses it itself
- [ ] Metrics: calls/second, message latency p50/p95/p99, stream duration, gRPC status code breakdown
- [ ] TLS configuration: CA cert, client cert, client key file paths

**Database (PostgreSQL, MySQL, MongoDB):**
- [ ] `core/db_engine.jac` — VU coroutine: acquire connection from pool, execute query, record acquisition time + execution time; release on iteration end
- [ ] `core/db_engine.jac`: `preview_query(connection_config, query) -> dict` headless entry point — runs a single query against the real DB and returns rows/errors, so the web layer's "run before load testing" button is a thin call into this instead of its own DB client logic
- [ ] Connection pool load testing: configurable pool size; metrics: pool utilisation (%), pool exhaustion events, failed connections
- [ ] Transaction scenario: multi-step SQL sequence that commits or rolls back as a unit
- [ ] Parameterised queries: `{{vu_id}}`, `{{iteration}}`, or CSV-column substitution to avoid cache-hit uniformity
- [ ] Metrics: queries/second, deadlock count, slow query count above configurable threshold

**Mixed Protocol:**
- [ ] `run_test_headless()` accepts a step list that interleaves protocol adapters
- [ ] Dependency chaining: extract a value from one step's response and inject into the next step's request body

### Web
Forms, uploads, and result rendering only — every parsing/execution bullet points at its CLI
counterpart above.

**gRPC:**
- [ ] gRPC scenario builder: upload `.proto` → `sv` walker calls `parse_proto()` (CLI, see above); browse services/methods in a tree view
- [ ] Request message editor: form-based editor from proto schema + raw JSON mode
- [ ] All streaming modes UI
- [ ] Metadata (header) editor for gRPC auth tokens and tracing headers
- [ ] TLS configuration panel: upload CA cert, client cert, client key (stored server-side)

**Database:**
- [ ] Database connection panel: host, port, database name, username, password, pool size, SSL mode
- [ ] Query editor per type: SQL (PostgreSQL/MySQL) with syntax highlighting; MongoDB JSON query document editor
- [ ] Result preview: "Run" button calls `preview_query()` (CLI, see above) through a `sv` walker and renders the returned rows/errors
- [ ] Transaction scenario builder: multi-step SQL editor with commit/rollback toggle
- [ ] Parameterised query UI: bind CSV columns or VU variables to query parameters

**Mixed Protocol:**
- [ ] Scenario editor allows mixing steps across HTTP, WebSocket, gRPC, and database in a single persona flow
- [ ] Dependency chaining UI: visually wire an output field from one step into an input of the next

**Exit criterion:** A user runs a scenario that: logs in via HTTP, opens a WebSocket subscription, inserts a row into PostgreSQL, calls a gRPC method, and verifies the subscription received the expected event — measured end-to-end.

---

## Phase 11 — Distributed Testing

> Break the single-machine VU ceiling. Coordinate load across multiple machines.

Already CLI-first as originally scoped — `jac x loadtest worker` and the controller/node
protocol are the actual distributed-testing logic, and the web layer only displays status the
CLI's controller process reports. Two bullets moved from Web to CLI below since they're
infrastructure-level (network discovery, cross-node metric aggregation), not UI: node
auto-discovery and per-region latency breakdown. The web layer's job stays "render whatever
the controller returns," it just returns slightly more now.

### CLI
These additions enable the web's worker management UI. Mirrors CLI Phase 5b.

- [ ] `jac x loadtest worker --port N` — lightweight `aiohttp` HTTP server that accepts `POST /start` (config JSON + HAR entries) and runs `run_multiprocess()` locally; returns `GET /results` on completion
- [ ] `--worker-nodes host:port,...` flag — POST serialised config + HAR to each node; wait; GET results; merge into a single `MetricsCollector`
- [ ] VU distribution across nodes — split `--vus` evenly; each node receives `vu_id_offset` for globally unique VU IDs
- [ ] Pre-authentication on controller — sends per-VU token slices to each worker (no auth burst at nodes)
- [ ] Worker health check: `GET /health` before test start; abort with clear error if any node is unreachable
- [ ] Result streaming: workers push `StatsSnapshot` updates to controller via long-poll during run
- [ ] `--worker-nodes region:host:port,...` — optional `region:` label per node; the controller's merged report groups per-node latency by region, so "which region is slow" is a report field, not something the web layer computes by re-slicing raw per-node data itself
- [ ] Worker node auto-discovery: mDNS-based, `jac x loadtest worker --discover` (or equivalent) on the controller side — network discovery is infrastructure logic, not a UI concern; the web layer only ever renders whatever node list the controller reports, discovered or manually added

### Web
- [ ] Worker node manager UI: add remote worker nodes by IP/port, or trigger CLI-side mDNS auto-discovery (see CLI checklist) and display what it finds; see status (connected, running, idle)
- [ ] VU distribution display: shows VU slice assigned to each node
- [ ] Metrics aggregation: results streamed from all workers → controller sv walker → SSE → `cl` frontend as single unified stream — the controller's own merge logic lives in the CLI (`run_multiprocess()`-style merging, see CLI checklist); the `sv` walker only relays it
- [ ] Geo distribution: render the region-labeled latency breakdown the CLI's merged report already includes (see CLI checklist) — no re-aggregation on this side

**MQTT** (CLI adapter required, web-driven configuration):
- [ ] CLI: `core/mqtt_engine.jac` — connect to broker, publish/subscribe, measure delivery latency; supports MQTT 3.1.1 and 5, QoS 0/1/2
- [ ] Web: MQTT connection builder (broker URL, port, client ID, credentials, TLS); topic parameterisation (`sensors/{{vu_id}}/temperature`); metrics: messages/second, delivery latency p50/p95/p99, connection drops, message loss rate — all computed by `core/mqtt_engine.jac`/`MetricsCollector`, the web layer only renders the returned report

**Exit criterion:** A user orchestrates a 5,000-VU test split across 3 worker nodes in different network segments, with unified per-region latency in the browser dashboard in real time.

---

## Phase 12 — Release & Ecosystem

> Production-ready release for both CLI and web. PyPI, jac-scale integration, Docker, CI plugin, public launch.

Two groups of bullets moved from Web to CLI: JUnit XML is a **report format** — that's
`output/reporter.jac`'s job alongside console/JSON/HTML, not something the web/sv layer
invents on top of a JSON result — and the plugin architecture (the `ProtocolAdapter`
interface, the registry that discovers installed adapters, the reference adapters
themselves) is exactly the same kind of core, protocol-adapter work as `ws_engine.jac`/
`grpc_engine.jac`, so it belongs in `jac_loadtest_cli`, not the web project. What's left under
Web for both is thin: the headless HTTP endpoint that calls into the CLI, and a UI that
reflects whatever plugin list the CLI reports.

### CLI
- [ ] All `jac test tests/unit/`, `jac test tests/integration/`, `jac test tests/e2e/` pass cleanly
- [ ] Integration test: local jac-scale app + HAR capture → `jac x loadtest` end-to-end (manual)
- [ ] Auth integration test: register test user, run with `--username`/`--password`, verify 0 auth errors (manual)
- [ ] `README.md` polished: install instructions, usage examples, all flags documented
- [ ] `jac.toml` polished: classifiers, description, license, version
- [ ] Publish to PyPI as `jac-loadtest-cli` via `jac build --as wheel && twine upload dist/*`
- [ ] **jac-scale integration:** Move `jac_loadtest_cli/core/` and `output/` into `jac-scale/jac_scale/loadtest/`; swap HTTP auth for in-process `UserManager`; swap disk read for in-memory `ServiceRegistry`; expose `loadtest` as a console script from jac-scale's own package; deprecate standalone package
- [ ] `output/reporter.jac`: `render_junit()` — JUnit XML report format alongside `render_console()`/`render_json()`/`render_html()`, same `stats`/`config`/... signature; `--report-format junit` on the CLI
- [ ] **Plugin Architecture** (re-scoped from Web — this is adapter code, same shape as `ws_engine.jac`): `ProtocolAdapter` ABC defining the Python interface every protocol adapter (built-in or third-party) implements; a plugin registry that discovers installed adapters (Python entry-points, mirroring how `[entrypoints.scripts]` already exposes `loadtest` itself) so `run_test_headless()`/`cli.jac` can dispatch to one without a hardcoded import list; example plugins (Redis, Kafka, AMQP/RabbitMQ) as reference implementations, each its own installable package depending on `jac-loadtest-cli`

### Web
**Headless CI API — thin wrapper around the CLI, no logic of its own:**
- [ ] `POST /api/run` — accepts `.jactest` config JSON, calls `run_test_headless()` (CLI), returns its result as JSON (no browser required); same exit-code semantics as CLI
- [ ] `GET /api/run?format=junit` — calls `render_junit()` (CLI, see above) on the stored result and returns it; for Jenkins, Azure DevOps, GitLab
- [ ] GitHub Actions plugin: `jaseci-labs/jac-loadtest-action@v1` posts to the headless API above; comments pass/fail + key metrics on the PR

**Plugin Architecture — UI reflection only:**
- [ ] UI auto-discovers whatever protocol adapters the CLI's plugin registry (see CLI checklist above) reports as installed, and adds a protocol tab on next page load — no registry logic duplicated here
- [ ] Official plugin list: maintained index of community adapters (documentation/ecosystem page, not application logic)

**UX Polish:**
- [ ] Onboarding tour: step-by-step walkthrough for first-time users
- [ ] Test templates library: pre-built configs (REST API stress test, WebSocket broadcast, DB connection pool test)
- [x] Dark / light theme toggle (persisted to `localStorage`) — implemented ahead of
      this phase: `components/ThemeProvider.cl.jac` (shared context, mounted at the app
      root so a refresh on any route re-applies the saved theme), `ThemeToggle.cl.jac`
      (button in every protected page's header), `lib/theme.cl.jac` (persistence)
- [ ] Keyboard shortcuts for all primary actions
- [ ] Accessibility audit (WCAG 2.1 AA)

**Deployment:**
- [ ] Docker image: single container running `jac serve`
- [ ] `docker-compose.yml` example: web app + optional worker node agents
- [ ] Auth layer (optional): toggle-able login wall for team deployments; API token for headless CI
- [ ] Public website with docs, changelog, and hosted demo instance

**Exit criterion:** `jac install jac-loadtest-cli && jac x loadtest --help` works from PyPI; `docker run jaseci/jac-loadtest` serves the web app; GitHub Actions CI plugin is published.

---

## Milestone Summary

| Milestone | Phase | CLI Deliverable | Web Deliverable |
|-----------|-------|-----------------|-----------------|
| M1 | 0 | `jac x loadtest --help` works | — |
| M2 | 1 | HAR replay + console report | — |
| M3 | 2 | Per-VU JWT injection + username/password auth | — |
| M4 | 3 | Per-service routing + breakdown | — |
| M5 | 4 | Graceful shutdown, thresholds, exit codes, RPS cap | — |
| M6 | 5 | JSON + HTML reports, p99.9, Apdex, TTFB | — |
| M7 | 6 | `LoadTestConfig.from_dict()`, `run_test_headless()` with SSE callback | User accounts; workspace wizard (mode, URL/services-map, HAR, credentials); load test runs with live dashboard and HTML report download |
| M8 | 7 | `PersonaConfig`, `run_personas()`, `RequestResult.persona`, `--persona-file` — not started | Standard/Persona mode toggle; 3 built-in personas; HAR entry selector per persona; per-persona report section — display/config only, not started |
| M9 | 8 | `core/spec_parser.jac`, `core/browser_agent.jac`, `core/persona_ai.jac` — re-scoped from web/sv, not started | Discovery source picker (HAR / spec / browser agent); AI persona assignment with rationale tooltips — thin `sv` wrappers around the CLI functions, not started |
| M10 | 9 | `ws_engine.jac`, `graphql_engine.jac`, HAR auto-detection — **done**; `introspect_schema()` — not started | GraphQL + WebSocket protocol UI — not started |
| M11 | 10 | `grpc_engine.jac`, `db_engine.jac` (Postgres/MySQL/MongoDB), `.proto` parser, `preview_query()` — not started | gRPC builder, SQL/Mongo query editors — display/upload only, not started |
| M12 | 11 | `--worker-nodes` flag, `jac x loadtest worker` server mode, mDNS discovery, region-labeled aggregation — not started | Worker management UI, geo region display — not started |
| M13 | 12 | PyPI release, jac-scale integration, `render_junit()`, plugin registry — not started | Docker image, thin CI-trigger endpoint, plugin-list UI, public launch — not started |

---

## Protocol Support Target

| Protocol | Phase | CLI Adapter | Web UI |
|----------|-------|-------------|--------|
| HTTP/HTTPS | 0–5 (existing) | `core/engine.jac` — done | Phase 6 — done |
| GraphQL (query/mutation) | 9 | `core/graphql_engine.jac` — done | Phase 9 — not started |
| GraphQL subscriptions | 9 | `core/ws_engine.jac` (graphql-ws) — done | Phase 9 — not started |
| WebSocket (raw) | 9 | `core/ws_engine.jac` — done | Phase 9 — not started |
| gRPC | 10 | `core/grpc_engine.jac` — not started | Phase 10 — not started |
| PostgreSQL | 10 | `core/db_engine.jac` — not started | Phase 10 — not started |
| MySQL | 10 | `core/db_engine.jac` — not started | Phase 10 — not started |
| MongoDB | 10 | `core/db_engine.jac` — not started | Phase 10 — not started |
| MQTT | 11 | `core/mqtt_engine.jac` — not started | Phase 11 — not started |
| Redis | 12 (plugin) | Community plugin, installable against the CLI's plugin registry — not started | Phase 12 — UI reflection only, not started |
| Kafka | 12 (plugin) | Community plugin, installable against the CLI's plugin registry — not started | Phase 12 — UI reflection only, not started |
| AMQP (RabbitMQ) | 12 (plugin) | Community plugin, installable against the CLI's plugin registry — not started | Phase 12 — UI reflection only, not started |
