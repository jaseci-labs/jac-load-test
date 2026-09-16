# Upgrading

## 0.8.1 → 0.8.2

**Only affects runs using explicit `--correlate` rules (or `x-jac-correlate` HAR annotations).**
Auto-detected correlation, the wire format, and every other flag are unchanged.

An explicit rule used to inject only by overwriting one exact JSON field, and would abort the
request the instant its consumer endpoint matched and the value hadn't been captured yet —
regardless of whether the target field was even present in that particular occurrence. Both
limits existed because explicit rules never learned the literal value the recording actually
used, unlike auto-detected rules, which do.

Explicit rules are now hydrated with that literal at startup, read straight from the HAR
response the producer endpoint recorded. Once resolved, an explicit rule behaves like a detected
one: it substitutes the id anywhere it appears (including inside a larger string, like
`/project/{id}`) instead of only in a whole field, and it only reports a value as missing when
the recording shows that occurrence actually needed it.

What moves as a result:

- **Fewer spurious `CORRELATION_MISS` failures** on `--correlate` rules whose target field isn't
  present in every occurrence of the consumer endpoint.
- **`--correlate 'Producer.path -> Consumer'` (no target path) is now valid** — useful when you
  don't know or care which field carries the id, since literal-substring mode doesn't need one.
- If a producer's value can't be resolved from the HAR at all (the field is null/absent in the
  recording) and the rule also has no target path, `--correlate` now fails fast at startup with a
  clear message, instead of the rule silently never firing.
- If a producer recorded more than one distinct value for the same field, the rule threads only
  the first and prints a warning — true per-occurrence correlation isn't supported yet.
- Startup output now tags each correlation rule `[literal-substring]` or `[json-path-set]` so you
  can see which mode a rule resolved to.

## 0.8.0 → 0.8.1

**Only affects runs against a jac-scale app where `--body-check` finds something to catch.**
Everything else — the wire format, every other flag, the report shape — is unchanged.

`check_body()` used to read `error`/`errors`/`status`/`reports` off the raw top level of the
response JSON. jac-scale's actual walker envelope nests all of that inside
`data`/`data.result`, so a walker that declined a request — a duplicate name, a quota gate, an
ownership check — and answered with HTTP 200 and `reports: [{"success": false, "error": "..."}]`
sailed straight through as a counted success. Body-check now unwraps `data`/`data.result` before
running its checks, and adds a new one: any `reports[]` entry whose own `success` is `false` is
flagged, alongside the existing `error`/`errors`/inner-status/empty-reports signals (now checked
at the right nesting level too).

What moves as a result:

- **Error rate may rise** on a run against a real jac-scale app. This is the tool catching what
  it previously missed — a run that looked clean at 0% errors may now show the rejections that
  were happening the whole time, just invisibly. Confirmed live: a project-creation walker
  silently rejecting a duplicate name under concurrent VUs used to report 91%+ success; the
  failure only ever surfaced downstream as unrelated-looking errors on other endpoints (or, with
  `--correlate` in play, as `CORRELATION_MISS`) rather than at its actual source.
- **Not affected:** a bare top-level `ok: false` with no `data`/`reports` wrapper is still left
  alone — that's an app-specific convention, not something this jac-scale-specific module should
  guess at. Use `--assert-json 'ok=true'` for that case, same as before.
- No new flags. `--no-body-check` still turns the whole check off, same as in 0.6.0.

If a run that used to look clean suddenly does not, that is very likely a real rejection
body-check can now see — check the endpoint named in the new `APP_ERROR_IN_200: reports[].success
is false (...)` error, not a regression in your service.

## 0.7.0 → 0.8.0

**Purely additive — nothing changes for an existing run that doesn't opt in.**

- `jac x loadtest from-spec <source> --out <recording.har>` generates a HAR file from an
  OpenAPI 3.0/3.1 or Swagger 2.0 document (path or URL, JSON or YAML) — one entry per
  operation, replayed exactly like a browser-recorded HAR through the normal
  `jac x loadtest <har_file> ...` flow.
- `jac x loadtest --spec <source> --url <target> [options]` skips the HAR file entirely —
  `--spec` replaces the `har_file` positional and loads the spec straight into memory.
  `har_file` and `--spec` are mutually exclusive; exactly one is required.
- `core/spec_parser.jac`'s `parse_api_spec(source: str) -> list[dict]` is headless-callable
  for embedders that want the synthesised entries directly.
- New dependency: `pyyaml` (for YAML spec documents; JSON specs need no extra dependency).

Existing HAR-driven commands and `jac.toml` entries are unaffected — `har_file` still works
exactly as before, and `core/har_parser.jac:parse_har()`'s output is unchanged (it now
delegates to the new `parse_har_entries()`, but the public signature and behavior are the same).

## 0.6.1 → 0.7.0

**Purely additive — nothing changes for an existing run that doesn't opt in.**

- `--health-check PATH` fires one extra unauthenticated `GET` request to `--url` + PATH, once
  per VU per completed iteration, alongside the HAR replay. It gets its own row in the endpoint
  report, but is excluded from the run's global/TOTAL aggregates and from the plain global
  `--fail-on-p95`/`--fail-on-p99` gate — a fast liveness ping blended into those would make them
  easier to pass than the recorded traffic actually performed. Requires `--url`.
