# jac-loadtest Combined Roadmap

A unified delivery plan covering both `jac-loadtest-cli` (the engine) and `jac-loadtest-web`
(the visual frontend). Each phase lists what must be built at the CLI level and what must be
built at the web level, in dependency order.

---

## Architecture Principle

The CLI package (`jac_loadtest_cli`) is the engine — it owns all load generation, metric
collection, auth, topology routing, and report rendering. The web app is a shell that
configures the engine, invokes it via `sv` walkers, and visualises its output. **The engine
is never rewritten; it is only extended.**

```
Browser (cl codespace — Vite/React)        ←  web phases
  ↕ HTTP walker calls (jac-client fullstack)
jac-loadtest sv walkers (sv codespace)     ←  web phases (thin adapters)
  ↓ imports as Python module
jac-loadtest engine (jac_loadtest_cli)     ←  CLI phases
  ↓ extended by
Protocol Adapters                          ←  CLI phases (per protocol)
```

---

## Phase Status Overview

| Phase | Name | CLI | Web |
|-------|------|-----|-----|
| 0 | CLI Foundation | ✓ Done | — |
| 1 | CLI MVP | ✓ Done | — |
| 2 | CLI Auth + Think Time | ✓ Done | — |
| 3 | CLI Microservice Mode | ✓ Done | — |
| 4 | Production Hardening | Done | — |
| 5 | Reporting & Polish | Done | — |
| 6 | Web MVP | Minor extensions | Full UI shell |
| 7 | GraphQL & WebSocket | Engine adapters | Protocol UI |
| 8 | Advanced Personas | Core engine changes | Advanced persona UI |
| 9 | AI Flow Generation | None | LLM integration |
| 10 | gRPC & Databases | Protocol adapters | Schema editors |
| 11 | Distributed Testing | `--worker-nodes` flag | Worker management UI |
| 12 | Release & Ecosystem | PyPI + jac-scale | Docker + CI + public launch |

---

## Phase 0 — CLI Foundation ✓

> Repo skeleton and import tree wired before any logic is written.

### CLI
- [x] `jac_loadtest_cli/` package with `core/`, `bridge/`, `output/` layout
- [x] `jac.toml` with dependencies; plugin registered via `[entrypoints.jac]`
- [x] `plugin.jac` — `@registry.command(...)` entry point; `jac loadtest --help` works
- [x] Empty module stubs; full import tree resolves from day one
- [x] `tests/` directory with `tests/fixtures/` and JAC test blocks

### Web
None — CLI must be functional before web development begins.

**Exit criterion:** `jac loadtest --help` prints usage. ✓

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

**Exit criterion:** `jac loadtest recording.har --url http://localhost:8000 --vus 10` completes and prints a summary table. ✓

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

**Exit criterion:** `jac loadtest recording.har --username user --password pass` runs with 0 auth errors. 141 tests pass. ✓

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

**Exit criterion:** `jac loadtest recording.har --mode microservice --services-map '{...}'` reports per-service latency. ✓

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

**Exit criterion:** `jac loadtest ... --report-format html --report-out report.html` produces a self-contained HTML file with charts; `jac test tests/e2e/` passes.

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
- [x] `run_test_headless(config: LoadTestConfig, on_snapshot=None) -> dict` — public
      Python function; runs the full engine (`run_multiprocess` or `run_all_vus`), calls
      `on_snapshot(snapshot)` after each 10s tick so the sv walker can push SSE events,
      and returns the JSON-serialisable result dict produced by `render_json()`.
      No `sys.exit()`, no Rich console output, no file writes — caller controls all I/O.
- [x] `stream_metrics_callback` parameter wired into `run_all_vus()` and
      `run_multiprocess()` — called with each `StatsSnapshot` object; no-op when `None`.
- [x] Verify `render_json()` and `render_html()` are importable as plain Python functions
      with no CLI context required (no `sys.argv`, no Rich console initialisation at
      import time).
