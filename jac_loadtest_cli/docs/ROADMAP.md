# jac-loadtest Roadmap

What is built and what is planned for `jac-loadtest-cli` (the CLI and its headless engine). The
web app has its own roadmap: [`../../jac_loadtest_web/docs/ROADMAP.md`](../../jac_loadtest_web/docs/ROADMAP.md).

Principles: CLI-first (front ends wrap `headless.jac`); no embedded AI; no `--engine k6` backend
(scale-out is native distributed mode, Phase 11).

## Status

| Phase | Scope | Status |
|---|---|---|
| 0–5 | Foundation, HAR replay, auth + think time, microservice mode, hardening, reporting | ✅ Done |
| 6 | Headless entry points, capacity-testing flags, harness fixes | ✅ Done |
| 7 | Multi-user realism | ◑ 7a–7c, 7F done; 7d, 7e open |
| 8 | Result fidelity and regression gating | ◑ 8a, 8b, 8d done; 8c and one 8d item open |
| 9 | WebSocket and GraphQL | ◑ Replay, auto-detect, multiprocess done; scenario files and `introspect_schema()` open |
| 10 | Pluggable auth and a built-in recorder | ⬜ Not started |
| 11 | Distributed load generation | ⬜ Not started |
| 12 | Release and observability | ⬜ Not started |
| 13 | gRPC / DB / MQTT | ⬜ Demand-driven |

Critical path: **7 → 8 → 12**. Phases 10, 11 and 13 follow adoption.

---

## Done

**Phases 0–5.** HAR parsing and filtering; asyncio VU engine; per-VU JWT auth; think time and ramp-up;
microservice routing by path prefix; `--rps`; threshold gates with exit codes and `--abort-on-fail`;
multi-process workers; console, JSON and HTML reports; p99.9, Apdex, TTFB.

**Phase 6.** `LoadTestConfig.from_dict()`, `run_test_headless()`, live snapshots; `--open-loop`,
`--duration`, `--step-load` with capacity knee, `--csrf`, `--assert-json`, `--slo`, trace-ID capture;
fixes for timeout-skewed percentiles, fractional `rps`, sample eviction and per-interval series.

**Phase 7 — multi-user realism**
- 7a Response correlation: auto-detected from the HAR, plus `--correlate` and `x-jac-correlate`.
- 7b Per-VU account pool (`--accounts`), register on demand, mid-run re-auth on 401, `--skip-failed-accounts`, auth-burst pacing.
- 7c Test data: `--param` files and `{{uuid}}`, `{{vu_id}}`, `{{iter}}`, `{{randint}}`, `{{now}}`, `{{account.<col>}}`, `{{env.<VAR>}}`.
- 7F `--health-check` side channel with endpoint-scoped `--fail-on-p95/p99`.

**Phase 8 — result fidelity**
- 8a `INFRA_BLOCK_SUSPECTED` detection (WAF/rate-limit pages excluded from the error rate) and `--proxy-pool`.
- 8b Body check for failures inside HTTP 200 (`APP_ERROR_IN_200`), `--check-shape`, scoped `--assert-json`, `--poll-until` wait-until polling.
- 8d Multi-process fidelity: fleet-wide `--abort-on-fail`, exact live percentiles, `--max-samples` split.

**Phase 9.** WebSocket and GraphQL (query, mutation, subscription) auto-detected from the HAR and
replayed at any `--workers` count; the WebSocket handshake is reported as a `[connect]` row.

---

## Open

**7d Randomised think time.** `--think-time gaussian` (+ `--think-time-stddev`) and `--think-time-jitter`.

**7e Personas.** `--persona-file` splits load across user archetypes, each replaying a subset of
the HAR; reports group by persona.

**8c Regression gate.** `--baseline prev.json` and `--fail-on-regression "p95:10%,error_rate:0.5pp"`;
per-endpoint diff in the report. The highest-value open item for CI use.

**8d `--step-load` with `--workers > 1`.** Each worker ramps its share in lockstep; the controller
merges per-step results.

**9 WebSocket / GraphQL remainder.** `--ws-scenario` / `--graphql-scenario` files for tests with no
captured frames; `introspect_schema()`; a clearer "no frames" warning.

**10a Pluggable auth.** `--auth-type {jac-scale|bearer|basic|apikey|oauth2-cc|none}`,
`--auth-header/--auth-value`, `--auth-token-path`, `--auth-body-template`, `--auth-adapter pkg.mod:Class`.

**10b Built-in recorder.** `jac x loadtest record --port N --out r.har [--scope URL]`; captures
WebSocket frames; optional `--via cdp`; `--redact-headers`.

**11 Distributed load.** `jac x loadtest worker --port N`; `--worker-nodes [region:]host:port,...`;
controller pre-authenticates and splits VUs; merged metrics with region labels; mDNS discovery;
controller-driven `--step-load`. Non-goal: globally coordinated request pacing.

**12 Release and observability.** `--output prometheus|influxdb|otlp`; `--report-format junit`;
`ProtocolAdapter` interface and plugin registry; PyPI release, Docker image, GitHub Action with the
baseline diff as a PR comment.

**13 Extended protocols (only on demand).** gRPC, PostgreSQL/MySQL/MongoDB, MQTT, mixed-protocol steps.

---

## Removed

| Removed | Why |
|---|---|
| AI persona assignment and `by-llm` browser agent | A general coding agent does this better; personas stay as a hand-authored file (7e). |
| `--engine k6` backend | Would fork the report format, auth and metrics; native distributed mode replaces it. |
| OpenAPI import (`--spec`, `from-spec`, built in 0.8.0) | One placeholder request per operation, no field values, cannot tell actions apart. |