- `--fail-on-p95`/`--fail-on-p99` gain a repeatable `ENDPOINT:MS` scoped form (e.g.
  `--fail-on-p99 "/healthz/live:100"`), checked against that one endpoint's own p95/p99. A bare
  value (`"500"`) still sets the plain global threshold exactly as before — existing commands
  and `jac.toml` entries using the bare form are unaffected. At most one bare value is allowed
  per flag; scoped values are CLI-only, like `--assert-json`/`--correlate`.

If you don't pass `--health-check`, report output, `total_rps`, and every `--fail-on-*`
threshold are byte-for-byte the same as 0.6.1.

## 0.6.0 → 0.6.1

**Only affects runs whose HAR contains WebSocket entries.** Everything else is unchanged.

The WebSocket handshake is now recorded as a sample under a `<endpoint> [connect]` label. It
was not recorded before, so a connection with no frames to replay — the usual case, since a
Chrome DevTools HAR export drops `_webSocketMessages` — generated real connect/disconnect load
on every iteration and produced no samples at all. The target felt it; the report did not show
it. (A *failed* connect was already recorded, so the endpoint was silent when it worked and
loud when it broke.)

What moves as a result:

- `total_requests` rises for any run with WebSocket entries, by one per connection per
  iteration per VU. A stored baseline or a `--fail-on-*` threshold tuned against a WebSocket
  run will need re-checking.
- A new endpoint row appears per WebSocket scenario. Connect latency is kept out of the message
  round-trip percentiles deliberately — the two measure different things.
- Message-traffic numbers are unchanged.

If you parse the JSON report, select message rows explicitly rather than assuming one row per
scenario; `endpoint` ends with `[connect]` for handshake rows.

## 0.5.1 → 0.6.0

**The same HAR against the same target will report different numbers.** That is the point of
this release — several classes of failure that 0.5.1 counted wrongly (or not at all) are now
counted correctly. Nothing about your target changed; what the tool can see did.

If a run that used to look clean suddenly does not, work through the table below before
suspecting a regression in your service.

### Defaults that changed

| Behaviour | 0.5.1 | 0.6.0 | Turn it off with |
|---|---|---|---|
| Response correlation | Not available | **On** — IDs a response hands to a later request are threaded per VU | `--no-auto-correlate` |
| Body-level correctness | Not available | **On** — a 200 carrying a jac-scale error envelope is a failure | `--no-body-check` |
| Infrastructure-block detection | Not available | **On** — identical non-JSON bodies across ≥3 endpoints are separated from application errors | `--infra-block-threshold 1` |
| Account creation | Not available | **On** — a missing account is registered and the login retried | `--no-auto-register` |
| Mid-run re-authentication | Not available | **On** — a 401 triggers one re-login and retry | *(no flag; it only fires when a 401 would otherwise have failed)* |

Shape drift (`--check-shape`) and tolerating failed accounts (`--skip-failed-accounts`) are
**off** by default and opt-in.

### What each change does to your numbers

**Error rate may rise.** `--no-body-check` was not an option before, because the check did not
exist: a jac-scale walker returning `{"error": ...}` inside an HTTP 200 counted as a success.
Runs that reported 0% errors may now report real ones. This is the tool catching what it
previously missed, not new breakage.

**Error rate may also fall.** If your target sits behind a WAF or rate limiter, deny pages that
0.5.1 counted as application errors are now classified separately and excluded from the rate.
Note the denominator changed too: the success rate is now rated against the requests the
application actually received, so `success + errors + infra_blocks == total_requests`.

**Mixed create/update/delete workflows may start passing.** Correlation threads each VU's own
server-generated IDs, so requests that previously failed ownership checks with 404/403 now
succeed. If you had been treating those failures as a known-bad baseline, that baseline moves.

**Multiprocess runs may behave differently from before — correctly.** `_worker_fn` was building
its worker config from a hand-written field list, so fourteen settings silently defaulted inside
worker processes. Since `--workers` defaults to CPU count, that affected almost every run.
Flags you set that appeared to do nothing now take effect.

### API changes for embedders

Only relevant if you import the package rather than using the CLI.

- `AuthProvider.authenticate_all()` returns an `AuthOutcome` (`.tokens`, `.failures`,
  `.active_accounts`, `.total_accounts`) instead of a bare `dict[int, str]`.
- `parse_assert_json()` returns `(path, value, endpoint)` triples instead of `(path, value)`
  pairs; `endpoint` is `""` for the global form.
- `run_all_protocols()` moved from `headless.jac` to `core/protocols.jac`. `headless.jac`
  re-exports it, so existing imports keep working.
- `RequestResult` gained `correlation_applied` and `body_hash`; `EndpointStats` gained
  `infra_block_count`; `StatsSnapshot` gained `latency_buckets`. All additive.
- The JSON report gained `infra_block_count` (per endpoint and in `summary`),
  `parameterized_fields` and `skip_failed_accounts`. All additive.

`run_test_headless()` and `LoadTestConfig.from_dict()` are unchanged.

### Toolchain

The jac toolchain is pinned to **0.34.17** (`jac-version` in `jac.toml`, `JAC_VERSION` in both
workflows). 0.6.0 will not build on 0.31.x: lambda parameter syntax changed between them, and
the older form is a parse error rather than a warning.

### Getting the old behaviour back

```bash
jac x loadtest recording.har --url ... \
  --no-auto-correlate --no-body-check --infra-block-threshold 1 --no-auto-register
```

Worth doing once, to confirm a difference is this release rather than your service — then drop
the flags, because the new numbers are the accurate ones.