- [x] **TTFB breakdown** — separate Time To First Byte from total latency via aiohttp
      trace API (`aiohttp.TraceConfig`); adds `ttfb_ms` field to `RequestResult`,
      `EndpointStats`, JSON report, and HTML summary card

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
│   └── ReportViewer.cl.jac
│
├── services/                            ← server walkers (.sv.jac) — jac-scale endpoints
│   ├── auth_walkers.sv.jac              ← register_user(), login_user(), logout_user(), me()
│   ├── workspace_walkers.sv.jac         ← create/list/get/update/delete workspace
│   ├── file_walkers.sv.jac              ← upload_har(), start_proxy(), stop_proxy()
│   ├── run_walkers.sv.jac               ← create_run(), start_run(), stop_run(),
│   │                                       get_run(), list_runs()
│   └── stream_walkers.sv.jac            ← stream_metrics(run_id) → SSE
│
├── models/                              ← node / dataclass definitions (.sv.jac)
│   ├── workspace.sv.jac                 ← Workspace node
│   └── run.sv.jac                       ← LoadTestRun node
│
├── lib/                                 ← utility modules
│   └── utils.cl.jac                     ← shadcn cn() helper
│
└── styles/
    └── global.css                       ← Tailwind + jac-shadcn theme tokens
```

---

#### Web App Authentication

- [x] `register_user(email, password)` sv walker — creates a jac-scale `User` node;
      returns JWT token for the web session
- [x] `login_user(email, password)` sv walker — authenticates against `UserManager`;
      returns JWT
- [x] `logout_user()` sv walker — invalidates the current session token. jac-scale
      issues stateless JWTs with no server-side revocation list, so this is an
      authenticated acknowledgement endpoint only — actual session termination is
      the client dropping the token (localStorage removal + `jacLogout()`)
- [x] `me()` sv walker — returns the current user's profile
- [x] `cl` login page: email + password form; on success stores token in `localStorage`
      and redirects to `/workspaces`
- [x] `cl` register page: email + password + confirm form; on success auto-logs in
      (`register_user` mints the JWT directly — no separate login round-trip needed)
- [x] Auth guard: all `cl` routes except `/login` and `/register` check for a valid token;
      unauthenticated requests redirect to `/login` (`AuthGuard` from `@jac/runtime`)
- [x] JWT attached to every sv walker call as `Authorization: Bearer <token>` header;
      sv walkers reject requests without a valid token with `401` (jac-scale's
      canonical status for "no/invalid token" — the framework's plain-`walker`
      auth gate, not a custom 403 check; see `jac guide jac-sv-auth`)

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
- [ ] HAR entry table with enable/disable toggles; "Save" persists the selection to
      `har_entries_json` on the workspace
- [ ] "Replace HAR" button — re-runs Step 3 of the wizard against the existing workspace
- [ ] "Update Credentials" button — re-runs Step 4
- [ ] Run history list: all `LoadTestRun` records for this workspace, sorted newest first,
      showing label, status badge, VUs, duration, p95, error rate, started_at
- [ ] "New Run" button → run create page
- [ ] Workspace settings panel: edit name, description, URL/services-map, login path,
      include_static
- [ ] Delete workspace (with confirmation dialog)

---

#### Load Test Run

**Create Run Page (`/workspaces/{id}/runs/new`):**

The run form shows which settings it inherits from the workspace (greyed out, editable
via override) and which are run-specific.

*Inherited from workspace (display only, no override needed):*
- Mode, target URL / services map, HAR entries, credentials, login path

*Run-specific settings — required:*
- [ ] VUs (virtual users) — integer input
- [ ] Stop condition — **Iterations** (N replays per VU)

*Run-specific settings — optional (collapsible "Advanced" section):*
- [ ] Ramp-up duration (default `0s`)
- [ ] Worker processes (default: CPU count)
- [ ] RPS cap (default: 0 = unlimited)
- [ ] Think time: None / Real / Scaled + scale multiplier
- [ ] Per-request timeout (default `30s`)

*Thresholds (collapsible):*
- [ ] Fail if error rate exceeds N%
- [ ] Fail if p95 latency exceeds N ms
- [ ] Fail if p99 latency exceeds N ms
- [ ] Abort immediately on first threshold breach (checkbox)
- [ ] Threshold evaluation delay (default `0s` — cold-start protection)

*Label:* optional freetext name for this run (e.g. "50 VU smoke test")

**"Start Run" button:**
- [ ] `create_run` sv walker: creates `LoadTestRun` node with `status = "pending"`;
      returns `run_id`
- [ ] `start_run` sv walker: builds `LoadTestConfig` via `LoadTestConfig.from_dict()`
      (no toml lookup); spawns engine via `run_test_headless()` in a background
      asyncio task; sets `status = "running"`; returns SSE stream URL
- [ ] `cl` redirects to run detail page immediately after `start_run` succeeds

**Run Detail Page (`/workspaces/{id}/runs/{run_id}`):**

*During run:*
- [ ] Status bar: `RUNNING` badge + elapsed time counter
- [ ] Stop button → `stop_run` sv walker → engine graceful two-signal shutdown;
      sets `status = "stopped"`; partial report is still rendered from collected metrics
- [ ] Live RPS counter and error rate badge (SSE, updated every second)
- [ ] Ramp-up progress ring: live VU count rising to target during ramp-up
- [ ] RPS-over-time line chart (live SSE)
- [ ] p50/p95/p99 latency-over-time chart (live SSE)
- [ ] Per-endpoint latency bar chart (updates every 10s)
- [ ] Error rate gauge: green < 1%, yellow 1–5%, red > 5%
- [ ] Debug log panel (shown only when run was created with debug=true): per-request
      lines streamed via SSE

*After run completes or is stopped:*
- [ ] Status badge changes to `COMPLETED` / `STOPPED` / `FAILED`
- [ ] Threshold pass/fail summary banner (green tick / red cross per threshold)
- [ ] Full report rendered inline from `results_json`:
      — Summary table: total requests, RPS, error rate, p50/p95/p99
      — Per-endpoint latency bar chart
      — RPS-over-time chart (post-run, from timeseries data)
      — Error breakdown table
- [ ] "Download JSON" button (browser Blob from `results_json`)
- [ ] "Download HTML" button: sv walker calls `render_html()` and returns the HTML
      string; browser triggers a file download
- [ ] "Re-run with same settings" button — pre-fills the run create form with all
      current settings

**SSE Streaming Architecture:**
- [ ] `stream_metrics(run_id)` sv walker: keeps an SSE connection open; the
      `on_snapshot` callback registered in `run_test_headless()` writes each
      `StatsSnapshot` into an asyncio queue; the SSE walker reads from the queue
      and sends `data: {json}\n\n` events; connection closes when the run ends
- [ ] `cl` `MetricsDashboard` component subscribes to the SSE endpoint on mount;
      unsubscribes when the run detail page unmounts or run status is terminal

---

**Exit criterion:** A user registers an account, creates a workspace (monolith mode,
uploads a HAR, optionally provides credentials), creates a load test run (50 VUs, 60s),
watches live RPS and latency charts in the browser, sees a threshold pass/fail summary,
and downloads an HTML report — without touching a terminal.

---

## Phase 7 — Persona-Based Testing

> Simulate realistic user behaviour by splitting the load across distinct user archetypes, each replaying their own subset of HAR entries.

### CLI

- [ ] `PersonaConfig` dataclass: `name: str`, `description: str`, `entry_indices: list[int]`, `vus: int`
- [ ] `run_personas()` orchestrator: for each persona, filters `HarEntry` list to `entry_indices`, then launches a `run_all_vus()` coroutine; all personas share a single `MetricsCollector` so aggregate metrics are correct
- [ ] `RequestResult` gains `persona: str` field — populated by the engine from the active `PersonaConfig.name`
- [ ] `MetricsCollector.endpoint_stats()` groups results by `(persona, endpoint)` — console, JSON, and HTML reports include per-persona rows
- [ ] JSON report gains `"personas": [{ "name", "vus", "summary", "endpoints" }]` section
- [ ] HTML report gains a **Personas** tab with per-persona summary cards and p95 latency bars
- [ ] `--persona-file` flag: path to a JSON file defining persona list; mutually exclusive with `--vus` (persona mode replaces flat VU count)

### Web

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

> Two AI-powered capabilities that live entirely in the web layer: discover every endpoint the app exposes without manual effort, then let AI decide which endpoints belong to each persona.

**Architecture boundary:** The CLI is a pure execution engine — it only ever consumes `HarEntry` objects and `PersonaConfig` objects, both of which are prepared by the web layer before a run starts. The CLI gains no new code in this phase. All endpoint discovery, spec parsing, browser-agent orchestration, and AI persona assignment run in the `sv` (server-side Jac) codespace. Once the web layer has built the entry list and persona configs, it calls the same `run_personas()` function introduced in Phase 7 — unchanged.

---

### Pillar 1 — Automatic Endpoint Discovery

**Goal:** give users three progressively automated paths to populate the workspace endpoint list. Every path ultimately produces the same thing: a list of `HarEntry`-compatible records stored in `har_entries_json` on the workspace node. The run pipeline is identical regardless of which path was used.

#### Path A — HAR file upload (already built in Phase 6)
The existing workspace wizard HAR upload path already parses entries and stores them in `har_entries_json`. No new work. Displayed first in the discovery UI as the recommended fast path.

#### Path B — API specification document

### Web / SV
- [ ] `services/spec_parser.sv.jac` — `sv` walker that accepts a URL or uploaded file; fetches and parses OpenAPI 3.0 / 3.1 or Swagger 2.0 YAML/JSON; emits a flat list of `{ method, path, summary, request_schema, response_schema }` records
- [ ] Synthesises `HarEntry`-compatible dicts from the spec (method, path, empty body, status 200) and writes them to `workspace.har_entries_json` — no changes to the engine pipeline or CLI required
- [ ] Workspace creation wizard: **Discovery source** step added between HAR upload and credentials; options are **Upload HAR** (existing) | **API spec URL or file** | **Browser agent** (below)
- [ ] API spec option: URL text input (e.g. `https://api.example.com/openapi.json`) or file upload (`.yaml` / `.json`); "Import spec" calls `spec_parser` sv walker
- [ ] Parsed endpoints appear in the HAR entry table (same `HarEntryTable` component from Phase 6); method badge, path, and spec summary shown as a tooltip on the path cell
- [ ] Accepted formats: OpenAPI 3.0, OpenAPI 3.1, Swagger 2.0

