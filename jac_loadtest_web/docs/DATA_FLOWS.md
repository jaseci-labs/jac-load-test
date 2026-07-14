# Data Flows

End-to-end traces of the app's core user flows across the client (`.cl.jac`
pages/components), the server (`services/*.jac` walkers), and the data layer
(graph nodes in `models/*.sv.jac`, jac-scale identity storage, and the
`jac_loadtest_cli` engine). Paths are relative to `jac_loadtest_web/web/`
unless noted otherwise.

All `root spawn some_walker(...)` calls compile to `POST /walker/some_walker`
requests carrying the caller's JWT (see [Login](#login)); all node writes in
this dev setup persist to jac-scale's default local SQLite store under
`.jac/data/` (no `[scale.database]` configured in `jac.toml`).

---

## Login

Authenticates an existing user and hands the client a JWT used for every
subsequent `root spawn` call. This flow runs entirely on jac-scale's
**built-in** auth endpoints — there is no custom `auth_walkers.jac` in this
app (see `main.jac`'s module docstring).

1. **`pages/Login.cl.jac`** — email/password form. `handleSubmit` calls
   `jacLogin(email, password)` (`@jac/runtime`), which POSTs to jac-scale's
   built-in `/user/login` endpoint.
2. jac-scale's built-in identity subsystem authenticates the credentials
   against its identity store (local SQLite in this dev setup) and mints a
   stateless JWT.
3. `jacLogin` is a plain `bool` — no separate token plumbing in page code:
   on success it has already stored the JWT under
   `localStorage["jac_token"]` via `jacSetToken` internally, so it's
   attached as `Authorization: Bearer <token>` on every later RPC.
   `Login.cl.jac` just checks the returned bool and navigates to
   `/workspaces` on success, or shows "Invalid email or password" on
   failure.

Sibling flows, same shape:
- **Register** — `pages/Register.cl.jac` → `jacSignup(email, password)`
  against built-in `/user/register`. `jacSignup` does **not** establish a
  session by itself (returns `{"success": ..., "error"?: ...}`, no token) —
  `handleSubmit` always follows a successful signup with `jacLogin(email,
  password)` to actually log the new user in before navigating to
  `/workspaces`.
- **Session guard** — protected routes are wrapped in `<AuthGuard
  redirect="/login">` (`@jac/runtime`, wired in `frontend.cl.jac`), which
  redirects to `/login` when there's no valid token instead of each page
  checking a `me`-style walker itself.
- **Logout** — `jacLogout()` (`@jac/runtime`) clears the stored token
  client-side; called directly from pages like `WorkspaceList.cl.jac`
  (`handleLogout`) rather than through a custom walker — jac-scale issues
  stateless JWTs with no server-side revocation list, so there's nothing to
  invalidate server-side.

| Layer | File |
|---|---|
| Frontend | `pages/Login.cl.jac`, `pages/Register.cl.jac`, `frontend.cl.jac` (`AuthGuard`) |
| Backend | jac-scale's built-in `/user/register`, `/user/login`, `/user/me`, `/user/logout` endpoints — no app-level walkers |
| Data layer | jac-scale identity storage — local SQLite in dev |
| Entry registration | `main.jac` (must plain-`import` every **app-level** walker used by a `.cl.jac` page — see note below; built-in auth endpoints need no such registration) |

> **Why `main.jac` matters:** an app-level walker only becomes an HTTP
> endpoint if its name is bound into `main.jac`'s own namespace
> (`ModuleIntrospector` scans `main.jac` via `inspect.getmembers`, not every
> loaded `.jac` file). Every such walker a page imports must also appear in
> `main.jac`'s top-level imports, or calls to it 405.

---

## Workspace Creation

A 5-step wizard that captures a target app, a HAR recording of real traffic
against it, and optional replay credentials — the reusable "project" that
runs are created against.

1. **`pages/WorkspaceCreate.cl.jac`** — local wizard state only (`step`,
   `name`, `mode`, `har_entries`, etc.), nothing hits the server until a step
   needs it:
   - **Step 2 (Target)**, monolith mode only: "Check reachability" button →
     `root spawn check_reachability(url=target_url)` →
     `services/workspace_walkers.jac`'s `check_reachability` walker does a
     best-effort `aiohttp` GET with a 5s timeout and reports
     `{"reachable", "status", "error"}`. Purely advisory — never blocks
     creation (the sv server may not share network reachability with real
     load-test traffic).
   - **Step 3 (HAR)**: file input → `handleHarFile` does a **raw multipart
     `fetch("/walker/upload_har", ...)`** (not `root spawn` — a `File` can't
     serialize through the JSON-only RPC stub). Hits
     `services/file_walkers.jac`'s `upload_har` walker, which parses the raw
     HAR JSON, flags sensitive headers (`authorization`/`cookie`) as a
     security warning, and reports per-request `{method, url, status,
     mime_type, time, headers, enabled}` rows plus the raw HAR text — none of
     this is persisted yet, it just fills the wizard's review table
     (`components/HarEntryTable.cl.jac`), where the user can toggle
     individual requests off.
   - **Step 4 (Credentials)**: optional single username/password + login
     path, kept in local wizard state.
   - **Step 5 (Review)**: `handleCreate` → `root spawn
     create_workspace(name, description, mode, target_url |
     services_map_json, username, password, login_path, har_raw_json,
     har_entries_json)`.
2. **`services/workspace_walkers.jac`** (`create_workspace`):
   validates required fields (name; target URL for monolith / service map
   for microservice; a HAR is mandatory; username+password must be
   both-or-neither), then writes a new **`models/workspace.sv.jac`**
   `Workspace` node directly off the caller's `root` (`root ++>
   Workspace(...)`) — the data-layer write. Reports a view of the node
   (`_workspace_view`, including a live `run_count` computed from
   `[root --> ][?:LoadTestRun][?workspace_id == jid(ws)]`).
3. Client navigates to `/workspaces/:id` (`pages/WorkspaceDetail.cl.jac`),
   which loads the workspace via `get_workspace` and lists its runs via
   `list_runs` — the entry point into the [run creation flow](#run-creation--execution).

| Layer | File |
|---|---|
| Frontend | `pages/WorkspaceCreate.cl.jac`, `components/HarEntryTable.cl.jac` |
| Backend (walkers) | `services/workspace_walkers.jac` (`create_workspace`, `check_reachability`, `get_workspace`, `list_workspaces`, `update_workspace`, `delete_workspace`), `services/file_walkers.jac` (`upload_har`) |
| Data layer | `models/workspace.sv.jac` (`Workspace` node, hangs off `root`) |

---

## Run Creation & Execution

Creating a run against a workspace's HAR, executing it, streaming live
metrics, and viewing the final report.

1. **`components/RunSettingsForm.cl.jac`** collects VUs, iterations,
   ramp-up, workers, RPS cap, think-time, timeout, thresholds, label →
   packaged into a `settings` dict.
2. **`pages/RunCreate.cl.jac`** (`/workspaces/:id/runs/new`): on submit,
   `root spawn create_run(workspace_id, vus, iterations, ...)`, then on
   success `root spawn start_run(run_id)`, then navigates to
   `/workspaces/:id/runs/:run_id`.
3. **`services/run_walkers.jac`** (`create_run`): validates label/VUs/
   iterations, looks up the owning `Workspace`
   (`[root --> ][?:Workspace]` scoping = ownership check), writes a new
   **`models/run.sv.jac`** `LoadTestRun` node off `root` (linked to its
   workspace only by the `workspace_id` string field, not a graph edge).
4. **`services/run_walkers.jac`** (`start_run`):
   - Re-fetches the run + workspace; requires `ws.har_raw_json` to exist.
   - `_write_filtered_har(ws)` re-applies the wizard's per-entry
     enable/disable choices over the raw HAR into a temp `.har` file.
   - `_build_config(...)` maps `LoadTestRun`/`Workspace` fields onto a
     `jac_loadtest_cli.config.LoadTestConfig`.
   - Sets up a `queue.Queue` (`_stream_queues[run_id]`, live metrics) and a
     `_RunStopSignal` (`_stop_events[run_id]`, stop button), flips
     `run.status = "running"` (persisted write), then
     `flow _execute_run(...)` hands the actual test off to a background
     thread so the HTTP request returns immediately. Reports
     `{"ok": true, "stream_url": ...}`.
5. **`_execute_run`** (same file) calls into the CLI engine, headlessly:
   - **`jac_loadtest_cli/headless.jac`**'s `run_test_headless(config,
     on_snapshot, stop_event, on_html_report)`:
     - `core/har_parser.jac` (`parse_har`) → replayable `HarEntry` list.
     - `bridge/auth.jac` (`AuthProvider`) / `bridge/topology.jac`
       (`TopologyRouter`) → login/token handling and monolith-vs-
       microservice URL routing.
     - `core/engine.jac` (`run_all_vus`) if `workers <= 1`, else
       `core/process_runner.jac` (`run_multiprocess`) fans out across OS
       processes. Each virtual user (`_run_vu`) replays the HAR entries for
       `iterations` cycles via `aiohttp`, timing TTFB/latency, feeding every
       result into `core/metrics.jac`'s `MetricsCollector`.
     - Every ~10s, a snapshot (`rps`, `error_rate_pct`, `p50/p95/p99_ms`,
       `total_requests`) is pushed via `on_snapshot` into
       `_stream_queues[run_id]`.
     - `core/output/reporter.jac` (`render_json`/`render_html`) builds the
       final report once all VUs finish (or `stop_event` fires).
   - `_execute_run` writes the terminal state back onto the `LoadTestRun`
     node: `status`, `completed_at`, `results_json`, `results_html`,
     `passed_thresholds` (data-layer write).
6. **Live streaming** — `pages/RunDetail.cl.jac` renders
   `components/MetricsDashboard.cl.jac` while the run isn't terminal. It
   opens a raw SSE `fetch("/function/stream_metrics", {method: POST, body:
   {run_id}})` (not a walker RPC — streaming can't go through the buffered
   stub) hitting **`services/stream_walkers.jac`**'s `stream_metrics`, a
   plain streaming `def` that polls `_stream_queues[run_id]` and yields SSE
   frames, adding a derived `active_vus`. Feeds
   `components/RunControl.cl.jac` (elapsed/VUs/RPS/error-rate) and
   `components/LatencyChart.cl.jac`.
   - **Stop** — `RunControl`'s stop button → `root spawn
     stop_run(run_id)` → flips `run.status = "stopped"` (persisted
     immediately) and sets the in-memory stop event; `_run_vu` checks it
     between requests.
7. **Completion** — the stream's final `{"done": true, ...}` frame triggers
   `RunDetail.handleRunFinished` → re-`get_run` to pick up
   `results_json`/`passed_thresholds` → swaps `MetricsDashboard` for
   **`components/ReportViewer.cl.jac`**: a summary table (elapsed/VUs/RPS,
   success rate, Apdex, p50/p95/p99/p99.9 latency, p50/p95/p99 completion
   times), a latency-over-time chart paired with a cumulative RPS-over-time
   chart (`components/RpsChart.cl.jac`), a per-endpoint latency bar chart
   (p50/p95/p99/p99.9), a full per-endpoint metrics table, an error
   breakdown table, JSON download from `results_json`, and HTML download
   via `root spawn get_run_html(run_id)` which just returns the stored
   `results_html`.

| Layer | File |
|---|---|
| Frontend | `components/RunSettingsForm.cl.jac`, `pages/RunCreate.cl.jac`, `pages/RunDetail.cl.jac`, `components/MetricsDashboard.cl.jac`, `components/RunControl.cl.jac`, `components/LatencyChart.cl.jac`, `components/RpsChart.cl.jac`, `components/ReportViewer.cl.jac` |
| Backend (walkers/streams) | `services/run_walkers.jac` (`create_run`, `start_run`, `stop_run`, `get_run`, `list_runs`, `delete_run`, `get_run_html`), `services/stream_walkers.jac` (`stream_metrics`) |
| Engine (`jac_loadtest_cli`, separate package) | `headless.jac`, `core/har_parser.jac`, `core/engine.jac`, `core/process_runner.jac`, `core/metrics.jac`, `output/reporter.jac`, `bridge/auth.jac`, `bridge/topology.jac`, `config.jac` (`LoadTestConfig`) |
| Data layer | `models/run.sv.jac` (`LoadTestRun` node), `models/workspace.sv.jac` (`Workspace`, read-only here) |
