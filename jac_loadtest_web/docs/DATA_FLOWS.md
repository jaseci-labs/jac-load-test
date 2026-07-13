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
subsequent `root spawn` call.

1. **`pages/Login.cl.jac`** — email/password form. `handleSubmit` first calls
   `jacLogout()` to drop any stale token (a leftover token would otherwise be
   sent as the `Authorization` header on this public call and break root
   resolution), then `root spawn login_user(email, password)`.
2. **`services/auth_walkers.jac`** (`login_user`, `walker:pub` — no token
   needed to call it):
   - `Jac.get_user_manager(base_path=".")` — jac-scale's identity subsystem.
   - `user_manager.authenticate(email, password)` — looks up the identity
     store (jac-scale `identity/user_manager.jac`, backed by the same local
     SQLite dev store) and verifies the password credential.
   - On success, `user_manager.create_jwt_token(user_id)` mints a stateless
     JWT; reports `{"token": ..., "email": ...}`.
3. Back in `Login.cl.jac`: token goes into `localStorage` and into the
   client runtime via `jacSetToken` (`@jac/runtime`, generated client
   helper) so it's attached as `Authorization: Bearer <token>` on every
   later RPC. Navigates to `/workspaces`.

Sibling flows, same shape:
- **Register** — `pages/Register.cl.jac` → `register_user` walker
  (`services/auth_walkers.jac`), which calls
  `user_manager.create_user_with_identities(...)` instead of `authenticate`.
- **Session check / logout** — `me` and `logout_user` walkers in the same
  file; `me` decodes the token via `user_manager.validate_jwt_token` rather
  than trusting `root` (see the file's module docstring for why).

| Layer | File |
|---|---|
| Frontend | `pages/Login.cl.jac`, `pages/Register.cl.jac` |
| Backend (walkers) | `services/auth_walkers.jac` (`login_user`, `register_user`, `me`, `logout_user`) |
| Data layer | jac-scale identity storage (`jaclang/scale/identity/user_manager.jac`, `identity_storage.jac`) — local SQLite in dev |
| Entry registration | `main.jac` (must plain-`import` every walker used by a `.cl.jac` page — see note below) |

> **Why `main.jac` matters:** a walker only becomes an HTTP endpoint if its
> name is bound into `main.jac`'s own namespace (`ModuleIntrospector` scans
> `main.jac` via `inspect.getmembers`, not every loaded `.jac` file). Every
> walker a page imports must also appear in `main.jac`'s top-level imports,
> or calls to it 405.

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
   **`components/ReportViewer.cl.jac`** (summary table, per-endpoint p95
   chart, error breakdown, JSON download from `results_json`, HTML download
   via `root spawn get_run_html(run_id)` which just returns the stored
   `results_html`).

| Layer | File |
|---|---|
| Frontend | `components/RunSettingsForm.cl.jac`, `pages/RunCreate.cl.jac`, `pages/RunDetail.cl.jac`, `components/MetricsDashboard.cl.jac`, `components/RunControl.cl.jac`, `components/LatencyChart.cl.jac`, `components/ReportViewer.cl.jac` |
| Backend (walkers/streams) | `services/run_walkers.jac` (`create_run`, `start_run`, `stop_run`, `get_run`, `list_runs`, `delete_run`, `get_run_html`), `services/stream_walkers.jac` (`stream_metrics`) |
| Engine (`jac_loadtest_cli`, separate package) | `headless.jac`, `core/har_parser.jac`, `core/engine.jac`, `core/process_runner.jac`, `core/metrics.jac`, `output/reporter.jac`, `bridge/auth.jac`, `bridge/topology.jac`, `config.jac` (`LoadTestConfig`) |
| Data layer | `models/run.sv.jac` (`LoadTestRun` node), `models/workspace.sv.jac` (`Workspace`, read-only here) |