#### Path C — Browser-agent recording (when no HAR or spec is available)

If a user has neither a recorded HAR file nor an API spec, they can instruct a headless browser agent to visit the target URL, navigate the app automatically, and capture all network traffic — producing a real `.har` file that is then parsed by the existing `parse_har()` function.

### Web / SV
- [ ] `services/browser_agent.sv.jac` — `sv` walker that spawns a headless Chromium session via `playwright` (Python); attaches network interception to capture every API request/response; the captured traffic is saved as a `.har` file server-side
- [ ] `start_browser_agent` sv walker: accepts `target_url`, `max_pages` (default 20), `idle_timeout_s` (default 30), optional `username`/`password` (re-uses workspace credentials); launches the agent as a background asyncio task; returns a `recording_id`
- [ ] Navigation decisions powered by `by-llm` — a `BrowserAction` structured return type ensures the model always produces a valid, parseable action:
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
- [ ] The `reason` field is forwarded to the SSE stream so users see the agent's live reasoning in the progress panel
- [ ] Safety rule baked into the docstring prompt: never interact with elements matching the destructive path pattern list
- [ ] `stop_browser_agent` sv walker: signals graceful shutdown; agent flushes the HAR file and returns captured entry count
- [ ] SSE progress stream (`stream_agent_progress`): emits one event per page action — `{ page: int, url: str, action: str, reason: str, captured_count: int }`; the `cl` codespace renders a live log panel
- [ ] On completion: the `.har` file is parsed by the existing `parse_har()` function; resulting entries are written to `workspace.har_entries_json`; user is redirected to the HAR entry table to review before proceeding
- [ ] **Browser agent** option in the discovery source step with a config panel: max pages, idle timeout, credentials toggle; "Start Recording" / "Stop Recording" buttons; live log panel; entry count badge
- [ ] Security notice banner shown before recording starts: lists the destructive path patterns the agent will never interact with

