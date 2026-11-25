# jac-loadtest Architecture

jac-loadtest keeps what makes it a jac-scale tool (HAR replay, auto-correlation, jac-scale auth,
failure-inside-200 checks, WebSocket and GraphQL replay) and hands load generation to
[Locust](https://locust.io): user scheduling, workers, statistics, the console tables and the HTML
report are Locust's. The JSON report is ours. Everything is Jac.

## A run

```
jac x loadtest  ─►  cli.jac  ─►  runner/api.execute()
                                      │
                    environment.jac: parse HAR once, build RunContext, start Locust
                                      │   (--workers N: this process is the master,
                                      │    N worker processes join it)
                                      ▼
                       N × HarUser (runner/users.jac), one per virtual user
                          on_start : login, register on 401 (auth_flow.jac)
                          iteration: for each HAR entry, in order
                                       correlate ─► parameterize ─► send ─► check ─► capture
                                      │ request events
                                      ▼
                       Locust stats ─► output/json_report.jac  (JSON, ours)
                                    ─► console tables, HTML    (Locust's)
                                    ─► output/thresholds.jac   (exit code)
```

Every request, WebSocket frame and poll result is reported to Locust as a request event, so one set
of stats feeds every output. Rows named `auth: ...`, `poll: ...` and `health: ...` are kept out of
the totals and the threshold pool.

## Files

| Path | Job |
|---|---|
| `plugin.jac`, `cli.jac` | Register `jac x loadtest`, parse flags, run, print, set the exit code. Locust is imported only when a run starts. |
| `config.jac` | Flags over `jac.toml` `[loadtest]` over defaults, as one `LoadTestConfig`. |
| `headless.jac` | `run_test_headless()` for embedders: runs the test in a child process and returns the JSON report. |
| `core/har_parser`, `correlation`, `parameterize` | Parse and filter a HAR; detect and apply per-user id substitution; `{{tokens}}` and `--param` feeders. Pure logic. |
| `bridge/auth` | The `--accounts` pool (JSON map/array, `.json`, `.csv`). |
| `bridge/body_check` | jac-scale's response envelope: failure inside HTTP 200, shape drift. |
| `bridge/topology` | Microservice routing by path prefix. |
| `runner/environment` | Builds the Locust environment (local, or master plus workers), drives the run, step-load, duration, abort-on-fail, snapshots. |
| `runner/users` | `HarUser`: the per-user replay loop, re-auth on 401, CSRF, poll blocks, health check. |
| `runner/auth_flow` | Login, register on 401 (`IDENTITY_TAKEN` means wrong password), over the Locust client. |
| `runner/ws_client` | WebSocket and graphql-ws replay; rows `WS /p [connect]`, `WS /p`, `GraphQL /p`. |
| `runner/checks` | `--assert-json` and `--poll-until` helpers. |
| `runner/infra` | Fingerprints failed non-JSON bodies; identical deny pages across endpoints are infra blocks. |
| `runner/steps` | Step-load: per-step windows from histogram differences, the capacity knee. |
| `runner/live` | Aggregates, snapshots and the live threshold check. |
| `runner/api`, `child`, `subproc`, `worker`, `configio` | One-call `execute()`, the child-process protocol for embedders, and the worker process entry. |
| `output/json_report`, `thresholds` | The JSON report built from Locust's stats; pass/fail over a finished report. |

## Decisions worth knowing

- **Locust patches the standard library with gevent when imported.** So it is imported only inside
  `runner/` and only in a process meant to generate load. The web app and any other embedder call
  `run_in_subprocess()`, which starts a child interpreter and talks to it through files and stdout.
- **One class, one client per user.** `HarUser` is a direct `FastHttpUser` subclass. Each user has
  its own HTTP client, which is why there is no proxy pool or connector tuning.
- **User ids are unique across workers** (`local * workers + worker_index`), so two workers never
  log in the same account.
- **WebSocket and GraphQL entries replay in order inside each user's iteration**, with the
  recorded HTTP traffic around them, not as separate user populations.
- **The JSON report is built from the same Locust stats** the console and HTML read, so the three
  agree. It adds what Locust does not know: failures by type, infra blocks outside the error rate,
  step-load results and the capacity knee.
- **`[placement] default = "server"`** in `jac.toml`. This project is Python-ecosystem code, so
  native lowering never applies; opting out keeps compiles fast and light.

Correlation ambiguity (a value that appears in several responses) is tracked separately in #47.
