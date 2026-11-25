# Upgrading

What changes between releases, and why your numbers may move.

## 0.10.0 → unreleased: Locust engine (breaking)

The custom asyncio engine is replaced by [Locust](https://locust.io) (issue #46). Load generation,
scheduling, workers, statistics, the console tables and the HTML report are now Locust's; the
JSON report is still ours. **Numbers are not comparable with 0.10.x**: it is a different measuring
instrument.

**Removed flags** (Locust does these natively, or they were not worth rebuilding):
`--rps`, `--open-loop`, `--proxy-pool`, `--auth-delay`, `--auth-batch-size`, `--auth-batch-delay`,
`--think-time scaled` and `--think-time-scale`, `--max-samples`, `--apdex-t`, `--slo`.
Passing one is now an argparse error. A web request or `from_dict` config that still carries them
is accepted and ignores them.

**Changed behaviour**

- **Percentiles are approximate.** Locust keeps bucketed response times (two significant digits above
  100 ms) and reports whole milliseconds. There is no TTFB.
- **Report fields removed:** Apdex, good/bad ratings, `latency_benchmarks`, completion-time
  percentiles. The report gains `engine`, `auth` (login/register counts, failed accounts),
  per-endpoint `method`, and keeps `step_load` and `capacity_knee_vus`.
- **`--step-load` works with `--workers`** (it was single-process).
- **`--workers N`** starts a Locust master here and N worker processes. User ids are unique across
  workers, so no two workers log in the same account.
- **WebSocket and GraphQL entries replay inside each user's iteration**, in recorded order, instead
  of as separate user populations. Explicit `ws_scenarios` / `graphql_scenarios` run after the
  recorded flow on every iteration; their own `vus`, `iterations` and `duration` no longer apply.
- **Duplicate-account detection** accepts jac-scale 0.39's `IDENTITY_TAKEN` as well as
  `USER_EXISTS`, and reads the code from `error.code`. Register's token is reused instead of a second login.
- **`--skip-failed-accounts`:** users whose account fails stop; the rest run (they are no longer
  re-spread over the accounts that worked).
- **Console output** is Locust's tables, logged with Locust's `INFO -` prefix, followed by a one-line
  total. Auth rows (`auth: login`) appear in Locust's own table but not in our totals.
- **`jac.toml` needs `[placement] default = "server"`** if you build on this source: native lowering
  never applies to it and can exhaust memory on small machines.

**Embedders:** `run_test_headless(config, on_snapshot, stop_event, on_html_report)` keeps its shape and
returns the JSON report, but runs the test in a child process, so your process never imports Locust
(it patches the standard library with gevent). Snapshot objects have `timestamp`,
`total_requests`, `p50_ms`, `p95_ms`, `p99_ms`, `rps`, `error_rate_pct`. `core/engine`,
`core/metrics`, `output/reporter`, `AuthProvider` and the old protocol adapters are gone.

## 0.10.0 → unreleased (breaking)

**Requires jac 0.39.2** (was 0.34.17); the source no longer compiles on 0.34. Three
user-visible changes follow from the toolchain, plus a dependency floor:

- **Config table moved.** Defaults now live in a top-level `[loadtest]` table in `jac.toml`.
  `[plugins.scale.loadtest]` is gone: jac 0.39 removed the plugin system. A manifest that still has
  it loads without error, but nothing reads it, so those settings are **ignored** (the tool prints
  a warning naming the table). Rename it to `[loadtest]`.
- **Microservice routing comes from service apps.** `[scale.microservices.routes]` no longer exists.
  Declare each service as `[apps.<name>] kind = "service"` with an `entry-point` and an optional
  `route` (default `/api/<name>`); that route is the path prefix requests are matched on.
  `--services-map` is unchanged.
- **Service URL env vars renamed.** `JAC_SV_<NAME>_URL` is now `JAC_APP_<APP>_URL`, with every
  non-alphanumeric character in the app name turned into `_` (`order-service` →
  `JAC_APP_ORDER_SERVICE_URL`), exactly as jac itself names them.
- **`aiohttp>=3.11`** (was 3.9): the WebSocket and GraphQL engines pass `ClientWSTimeout`.

Embedder API: callbacks and stop flags are now typed. `on_snapshot` is a
`Callable[[StatsSnapshot], None]` and `stop_event` any object with `is_set()` and `set()`
(`core/stop_signal.jac`); `asyncio.Event` and multiprocessing events both qualify.
`parse_assert_json()` is annotated with the `(path, value, endpoint)` triples it always returned.
The wheel now vendors the jac runtime it needs.

OpenAPI/Swagger import is removed: `--spec`, `jac x loadtest from-spec`, `core/spec_parser.jac`,
`parse_api_spec()`, the `LoadTestConfig.spec` field and the `pyyaml` dependency. `har_file` is a
required positional argument again. HAR-driven commands are unaffected.

## 0.9.0 → 0.10.0

Additive. `--poll-until` / `--poll-error-until` turn a recorded run of adjacent same-endpoint calls
(a status-polling loop) into a wait-until step scored as one result, so a job that is slower than
the recording, or never finishes, is no longer a false pass. New: `--poll-timeout` (default
`60s`), `--poll-interval` (default: recorded gap). Without these flags, replay is unchanged.

## 0.8.2 → 0.9.0

Additive, `--accounts` only. `--auth-delay`, `--auth-batch-size` + `--auth-batch-delay` pace the
pre-run register/login burst so a large pool does not trip a rate limiter. The batch flags must be
given together; the batch pause wins on a batch boundary; no delay follows the last account.

## 0.8.1 → 0.8.2

Only affects explicit `--correlate` rules. They are now resolved against the HAR at startup like
detected rules: they substitute the id anywhere it appears (including inside a larger string),
fewer spurious `CORRELATION_MISS`, and `Producer.path -> Consumer` (no target path) is valid. A
rule that cannot be resolved and has no target path fails fast. If a producer recorded several
distinct values, only the first is threaded (with a warning).

## 0.8.0 → 0.8.1

Body check now unwraps jac-scale's `data` / `data.result` envelope and flags any
`reports[].success: false`. **The error rate may rise on a real jac-scale app**: failures that were
previously counted as successes now show. A bare top-level `{"ok": false}` is still left alone
(use `--assert-json 'ok=true'`).

## 0.7.0 → 0.8.0

Additive: OpenAPI import (`--spec`, `from-spec`). Removed again in the next release (see above).

## 0.6.1 → 0.7.0

Additive. `--health-check PATH` and endpoint-scoped `--fail-on-p95` / `--fail-on-p99`
(`ENDPOINT:MS`). Without them, output and thresholds are identical to 0.6.1.

## 0.6.0 → 0.6.1

WebSocket runs only. The handshake is now recorded as a `<endpoint> [connect]` row, so
`total_requests` rises by one per connection per iteration per VU; re-check stored baselines and
thresholds. Message rows are unchanged.

## 0.5.1 → 0.6.0

**The same HAR against the same target reports different numbers**, because failures that were
counted wrongly (or not at all) are now counted correctly. If a run that looked clean suddenly
does not, check this table before suspecting your service.

| Behaviour | Now | Turn off with |
|---|---|---|
| Response correlation | on | `--no-auto-correlate` |
| Body check (failure inside a 200) | on | `--no-body-check` |
| Infra-block detection | on | `--infra-block-threshold 1` |
| Account creation on login failure | on | `--no-auto-register` |
| Re-auth on mid-run 401 | on | (only fires when a 401 would have failed) |

`--check-shape` and `--skip-failed-accounts` are opt-in. Effects: the **error rate may rise** (body
check), **may fall** (WAF pages no longer counted as app errors; the rate is now rated against
requests the application received, so `success + errors + infra_blocks == total`), **create/update/
delete workflows may start passing** (correlation), and **multi-process runs now honour settings
that silently defaulted in workers before**.

Embedder API changes: `AuthProvider.authenticate_all()` returns an `AuthOutcome`;
`parse_assert_json()` returns `(path, value, endpoint)` triples; `run_all_protocols()` moved to
`core/protocols.jac` (still re-exported from `headless.jac`). The JSON report gained
`infra_block_count`, `parameterized_fields` and `skip_failed_accounts`. The toolchain is pinned to
jac 0.34.17 at the time, and 0.6.0 did not build on 0.31.x. (Superseded: see "0.10.0 → unreleased".)

To recover the old behaviour for a comparison run:
`--no-auto-correlate --no-body-check --infra-block-threshold 1 --no-auto-register`.