### CLI
No changes. The CLI receives `HarEntry` objects from the web layer exactly as it did in Phases 6 and 7. It has no awareness of whether entries came from a HAR upload, a spec, or a browser agent.

---

### Pillar 2 — AI Persona Assignment

**Goal:** once the endpoint list is populated (by any path above), users describe a persona's personality in plain English and AI pre-selects the relevant endpoints — replacing the manual checklist step from Phase 7. VU counts and all other run configuration remain manual.

### Web / SV
- [ ] `services/persona_ai.sv.jac` — uses `by-llm` with a `PersonaSelection` structured return type so the model's output is automatically parsed and validated without any manual JSON extraction:
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
- [ ] `by-llm` coerces the model output to `PersonaSelection`; malformed output triggers automatic retries (up to 3); if all retries fail the sv walker returns an error to the `cl` side and the user is prompted to try again
- [ ] "Auto-assign endpoints" button on each persona card calls the `assign_persona_endpoints` sv walker; pre-ticks the returned `indices` in the HAR entry checklist
- [ ] Rationale tooltip on each auto-selected row: shows `rationale[str(idx)]` from the model's response
- [ ] User retains full manual control after auto-assignment — they can add or remove ticks freely; AI output is a starting point, not a lock
- [ ] Safety gate: if the model selects a destructive endpoint (DELETE, or path matching the destructive pattern list), that row is highlighted amber and requires an explicit manual tick to confirm inclusion
- [ ] "Reassign" button with free-text feedback field: user types a correction ("this persona never deletes items"); the correction is appended to `description` and `assign_persona_endpoints` is called again; updated indices replace the previous selection
- [ ] Save the finalised persona (description + selected indices + VU count) as a `.jacpersona` JSON template; "Export" and "Import" buttons on the persona builder for reuse across workspaces

