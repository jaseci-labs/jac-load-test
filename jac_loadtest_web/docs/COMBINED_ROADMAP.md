# jac-loadtest-web — Roadmap (Frozen)

**Web development is frozen at the Phase 6 MVP.** As of the 2026-09 roadmap restructure, the
project is **CLI-first**: every capability from Phase 7 onward is built in `jac-loadtest-cli`
as engine + headless-function code only. The web app is no longer a roadmap driver.

## Current state (shipped)

`jac-loadtest-web` is a working browser GUI for standard HTTP load testing:

- jac-scale built-in auth (`/user/register`, `/user/login`)
- Workspace wizard — monolith / microservice, HAR upload, optional single credential
- Run creation form — VUs, iterations, ramp-up, workers, RPS, think time, timeout, thresholds
- Live SSE dashboard — RPS + latency charts, error-rate badge, stop button
- Post-run report — summary table, per-endpoint bars, error breakdown
- JSON / HTML report download

Data models (`Workspace`, `LoadTestRun`) persist as jac-scale nodes in the `sv` codespace.

## Why frozen

See [`../../jac_loadtest_cli/docs/COMBINED_ROADMAP.md`](../../jac_loadtest_cli/docs/COMBINED_ROADMAP.md)
— section "Web App Status" and the revision note at the top. In short: the priority is
validating jac-scale's scalability story with the CLI (correlation, per-VU identity,
regression gating, distributed load), and a GUI adds surface area without moving that goal.

## If the web app resumes

The engine's headless contract is stable and designed to be wrapped:

- `LoadTestConfig.from_dict(d)` — build a config from a plain dict, no argparse, no toml
- `run_test_headless(config, on_snapshot=, stop_event=, on_html_report=)` — run the engine,
  stream snapshots, cancel mid-run, capture the HTML report
- `render_json()` / `render_html()` — plain functions, no CLI context

New Phase 7+ engine features land as additional headless functions (`parse_api_spec`,
`start_recorder`, persona blocks on `run_test_headless`, …). Resuming the web app means
adding thin `sv` walkers that call these and stream results — no engine rewrite.

## The single source of truth

[`jac_loadtest_cli/docs/COMBINED_ROADMAP.md`](../../jac_loadtest_cli/docs/COMBINED_ROADMAP.md)
is the live roadmap for the whole project.
