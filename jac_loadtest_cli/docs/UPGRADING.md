# Upgrading

What changes between releases, and why your numbers may move.

## 0.10.0 → unreleased (breaking)

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
jac 0.34.17, and 0.6.0 does not build on 0.31.x.

To recover the old behaviour for a comparison run:
`--no-auto-correlate --no-body-check --infra-block-threshold 1 --no-auto-register`.