### CLI
No changes. When the user starts a run, the web layer serialises the personas (with their pre-resolved entry index lists) into `PersonaConfig` objects and calls `run_personas()` from Phase 7 directly. The CLI never makes any LLM calls.

**`by-llm` configuration (shared by both pillars):**
- [ ] All AI calls use the `by-llm` plugin from `jac-byllm`; configured via `[plugins.byllm]` in the sv-side `jac.toml`:
  ```toml
  [plugins.byllm]
  system_prompt = "You are a load-testing assistant helping design realistic traffic patterns."

  [plugins.byllm.model]
  default_model = "claude-sonnet-4-6"

  [plugins.byllm.call_params]
  temperature = 0.0
  max_tokens = 2000
  ```
- [ ] API key set via `ANTHROPIC_API_KEY` env var (consumed by LiteLLM under the hood — no direct `anthropic` SDK calls in application code)
- [ ] Model override without config file: set `BYLLM_DEFAULT_MODEL` env var; web Settings panel writes both `ANTHROPIC_API_KEY` and `BYLLM_DEFAULT_MODEL` to the sv process `.env` file
- [ ] Offline mode: if `ANTHROPIC_API_KEY` is absent, the sv walker returns `{"error": "no_api_key"}` and the `cl` side shows a banner — "Configure your API key in Settings to use AI features"; manual HAR upload and manual persona checklist (Phase 7) remain fully functional
- [ ] Testing: `MockLLM` (from `byllm.lib`) swaps in deterministic outputs during unit tests so AI-path tests run without API calls:
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

### CLI
New engine adapter files — the existing HTTP engine is not changed.

