# jac-loadtest-web — Roadmap

**Status: frozen at the Phase 6 MVP.** The project is CLI-first: every capability from engine
Phase 7 onward is built in `jac-loadtest-cli` as engine + headless-function code, and the web
app is not a roadmap driver. The engine's own plan lives in
[`../../jac_loadtest_cli/docs/ROADMAP.md`](../../jac_loadtest_cli/docs/ROADMAP.md).

---

## Phase 6 — Web MVP ✓

> A user with no CLI experience can run a complete authenticated load test from a browser tab.

`jac-loadtest-web` is a working browser GUI for standard HTTP load testing:

- jac-scale built-in auth (`/user/register`, `/user/login`)
- Workspace wizard — monolith / microservice, HAR upload, optional single credential
- Run creation form — VUs, iterations, ramp-up, workers, RPS, think time, timeout, thresholds
- Live SSE dashboard — RPS + latency charts, error-rate badge, stop button
- Post-run report — summary table, per-endpoint bars, error breakdown
- JSON / HTML report download

Data models (`Workspace`, `LoadTestRun`) persist as jac-scale nodes in the `sv` codespace.

**Exit criterion:** a user registers, creates a monolith workspace with a HAR and credentials,
runs a 50-VU / 60s test, watches live charts, sees a threshold pass/fail summary, and
downloads an HTML report — without touching a terminal. ✓

### Descoped by the freeze

These bullets from the original plan were not built and return only if the web app resumes:
proxy recorder UI, "replace HAR", workspace settings panel, ramp-up ring, debug log panel,
"re-run with same settings". The per-phase web checklists that used to accompany engine
Phases 7–12 were dropped for the same reason.

---

## Why frozen

The priority is validating jac-scale's scalability story with the CLI — correlation, per-VU
identity, regression gating, distributed load — and a GUI adds surface area without moving that
goal. Engine work from Phase 7 onward therefore lands as CLI flags plus headless functions only.

---

## Architecture rule

The web app is a presentation shell. Its `sv` walkers only call a headless engine function,
persist the result, and stream progress over SSE. No decision, parser, state machine, or
protocol client ever lives in an `sv` walker.

## The engine contract it depends on

Stable and designed to be wrapped:

- `LoadTestConfig.from_dict(d)` — build a config from a plain dict, no argparse, no toml
- `run_test_headless(config, on_snapshot=, stop_event=, on_html_report=)` — run the engine,
  stream snapshots, cancel mid-run, capture the HTML report
- `render_json()` / `render_html()` — plain functions, no CLI context

The stop button relies on a cross-process stop signal (`_RunStopSignal` in
`web/services/run_walkers.jac`); the CLI engine uses the same spawn-context `Event` mechanism for
its fleet-wide `--abort-on-fail`. Live percentiles streamed to the dashboard are exact across
worker processes since engine Phase 8d.

## If the web app resumes

New engine features land as additional headless functions (`start_recorder`,
persona blocks on `run_test_headless`, …). Resuming the web app means adding thin `sv` walkers
that call these and stream results — no engine rewrite. The descoped items above would be
revisited first.

## Until then

For correlation, per-VU accounts, personas, regression gating, distributed load,
or any protocol beyond HTTP / WebSocket / GraphQL: use the CLI
(see the [engine roadmap](../../jac_loadtest_cli/docs/ROADMAP.md)).