- [ ] `core/ws_engine.jac` — WebSocket VU coroutine: connect, send message sequence, record event-to-first-message latency and throughput; supports `ws://` and `wss://`
- [ ] `core/graphql_engine.jac` — wraps `ws_engine` with `graphql-ws` handshake; sends subscription query, records events/second and time-to-first-event latency
- [ ] `RequestResult` gains `protocol: str` field (`"http"`, `"ws"`, `"graphql"`) for mixed-protocol metric breakdown
- [ ] `EndpointStats` grouped by `(protocol, endpoint)` in `MetricsCollector`
- [ ] `run_test_headless()` accepts protocol-specific config blocks alongside HTTP config

### Web
- [ ] Protocol selector tab on test builder: **HTTP | GraphQL | WebSocket**
- [ ] GraphQL request editor: query/mutation text area with syntax highlighting
- [ ] Variables panel: JSON editor with schema validation
- [ ] Schema introspection: `sv` walker fetches `{url}/graphql` schema; `cl` editor uses it for autocomplete
- [ ] Auto-detect GraphQL endpoints in imported HAR; render with dedicated GraphQL UI
- [ ] GraphQL subscription builder: enter subscription query, expected event schema
- [ ] Raw WebSocket scenario builder: connect, send message sequence, record response latencies
- [ ] Message templates with variable substitution (`{"user_id": "{{vu_id}}"}`)
- [ ] Metrics panel gains **Connections** tab for active WebSocket connection count
- [ ] Side-by-side scenario editor: define an HTTP flow + a WebSocket subscription in the same test run

**Exit criterion:** A user can run a test that simultaneously hammers a REST endpoint with 50 VUs and holds 20 concurrent GraphQL subscriptions, seeing unified metrics in one dashboard.

---

## Phase 10 — gRPC & Database Connections

> Match JMeter's multi-protocol coverage in a modern interface.

### CLI
New engine adapter files — the existing HTTP engine is not changed.

**gRPC:**
- [ ] `core/grpc_engine.jac` — VU coroutine: connect to gRPC endpoint, call method, record latency; supports unary, server-streaming, client-streaming, bidirectional
- [ ] `.proto` file parsing module: parses service definitions and methods; returns schema for `cl` editor
- [ ] Metrics: calls/second, message latency p50/p95/p99, stream duration, gRPC status code breakdown
- [ ] TLS configuration: CA cert, client cert, client key file paths

**Database (PostgreSQL, MySQL, MongoDB):**
- [ ] `core/db_engine.jac` — VU coroutine: acquire connection from pool, execute query, record acquisition time + execution time; release on iteration end
- [ ] Connection pool load testing: configurable pool size; metrics: pool utilisation (%), pool exhaustion events, failed connections
- [ ] Transaction scenario: multi-step SQL sequence that commits or rolls back as a unit
- [ ] Parameterised queries: `{{vu_id}}`, `{{iteration}}`, or CSV-column substitution to avoid cache-hit uniformity
- [ ] Metrics: queries/second, deadlock count, slow query count above configurable threshold

**Mixed Protocol:**
- [ ] `run_test_headless()` accepts a step list that interleaves protocol adapters
- [ ] Dependency chaining: extract a value from one step's response and inject into the next step's request body

### Web
**gRPC:**
- [ ] gRPC scenario builder: upload `.proto` → `sv` walker parses it; browse services/methods in a tree view
- [ ] Request message editor: form-based editor from proto schema + raw JSON mode
- [ ] All streaming modes UI
- [ ] Metadata (header) editor for gRPC auth tokens and tracing headers
- [ ] TLS configuration panel: upload CA cert, client cert, client key (stored server-side)

**Database:**
- [ ] Database connection panel: host, port, database name, username, password, pool size, SSL mode
- [ ] Query editor per type: SQL (PostgreSQL/MySQL) with syntax highlighting; MongoDB JSON query document editor
- [ ] Result preview: run a query against the real DB before load testing
- [ ] Transaction scenario builder: multi-step SQL editor with commit/rollback toggle
- [ ] Parameterised query UI: bind CSV columns or VU variables to query parameters

**Mixed Protocol:**
- [ ] Scenario editor allows mixing steps across HTTP, WebSocket, gRPC, and database in a single persona flow
- [ ] Dependency chaining UI: visually wire an output field from one step into an input of the next

**Exit criterion:** A user runs a scenario that: logs in via HTTP, opens a WebSocket subscription, inserts a row into PostgreSQL, calls a gRPC method, and verifies the subscription received the expected event — measured end-to-end.

---

## Phase 11 — Distributed Testing

> Break the single-machine VU ceiling. Coordinate load across multiple machines.

### CLI
These additions enable the web's worker management UI. Mirrors CLI Phase 5b.

- [ ] `jac loadtest worker --port N` — lightweight `aiohttp` HTTP server that accepts `POST /start` (config JSON + HAR entries) and runs `run_multiprocess()` locally; returns `GET /results` on completion
- [ ] `--worker-nodes host:port,...` flag — POST serialised config + HAR to each node; wait; GET results; merge into a single `MetricsCollector`
- [ ] VU distribution across nodes — split `--vus` evenly; each node receives `vu_id_offset` for globally unique VU IDs
- [ ] Pre-authentication on controller — sends per-VU token slices to each worker (no auth burst at nodes)
- [ ] Worker health check: `GET /health` before test start; abort with clear error if any node is unreachable
- [ ] Result streaming: workers push `StatsSnapshot` updates to controller via long-poll during run

### Web
- [ ] Worker node manager UI: add remote worker nodes by IP/port; see status (connected, running, idle)
- [ ] VU distribution display: shows VU slice assigned to each node
- [ ] Metrics aggregation: results streamed from all workers → controller sv walker → SSE → `cl` frontend as single unified stream
- [ ] Geo distribution: label each worker node with a region; report latency breakdown by region
- [ ] Worker node auto-discovery: mDNS-based for nodes on the same LAN

**MQTT** (web-driven protocol, CLI adapter required):
- [ ] CLI: `core/mqtt_engine.jac` — connect to broker, publish/subscribe, measure delivery latency; supports MQTT 3.1.1 and 5, QoS 0/1/2
- [ ] Web: MQTT connection builder (broker URL, port, client ID, credentials, TLS); topic parameterisation (`sensors/{{vu_id}}/temperature`); metrics: messages/second, delivery latency p50/p95/p99, connection drops, message loss rate

**Exit criterion:** A user orchestrates a 5,000-VU test split across 3 worker nodes in different network segments, with unified per-region latency in the browser dashboard in real time.

---

## Phase 12 — Release & Ecosystem

> Production-ready release for both CLI and web. PyPI, jac-scale integration, Docker, CI plugin, public launch.

### CLI
- [ ] All `jac test tests/unit/`, `jac test tests/integration/`, `jac test tests/e2e/` pass cleanly
- [ ] Integration test: local jac-scale app + HAR capture → `jac loadtest` end-to-end (manual)
- [ ] Auth integration test: register test user, run with `--username`/`--password`, verify 0 auth errors (manual)
- [ ] `README.md` polished: install instructions, usage examples, all flags documented
- [ ] `jac.toml` polished: classifiers, description, license, version
- [ ] Publish to PyPI as `jac-loadtest-cli` via `jac bundle && twine upload dist/*`
- [ ] **jac-scale integration:** Move `jac_loadtest_cli/core/` and `output/` into `jac-scale/jac_scale/loadtest/`; swap HTTP auth for in-process `UserManager`; swap disk read for in-memory `ServiceRegistry`; register `jac loadtest` in `jac-scale/jac_scale/plugin.jac`; deprecate standalone package

### Web
**Headless CI API:**
- [ ] `POST /api/run` — accepts `.jactest` config JSON, returns results as JSON (no browser required); same exit-code semantics as CLI
- [ ] `GET /api/run?format=junit` — JUnit XML output for Jenkins, Azure DevOps, GitLab
- [ ] GitHub Actions plugin: `jaseci-labs/jac-loadtest-action@v1` posts to headless API; comments pass/fail + key metrics on the PR

**Plugin Architecture:**
- [ ] `ProtocolAdapter` ABC: defined Python interface for third-party protocol plugins
- [ ] Plugin registry: install server-side; UI auto-discovers installed plugins and adds protocol tab on next page load
- [ ] Official plugin list: maintained index of community adapters
- [ ] Example plugins: Redis, Kafka, AMQP (RabbitMQ) as reference implementations

**UX Polish:**
- [ ] Onboarding tour: step-by-step walkthrough for first-time users
- [ ] Test templates library: pre-built configs (REST API stress test, WebSocket broadcast, DB connection pool test)
- [ ] Dark / light theme toggle (persisted to `localStorage`)
- [ ] Keyboard shortcuts for all primary actions
- [ ] Accessibility audit (WCAG 2.1 AA)

**Deployment:**
- [ ] Docker image: single container running `jac serve`
- [ ] `docker-compose.yml` example: web app + optional worker node agents
- [ ] Auth layer (optional): toggle-able login wall for team deployments; API token for headless CI
- [ ] Public website with docs, changelog, and hosted demo instance

**Exit criterion:** `jac install jac-loadtest-cli && jac loadtest --help` works from PyPI; `docker run jaseci/jac-loadtest` serves the web app; GitHub Actions CI plugin is published.

---

## Milestone Summary

| Milestone | Phase | CLI Deliverable | Web Deliverable |
|-----------|-------|-----------------|-----------------|
| M1 | 0 | `jac loadtest --help` works | — |
| M2 | 1 | HAR replay + console report | — |
| M3 | 2 | Per-VU JWT injection + username/password auth | — |
| M4 | 3 | Per-service routing + breakdown | — |
| M5 | 4 | Graceful shutdown, thresholds, exit codes, RPS cap | — |
| M6 | 5 | JSON + HTML reports, p99.9, Apdex, TTFB | — |
| M7 | 6 | `LoadTestConfig.from_dict()`, `run_test_headless()` with SSE callback | User accounts; workspace wizard (mode, URL/services-map, HAR, credentials); load test runs with live dashboard and HTML report download |
| M8 | 7 | `PersonaConfig`, `run_personas()`, `RequestResult.persona`, `--persona-file` | Standard/Persona mode toggle; 3 built-in personas; HAR entry selector per persona; per-persona report section |
| M9 | 8 | — (Phase 7 CLI unchanged; all new work is web/sv) | Discovery source picker (HAR / spec / browser agent); AI persona assignment with rationale tooltips; `spec_parser.sv.jac`, `browser_agent.sv.jac`, `persona_ai.sv.jac` |
| M10 | 9 | `ws_engine.jac`, `graphql_engine.jac` | GraphQL + WebSocket protocol UI |
| M11 | 10 | `grpc_engine.jac`, `db_engine.jac` (Postgres/MySQL/MongoDB) | gRPC builder, SQL/Mongo query editors |
| M12 | 11 | `--worker-nodes` flag, `jac loadtest worker` server mode | Worker management UI, geo region reporting |
| M13 | 12 | PyPI release + jac-scale integration | Docker image, CI plugin, public launch |

---

## Protocol Support Target

| Protocol | Phase | CLI Adapter | Web UI |
|----------|-------|-------------|--------|
| HTTP/HTTPS | 0–5 (existing) | `core/engine.jac` | Phase 6 |
| GraphQL (query/mutation) | 7 | `core/graphql_engine.jac` | Phase 7 |
| GraphQL subscriptions | 7 | `core/ws_engine.jac` (graphql-ws) | Phase 7 |
| WebSocket (raw) | 7 | `core/ws_engine.jac` | Phase 7 |
| gRPC | 10 | `core/grpc_engine.jac` | Phase 10 |
| PostgreSQL | 10 | `core/db_engine.jac` | Phase 10 |
| MySQL | 10 | `core/db_engine.jac` | Phase 10 |
| MongoDB | 10 | `core/db_engine.jac` | Phase 10 |
| MQTT | 11 | `core/mqtt_engine.jac` | Phase 11 |
| Redis | 12 (plugin) | Community plugin | Phase 12 |
| Kafka | 12 (plugin) | Community plugin | Phase 12 |
| AMQP (RabbitMQ) | 12 (plugin) | Community plugin | Phase 12 |
