# jac-loadtest Architecture

How `jac-loadtest` works end to end in **monolith mode**, from the shell command to the report.
It is read section by section: each section follows one stage of a run and explains the modules,
functions, constants and data structures involved, and the flags that act at that stage.

> Status: sections 1–10 are written. Microservice mode is not covered, except where a step differs.

## The run at a glance

```
jac x loadtest rec.har --url http://host --vus 50 --iterations 10
  │
  ① plugin.main() ─ argparse ─▶ cli.run(args)
  │     config.from_args(): CLI flag → jac.toml → built-in default  ⇒ LoadTestConfig
  │     fail-fast validation  ⇒ exit 2 on a bad command
  │
  ② har_parser.parse_har(): filter, sanitize, rewrite origin to --url, tag protocol  ⇒ [HarEntry]
  │
  ③ AuthProvider, correlation rules, --param rules; --slo / --assert-json / --poll-until parsed
  │
  ④ single process (run_all_protocols) or --workers N (run_multiprocess)
  │     account pool authenticated once ─▶ one token per VU
  │
  ⑤ each VU replays the entries in order (closed loop, --open-loop or --step-load)
  │     per request: correlation → params → token → send → status/assert/body checks
  │                  → RequestResult → MetricsCollector
  │     WebSocket / GraphQL entries run alongside through their own adapters
  │
  ⑥ after the run: classify infra blocks → per-endpoint stats → time series
  │
  ⑦ render console / JSON / HTML  →  evaluate --fail-on-* thresholds  →  exit 0 or 1
```

| # | Section | Status |
|---|---|---|
| 1 | [Entry point and configuration](#1-entry-point-and-configuration) | written |
| 2 | [Loading the HAR](#2-loading-the-har) | written |
| 3 | [Identity and auth](#3-identity-and-auth) | written |
| 4 | [Correlation and test data](#4-correlation-and-test-data) | written |
| 5 | [Run orchestration](#5-run-orchestration) | written |
| 6 | [The VU loop and load shapes](#6-the-vu-loop-and-load-shapes) | written |
| 7 | [Sending a request and judging it](#7-sending-a-request-and-judging-it) | written |
| 8 | [WebSocket and GraphQL](#8-websocket-and-graphql) | written |
| 9 | [Metrics and post-run analysis](#9-metrics-and-post-run-analysis) | written |
| 10 | [Reports, thresholds and exit codes](#10-reports-thresholds-and-exit-codes) | written |

## Package layout

```
jac_loadtest_cli/
├── plugin.jac          argparse entry point (the `loadtest` console script)
├── cli.jac             run(): orchestration, report selection, threshold gate, exit codes
├── headless.jac        run_test_headless(): the same pipeline with no CLI, for embedders
├── config.jac          LoadTestConfig and the three-layer resolution
├── core/               engine pieces with no jac-scale knowledge
│   ├── har_parser.jac · engine.jac · correlation.jac · parameterize.jac · infra_block.jac
│   ├── ws_engine.jac · graphql_engine.jac · protocols.jac · process_runner.jac · metrics.jac
├── bridge/             jac-scale-aware adapters: auth.jac, body_check.jac, topology.jac
├── output/reporter.jac console, JSON and HTML reports
└── templates/          self-contained HTML report
```

`core/har_parser`, `metrics`, `correlation`, `parameterize`, `infra_block`, `ws_engine` and
`graphql_engine` never import `bridge/`. `engine`, `protocols` and `process_runner` call into
`bridge/` for auth and the body check. `bridge/` is the only place jac-scale's contracts are
encoded.

---

# 1. Entry point and configuration

**Goal of this stage:** turn a shell command into one validated `LoadTestConfig`, or exit with code
`2` before any traffic is sent.

**Files:** `plugin.jac`, `config.jac`, and the first ~100 lines of `cli.run()` in `cli.jac`.

## 1.1 From the shell to Python

`jac.toml` declares the command:

```toml
[entrypoints.scripts]
loadtest = "jac_loadtest_cli.plugin:main"
```

`jac install` turns that into a normal console script, and `jac x loadtest …` looks installed
console scripts up by name and runs them under the Jac runtime. (Jac has no third-party
`jac <name>` subcommand system; `jac x` is the supported route.)

`plugin.main()` does three things:

```
parser = build_parser()
args   = parser.parse_args(sys.argv[1:])     # an argparse.Namespace
run(args)                                    # cli.jac
```

`plugin.jac` is the only module that touches `argparse` and `sys.argv`. `run()` is the real
entry point for everything after.

## 1.2 The argument parser (`plugin.build_parser`)

`build_parser()` registers 55 arguments: one positional (`har_file`) and the rest long-form flags
(no short options). Four conventions matter because the config layer relies on them:

| Convention | Why |
|---|---|
| Every value flag uses `default=None` | The config layer must tell "the user did not pass this" (`None`) from "the user passed a value". Built-in defaults therefore live only in `config.jac`, never in argparse. |
| Boolean flags are `store_true` with `default=None` | Same reason: an absent flag stays `None` and can fall through to `jac.toml`. |
| Negations are `store_false` flags writing to a positive `dest` | `--no-body-check` sets `body_check=False`, `--no-auto-correlate` sets `auto_correlate=False`, `--no-auto-register` sets `auto_register=False`. |
| Repeatable flags use `action="append"` | `--assert-json`, `--correlate`, `--param`, `--poll-until`, `--poll-error-until`, `--fail-on-p95`, `--fail-on-p99` arrive as `list[str]`. The latency flags use dests `fail_on_p95_values` / `fail_on_p99_values`. |

Numeric flags use the tiny wrappers `_int` and `_float` rather than the `int` / `float` builtins,
because the Jac type checker requires `type=` to be a `Callable[[str], Any]`. Durations
(`--duration`, `--ramp-up`, `--timeout`, …) are kept as strings here and parsed later.

## 1.3 `LoadTestConfig` — the single source of truth

`config.jac` defines `obj LoadTestConfig`, a plain data object. Everything after this stage reads
settings from it and never touches `args` again. Its fields, grouped by what they control:

| Group | Fields |
|---|---|
| Target | `har_file`, `url`, `mode` (`monolith`), `include_static`, `login_path` |
| Load shape | `vus`, `iterations` (`int \| None`), `duration`, `ramp_up`, `workers`, `rps`, `open_loop`, `step_load`, `step_vus`, `step_duration`, `step_max_vus`, `think_time`, `think_time_scale`, `timeout` |
| Identity | `username`, `password`, `accounts`, `register_path`, `auto_register`, `skip_failed_accounts`, `auth_delay`, `auth_batch_size`, `auth_batch_delay`, `csrf` |
| Data | `correlate`, `auto_correlate`, `param` |
| Checks | `assert_json`, `body_check`, `check_shape`, `fail_on_shape_drift`, `poll_until`, `poll_error_until`, `poll_timeout`, `poll_interval`, `infra_block_threshold`, `proxy_pool`, `health_check` |
| Gates | `fail_on_error_rate`, `fail_on_p95`, `fail_on_p99`, `fail_on_p95_scoped`, `fail_on_p99_scoped`, `abort_on_fail`, `threshold_start_delay` |
| Output | `report_format`, `report_out`, `slo_map`, `max_samples`, `apdex_t`, `debug` |
| Protocol blocks | `ws_scenarios`, `graphql_scenarios` (only used by embedders; see 1.7) |

Two fields have non-obvious types. `iterations` can be `None`, meaning "no replay-count limit; a
time limit stops the run" (see 1.4). `accounts` is `object | None` because the CLI passes a string
(inline JSON or a file path) while an embedder may pass an already-parsed dict or list.

## 1.4 Resolution: CLI flag → `jac.toml` → built-in default

`config.from_args(args)` builds the config. Each setting is resolved by a small family of helpers
that all start from `_resolve(name, args, toml)`:

```
cli_val = getattr(args, name, None)
if cli_val is not None                      → use the CLI value        (wins)
elif name in toml and toml[name] is not None → use the jac.toml value
else                                         → BUILT_IN_DEFAULTS.get(name)
```

The typed wrappers narrow the result: `_resolve_str`, `_resolve_int`, `_resolve_float` (an int
becomes a float, so `rps = 2` in `jac.toml` works), `_resolve_bool`, `_resolve_opt_str` and
`_resolve_opt_float` (return `None` when unset).

Example: `--vus 50` → `args.vus == 50` → `_resolve_int("vus", …)` → `config.vus == 50`. With no flag
and `vus = 20` under `[plugins.scale.loadtest]` → `20`. With neither → the built-in `1`.

**Built-in defaults** (`BUILT_IN_DEFAULTS`) include: `vus=1`, `iterations=1`, `ramp_up="0s"`,
`timeout="30s"`, `workers=os.cpu_count()`, `think_time="none"`, `rps=0` (unlimited),
`report_format="console"`, `max_samples=1_000_000`, `body_check=True`, `auto_correlate=True`,
`auto_register=True`, `infra_block_threshold=3`, `apdex_t=500.0`, `poll_timeout="60s"`,
`login_path="/user/login"`, `register_path="/user/register"`.

**Special cases** that do not go through plain `_resolve`:

| Setting | Rule |
|---|---|
| `iterations` | `_resolve_iterations`: a CLI or toml integer wins; otherwise, if `--duration` is set (CLI or toml), `iterations` is `None` so VUs loop until the duration ends; otherwise the default `1`. |
| `--fail-on-p95` / `--fail-on-p99` | `_parse_fail_on_latency` reads the repeated values. A bare number (`500`) is the global threshold; `ENDPOINT:MS` (`/healthz/live:100`) is scoped to one endpoint and goes into `fail_on_p95_scoped` / `fail_on_p99_scoped`. More than one bare value, or a non-number, raises `ValueError`. If no bare CLI value is given, the toml value is the global one. Scoped values are CLI-only. |
| CLI-only fields | Read straight from `args` with `_getattr_*`, never from `jac.toml`: `har_file`, `url`, `username`, `password`, `services_map`, `slo` (→ `slo_map`), `assert_json`, `report_out`, `correlate`, `param`, `poll_until`, `poll_error_until`. They change per run or are sensitive. |

## 1.5 Reading `jac.toml`

`_load_toml_defaults()` reads the `[plugins.scale.loadtest]` section through jac-scale's own config
loader:

```
reset_scale_config()                                   # always re-read from the current directory
get_scale_config(project_dir=Path.cwd()).get_section("loadtest")
```

`reset_scale_config()` is called first so a previously initialised config singleton pointing at
another directory cannot leak in. Any exception (no `jac.toml`, no section, loader unavailable)
returns `{}`, so the tool works in any directory with no configuration file.

## 1.6 `parse_duration`

`parse_duration(s)` converts `"30s"`, `"5m"`, `"2h"` (or a bare number, taken as seconds) to
seconds as a float. `ms` is not supported. It raises `ValueError` on bad input. It is called where
a duration is used (`ramp_up`, `timeout`, `duration`, `step_duration`, `threshold_start_delay`,
`poll_timeout`, `poll_interval`), not when the config is built, so a bad value fails at that point;
the poll durations are also pre-checked in `run()` (1.7).

## 1.7 Fail-fast validation in `cli.run()`

Before any HAR parsing, `run()` rejects an inconsistent command with a message on stderr and **exit
code 2** (tool or config error). In order:

1. `from_args` raises `ValueError` (bad `--fail-on-p95/p99`) → exit 2.
2. Monolith mode without `--url`.
3. `--health-check` without `--url`, or a path that does not start with `/`.
4. No `har_file`.
5. `--open-loop` without a positive `--rps` (open loop needs a fixed arrival rate).
6. `--step-load` problems: combined with `--open-loop`; with `--workers > 1`; without a positive
   `--step-vus`; or with neither `--step-max-vus` nor a `--fail-on-*` threshold (the ramp would have
   no stopping condition).

After the HAR is parsed (section 2) and the rules are built (sections 3–4), `run()` also validates
`--slo` (`parse_slo_map`), `--assert-json` (`parse_assert_json`), `--poll-until` /
`--poll-error-until` (`parse_poll_rules`) and the poll durations. These are parsed once here only to
fail before the run starts; the engine parses them again where it uses them.

Exit codes across the tool: `0` all thresholds passed (or none set), `1` a threshold failed, `2` a
tool or config error.

## 1.8 The embedder path: `LoadTestConfig.from_dict`

`headless.run_test_headless()` does not use argparse or `jac.toml`. It calls
`LoadTestConfig.from_dict(d)`, which merges `BUILT_IN_DEFAULTS` and `_NON_BUILT_IN_DEFAULTS` (the
fields with no built-in default, such as `har_file`, `url`, `accounts`, `ws_scenarios`), overlays the
keys present in `d`, ignores unknown keys, and treats an explicit `None` as "use the default".
Because of this, an embedder can pass a whole JSON request body straight through.

## 1.9 Flags acting at this stage

All flags follow the path above. These are the ones whose effect is just a stored setting at this
point, with where they act later:

| Flag | Default | Stored as | Takes effect in |
|---|---|---|---|
| `har_file` (positional) | required | `har_file` | section 2 |
| `--url` | required | `url` | section 2 (origin rewrite) and 6–7 (health check, requests) |
| `--vus` | `1` | `vus` | sections 5–6 |
| `--iterations` | `1` (`None` with `--duration`) | `iterations` | section 6 |
| `--duration` | — | `duration` | section 5 (duration watcher) |
| `--ramp-up` | `0s` | `ramp_up` | section 5–6 (VU start delay) |
| `--workers` | CPU count | `workers` | section 5 |
| `--timeout` | `30s` | `timeout` | section 7 (per-request timeout) |
| `--max-samples` | `1000000` | `max_samples` | section 9 (sample buffer) |
| `--debug` | off | `debug` | section 7 (per-request stderr line) |
| `--mode` | `monolith` | `mode` | section 2 and 5 (this document assumes monolith) |

Every other flag is stored the same way and explained in the section where it takes effect.

---

# 2. Loading the HAR

**Goal of this stage:** turn the HAR file into an ordered list of `HarEntry` objects, each one a
request (or WebSocket connection) ready to replay against `--url`, with the recording's auth
headers removed and the recording's timing and repetition recorded as metadata.

**File:** `core/har_parser.jac`. It imports nothing from the rest of the package.

**Called from:** `cli.run()` (`parse_har(config.har_file, target_url=config.url, include_static=..., login_path=...)`)
and from `headless.run_test_headless()` with the same arguments. In monolith mode `target_url` is
`config.url`; in microservice mode it is `None` and URLs are left as recorded.

## 2.1 The two entry functions

| Function | Input | Does |
|---|---|---|
| `parse_har(har_path, target_url, include_static, login_path)` | path to a `.har` file | opens and `json.load`s it, requires a top-level `log` key (else `ValueError("Malformed HAR file…")`), warns if `log.version` is not `1.1`/`1.2` (`_check_version`, `_SUPPORTED_HAR_VERSIONS`), then hands `log.entries` on |
| `parse_har_entries(raw_entries, …)` | entries already in memory | the real parser; split out so a caller that holds entries need not write a file just to reach it (tests use it) |

An unreadable or malformed file raises `FileNotFoundError` / `OSError` / `ValueError`; `cli.run()`
catches them, prints `Error: …` and exits `2`. If every entry is filtered out, `cli.run()` also
exits `2` with "no API entries found after filtering" (a hint to try `--include-static`).

## 2.2 `HarEntry` — what one recorded request becomes

```
obj HarEntry
  request      method, url (rewritten), headers (sanitized), body, body_mime
  as recorded  original_url, expected_status (recorded response status, default 200)
  login        is_login            path == --login-path
  timing       think_time_ms       client-side gap to the next kept entry
  repetition   occurrence, total_occurrences          call #N of M of this path in the whole HAR
               consecutive_run_size, consecutive_run_index   position inside an adjacent same-path run
  protocol     protocol            "http" | "graphql" | "ws" | "graphql_ws"
  websocket    ws_messages         ordered "send" frames
  graphql      graphql_query, graphql_variables, graphql_operation_name
  correlation  recorded_response   response body, truncated to 64 000 chars (_MAX_RECORDED_RESPONSE)
               correlate_annotations   rules from the entry's x-jac-correlate field
```

`recorded_response` and `correlate_annotations` are inputs to section 4 and are never sent
anywhere. `expected_status` is what the engine compares against in section 7.

## 2.3 The per-entry pipeline

For each raw HAR entry the loop in `parse_har_entries` applies these steps in order. The first
step that matches decides the entry's fate.

| # | Check | Result |
|---|---|---|
| 1 | `_is_unsupported_type`: `_resourceType` in `_SKIP_RESOURCE_TYPES` (`eventsource`, `document`, `manifest`, `texttrack`, `media`, `font`) | skipped, one warning per run |
| 2 | `_is_websocket_entry`: `_resourceType == "websocket"` or URL starts `ws://` / `wss://` | WebSocket branch (2.5), then next entry |
| 3 | `_has_cache_buster(url)`: a query param named `_`, `cb`, `cachebust`, `cache_bust`, `nocache` or `bust` whose value is 10–13 digits (`_CACHE_BUSTER_PARAMS`, `_TIMESTAMP_RE`) | skipped, one warning (the stale timestamp makes servers reject the request) |
| 4 | `_is_static(mime)`: response MIME starts with `image/`, `font/`, `text/css`, `application/javascript`, `text/javascript`, `application/wasm` (`_SKIP_MIME_PREFIXES`) and `include_static` is false | skipped silently |
| 5 | `_has_missing_body`: method is POST/PUT/PATCH, `Content-Length` > 0, but `postData.text` is empty | skipped, one warning (replaying it bodyless would 422) |
| 6 | otherwise | kept as an HTTP entry (2.4) |

Each warning is printed at most once per run (`warned_unsupported`, `warned_cache_buster`,
`warned_missing_body`, `warned_ws_no_frames`) to stderr in yellow.

## 2.4 Building an HTTP entry

1. **URL rewrite** (`_rewrite_url`): keep the recorded path, params and query; replace scheme and
   host with those of `--url`. This is how a HAR recorded against one host replays against another.
   With no `target_url` the recorded URL is kept.
2. **Header sanitising** (`_sanitize_headers`): drops every header named in `_STRIP_HEADERS`
   (`authorization`, `cookie`, `host`, `content-length`) and every HTTP/2 pseudo-header starting
   with `:`. Authentication is never replayed from the recording; section 3 supplies a fresh token
   per VU. `_security_scan` runs once over the raw entries first and prints a warning if the file
   contains `Authorization` or `Cookie` values, since the file itself is sensitive.
3. **Body**: `postData.text` and `postData.mimeType` become `body` and `body_mime`.
4. **Login tag**: `is_login = (url path == login_path)`, where `login_path` is `--login-path`
   (default `/user/login`). At replay time the engine skips an `is_login` entry for a VU that
   already holds a token (section 6).
5. **GraphQL over HTTP** (`_detect_graphql_http`): if the body is JSON with a top-level `query`
   string that contains `{`, the entry is tagged `protocol="graphql"` and the query, `variables`
   and `operationName` are copied out. It is detected from the body, not the path, because
   deployments use `/graphql`, `/api/graphql` and so on. The `{` check keeps a search endpoint's
   `{"query": "text"}` from being misread. A `graphql` entry still replays through the HTTP
   engine; the tag only lets the report group it separately.
6. **Capture for correlation**: `_recorded_response_text` keeps the response text unless it is
   base64 (binary), truncated; `_correlate_annotations` reads `x-jac-correlate` (or
   `_jac_correlate`) as a string or list of strings.

## 2.5 Building a WebSocket entry

- **URL**: `_rewrite_ws_url` swaps host like `_rewrite_url` and maps the target scheme `http`→`ws`,
  `https`→`wss`; if `--url` is already `ws`/`wss` the recorded scheme is kept.
- **Frames**: `_extract_ws_send_messages` reads the non-standard `_webSocketMessages` array
  (Chrome "Preserve log" and Playwright's recorder write it; a plain Chrome HAR export does not)
  and keeps only frames of type `send`. `receive` frames are the original server's replies and are
  not replayed or compared.
- **Protocol**: `_detect_graphql_ws` looks through the sent frames for a `start` or `subscribe`
  message whose payload has a `query` containing `{`. If found the entry is `graphql_ws` with the
  query, variables and operation name; otherwise it is `ws`.
- **No frames**: the entry is still kept and replays as a bare connect; a warning says to re-record
  with a tool that preserves frames.
- Headers are sanitised the same way; `body` is `None`; `expected_status` is `101` by default;
  `think_time_ms` is `0` initially.

## 2.6 Post-pass: timing and repetition metadata

After the loop, three passes over the kept entries (in recorded order) fill in the metadata. None
of them removes entries.

1. **Think time.** `_parse_started_ms` converts `startedDateTime` to epoch ms. For entry *i*,
   `think_time_ms = max(0, started[i+1] − (started[i] + time[i]))`, the client-side gap between one
   call finishing and the next starting. This is deliberately not `timings.wait` (server time for
   that call). The last entry, and any entry with an unparseable timestamp, keeps `0`. Used by
   `--think-time real|scaled` in section 6.
2. **Occurrence counters.** Count how many times each URL path appears in the whole list, then set
   `total_occurrences` and a running `occurrence`. The report uses them to label repeated calls
   `call #2 of 3` so they are not merged into one row.
3. **Adjacent runs.** A single scan finds each maximal run of consecutive entries with the same
   path and the same protocol and sets `consecutive_run_size` and `consecutive_run_index`
   (`1/1` when there is no adjacent repeat). Unlike `occurrence`, this ignores unrelated reuse of
   the same path elsewhere in the flow. The engine only treats a run longer than 1 as a poll block
   when a `--poll-until` rule names its endpoint (section 6), so replay is unchanged by default.

## 2.7 Handing the list on

Back in `cli.run()` the single list is split by protocol:

- `entries` = entries with `protocol` in `http` / `graphql` → the HTTP engine (sections 5–7).
- `scenarios_from_har_entries(...)` in `ws_engine.jac` and in `graphql_engine.jac` turn the `ws`
  and `graphql_ws` entries into scenario configs → section 8.
- The full `all_entries` list also feeds correlation rule detection (section 4), because a value
  can be produced by one protocol and consumed by another.

## 2.8 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `har_file` | required | file parsed by `parse_har` |
| `--url` | required (monolith) | scheme and host that replace the recorded origin of every HTTP and WebSocket entry |
| `--include-static` | off | disables step 4 of the pipeline, so image, font, CSS and JS responses are replayed |
| `--login-path` | `/user/login` | path whose entry is tagged `is_login` |
| `--mode` | `monolith` | `microservice` passes `target_url=None`, so recorded URLs are routed by section 5's topology instead |
| `--think-time`, `--think-time-scale` | `none`, `1.0` | use `think_time_ms` computed here (applied in section 6) |
| `--poll-until`, `--poll-error-until` | — | use `consecutive_run_*` computed here (applied in section 6) |
| `--correlate`, `x-jac-correlate` in the HAR | — | read from `correlate_annotations` and `recorded_response` (section 4) |

---

# 3. Identity and auth

**Goal of this stage:** give every virtual user (VU) its own account and a valid bearer token
before any measured traffic is sent, and keep that token valid during the run.

**File:** `bridge/auth.jac` (jac-scale's login and register contracts live here and nowhere else).
Callers: `cli.run()` builds the provider; `engine.run_load_test` (single process) or
`process_runner._pre_authenticate_all` (`--workers > 1`) runs the pre-run burst; `engine._send_request`
attaches tokens and re-authenticates on a 401.

**Why it exists:** on jac-scale every request runs against the authenticated user's own root graph,
so N VUs sharing one token measure single-user contention, not a multi-user mix. Each VU therefore
gets its own identity.

## 3.1 Data structures

| Name | Fields | Purpose |
|---|---|---|
| `Credential` | `username`, `password`, `extra: dict[str,str]` | one account. `extra` holds any further CSV/JSON columns and feeds `{{account.<col>}}` (section 4), so a VU's body data matches the account it logged in as |
| `AuthOutcome` | `tokens` (vu_id → token), `failures` [(username, reason)], `active_accounts`, `total_accounts`, `failed_count()` | result of the pre-run burst |
| `AuthProvider` | `_accounts`, `_login_path`, `_register_path`, `_auto_register`, pacing fields, `_refresh_locks`, `_token_generation`, `_active_indices` | the pool and everything that talks to the login and register endpoints |
| `AuthenticationError` | exception | raised for any unrecoverable auth failure; `cli.run()` prints `Error: …` and exits `2` |

## 3.2 Building the provider: `AuthProvider.from_config`

Called once in `cli.run()` when there are HTTP entries. It returns `None`, meaning "no auth, send
requests as recorded minus the stripped headers", when no credentials are configured.

1. `parse_accounts(config.accounts)`. If that gives nothing and both `--username` and `--password`
   are set, a one-entry pool is built from them. `--accounts` wins over `--username`.
2. Pacing flags are cross-checked: `--auth-batch-size` without `--auth-batch-delay` (or the reverse)
   raises `ValueError`, which `cli.run()` turns into exit `2`.
3. The provider copies `login_path`, `register_path`, `auto_register` and the three pacing values
   from the config.

### Account sources: `parse_accounts`

Accepted forms, tried in this order, all producing an ordered `list[Credential]` (order matters
because VU-to-account assignment is positional, so a run must be reproducible):

| Form | Example |
|---|---|
| already-parsed dict or list (embedder path) | `{"alice": "pw"}` |
| inline JSON object | `'{"alice":"pw1","bob":"pw2"}'` |
| inline JSON array | `'[{"username":"alice","password":"pw1","region":"eu"}]'` |
| path to a `.json` file | either of the two shapes above |
| path to a `.csv` file | header row must include `username` and `password`; other columns become `extra` |

`_credentials_from_list` also accepts the key aliases `user`/`email` and `pass`, and bare
`[user, password]` pairs. `_credentials_from_csv` skips rows missing either field and raises if the
file is empty or has no rows. A string that is neither JSON nor an existing file raises `ValueError`.

## 3.3 The pre-run authentication burst: `authenticate_all`

Runs once, **before the replay loop and outside the measured window**, so login latency never
appears in results and the auth endpoint sees one burst, not traffic spread through the run.

1. **One login per distinct account, not per VU.** With 500 VUs over 10 accounts that is 10
   logins. A warning is printed once if there are more VUs than accounts (accounts are then reused
   round-robin and VUs sharing an account share a root graph).
2. For each account in order, `_acquire` obtains a token (3.4). The token is stored in
   `token_by_account` and seeded into `_token_generation` (3.6).
3. Failures: if `--skip-failed-accounts` is off, the first failure re-raises `AuthenticationError`
   and the run exits `2`. If it is on (`tolerate_failures=True`), the failure is recorded in
   `failures` and the burst continues.
4. If **no** account authenticated, it raises even in tolerant mode. That is a misconfiguration
   (wrong `--url`, wrong `--login-path`, server down), not a bad row, and continuing would measure
   only 401s.
5. `_active_indices` is set to the accounts that survived, and every requested VU id is re-spread
   over them (`vu_id % len(active)`). Concurrency stays as requested; only identity diversity
   drops. `credential_for(vu_id)` uses the same active list, so a VU's token and its
   `{{account.<col>}}` data never drift apart.
6. `_pace_auth_burst` runs after each account (skipped after the last): `--auth-batch-size` +
   `--auth-batch-delay` sleeps on a batch boundary and, there, replaces `--auth-delay`; otherwise
   `--auth-delay` sleeps between accounts. A failed attempt still counts, since it cost the target a
   request.
7. The result is an `AuthOutcome`. `_report_auth_failures` (in `engine.jac`) prints a yellow
   warning listing each failed account and reason, so a thinner-than-requested identity pool is
   never silent.

**Where it runs:** with `--workers 1`, `run_load_test` calls it inside its own `aiohttp` session.
With `--workers > 1`, the controller process calls it through `_pre_authenticate_all` before
forking, then gives each worker only its own `{vu_id: token}` slice, so raising `--workers` does not
multiply login traffic. Workers receive these as `pre_authed_tokens`.

## 3.4 Getting one token: `_acquire`, `_login`, `_register`

```
_login ──token──────────────────────────────▶ done
   │ 401 and auto_register on
   ▼
_register ── "exists"  ─▶ AuthenticationError: wrong password, fix --accounts
          ── "created" ─▶ _login again ─▶ token, or error
          ── other     ─▶ AuthenticationError: register also failed
```

- `_login` POSTs `{"identity": {"type": "email"|"username", "value": …}, "credential": {"type":
  "password", "password": …}}` to `base_url + login_path`. `_identity_type` picks `email` when the
  username contains `@`. A `200`/`201` response is searched for a token by `_token_from`
  (`data.token`, `data.access_token`, then top-level `token`/`access_token`). It returns
  `(token, status, detail)`.
- **Why register on a 401:** jac-scale returns the same `401 Invalid credentials` for a missing
  account and a wrong password. The register endpoint can tell them apart. `_register` POSTs
  `{"identities": [{"type": "username", …}], "credential": {…}}` to `register_path`. A `200`/`201`
  means the account did not exist and now does; a `USER_EXISTS` code, or "already exists" in the
  message, means it existed, so the 401 was a genuine wrong password. This never masks a bad
  credential and never registers over an existing account.
- Any non-401 login failure, or a 401 with `--no-auto-register`, raises at once with the server's
  message (`_message_from` reads `message`, `error`, `detail`, else `server returned <status>`).
- A connection error raises `AuthenticationError("Cannot reach login endpoint …")`.
- `_read_json` parses the body regardless of content type, falling back to the first 300 chars of
  text.

## 3.5 Using the token on every request

In `engine._send_request`, per request: the entry's sanitised headers (section 2) are copied, then
`Authorization: Bearer <token_by_vu[vu_id]>` is set when this VU has a token. Nothing from the
recording's `Authorization` or `Cookie` is ever sent. With `--csrf`, the engine also reads a
`csrftoken` or `_csrf` cookie from any response, stores it per VU, and sends it as `X-CSRFToken` on
later non-GET requests.

The recorded login call itself (`HarEntry.is_login`) is **skipped** during replay for a VU that
already holds a token, since the pre-run burst did that login and replaying it would add auth
traffic the run is not measuring.

WebSocket and GraphQL-over-WebSocket scenarios (section 8) do not read these tokens.

## 3.6 Mid-run re-authentication: `refresh_for`

If a response is `401` and the recording did not expect a 401 (`expected_status != 401`, so a HAR
that deliberately tests an auth failure keeps its 401), the engine calls `refresh_for` once and
replays the request once (`_reauth_attempted` guards against loops).

The hazard is a JWT expiring at one wall-clock time, which makes every VU holding it 401 within the
same second. `refresh_for` collapses that to one login per account:

- one `asyncio.Lock` per account index, created lazily (a lock binds to the running event loop, and
  this object is built before the loop exists and is pickled to workers);
- `_token_generation[index]` holds the current token for the account. A VU queued behind the lock
  compares the token it held (`stale_token`) with the current one; if another VU already refreshed,
  it returns that token without logging in again.

Outcomes: a successful refresh updates `token_by_vu[vu_id]` and the replayed request's result is
recorded normally. If re-login raises, the request is recorded as status `401` with error type
`AUTH_EXPIRED: re-authentication failed (…)`. If the replay is still `401`, it is recorded as
`AUTH_EXPIRED: still 401 after re-authentication`, a separate bucket from generic 4xx so an expiring
token is not mistaken for the application rejecting requests.

Known limitation: `refresh_for` picks the account as `vu_id % len(all accounts)`, while the burst
uses the surviving accounts. After `--skip-failed-accounts` drops an account, a VU can therefore
refresh against a different account than the one it started with.

## 3.7 VUs added after the burst (step load)

Only the initial `--vus` are authenticated. With `--step-load` (section 6), a VU created later has
no token; `_ensure_token` copies one from an existing VU, cycling in account order, so a ramp keeps
spreading over identities instead of piling onto one.

## 3.8 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--accounts MAP_OR_FILE` | none | per-VU account pool (3.2). Without it and without `--username`, no auth is used |
| `--username`, `--password` | none | single shared credential; superseded by `--accounts` |
| `--login-path` | `/user/login` | login endpoint for the burst and refresh, and the path tagged `is_login` in section 2 |
| `--register-path` | `/user/register` | endpoint used to create a missing account |
| `--no-auto-register` | register on | a 401 login fails instead of registering (3.4) |
| `--skip-failed-accounts` | off | continue on the accounts that authenticated and re-spread VUs (3.3) |
| `--auth-delay SECONDS` | 0 | sleep after each account in the burst |
| `--auth-batch-size N` + `--auth-batch-delay S` | off | pause `S` seconds after every `N` accounts; must be given together |
| `--csrf` | off | per-VU `X-CSRFToken` from a `csrftoken`/`_csrf` response cookie (3.5) |

In microservice mode, authentication also requires `--url` (the gateway), checked in `cli.run()`.

---

# 4. Correlation and test data

**Goal of this stage:** make each VU send its *own* server-generated ids and *varied* data instead of
the one recorded user's values, so create → update → delete flows work and reads do not hit a
warm cache.

**Files:** `core/correlation.jac` (rules, per-VU table, substitution) and `core/parameterize.jac`
(`--param` files and `{{token}}` substitution). Both are generic and know nothing about jac-scale.
Rules are built once in `cli.run()` (before the run) and applied per request inside
`engine._send_request` (section 7).

## 4.1 The problem

A HAR holds one user's session. A request that works on an existing object carries an id that the
server generated at recording time, so replayed as-is it targets the recording user's row. Rotating
accounts does not help: the id is in the body or URL, not the token. Correlation captures the id
each VU actually received and substitutes it into the later request.

## 4.2 `CorrelationRule`

| Field | Meaning |
|---|---|
| `producer` | endpoint whose response holds the value (`/walker/AddTodo` or just `AddTodo`) |
| `source_path` | dotted path into the producer's JSON response (`reports.0.id`), or `header.<name>` |
| `consumer` | endpoint that sends the value later |
| `target_path` | where in the consumer request (`body.nd`, `query.id`, `path`); empty for literal rules |
| `recorded_value` | the literal the recording used. Set on detected rules and on explicit rules after hydration |
| `name` / `label()` | key into the per-VU table and the entry in `RequestResult.correlation_applied` |

`endpoint_matches(rule_side, endpoint)` matches the full path or the last path segment only (so
`AddTodo` matches `/walker/AddTodo`). It has no notion of an action inside a body. `--poll-until`
and `--assert-json` reuse it.

## 4.3 Where rules come from: `build_rules`

One function decides the run's correlation (called by `cli.run()` and `headless.run_test_headless()`
so they cannot drift). Precedence:

1. `--correlate` flags (`parse_correlate_rules`): `Producer.response.a.b -> Consumer.body.c`.
   `--correlate` is repeatable; `response.` prefix optional; target path optional.
2. `x-jac-correlate` annotations in the HAR (`rules_from_har_annotations`), same syntax, so a team can
   commit the annotated HAR instead of repeating flags.
3. Auto-detected rules (`detect_correlations`), unless `--no-auto-correlate`. A detected rule is
   dropped when an explicit rule already covers the same producer/consumer pair.

**Hydration** (`hydrate_explicit_rule`): an explicit rule has no recorded literal, so the HAR is read
for the values recorded at `source_path` across the producer's occurrences. If the first value looks
like an id, it becomes `recorded_value`, which gives the rule the same substring replacement and
conditional miss check as a detected one. If the producer recorded several distinct values only the
first is threaded (a warning is printed). If nothing resolves and there is no target path, the run
fails fast (exit 2).

**Detection** (`detect_correlations`) reads only the HAR, with no baseline run:

1. For every HTTP/GraphQL entry's `recorded_response`, `flatten_json` turns it into
   `(dotted-path, scalar)` pairs and keeps those `is_id_like` accepts: strings of 8–512 chars made of
   `[A-Za-z0-9_:.-+/=]`, no spaces, not in `_STOPWORDS`, containing a digit or `-_:`; or integers
   ≥ 10 000. Booleans, small numbers and plain words are rejected on purpose, since a false
   correlation silently sends wrong data while a missed one shows up as a visible 404.
2. A value produced by more than one response is skipped (ambiguous producer).
3. For each remaining value, search the request body and URL of every *later* HTTP/GraphQL entry. A
   hit means the browser copied that value forward, and a rule is created, deduplicated by
   (producer, path, consumer, value).

`cli.run()` prints the detected and hydrated rules to stderr at start-up.

## 4.4 Per-VU runtime: `CorrelationTable`

`engine._run_iteration` creates one `CorrelationTable` per VU **per iteration**, so VU 3 threads VU 3's
ids and iteration 2 acts on the object iteration 2 created. It is never shared.

- `capture(rules, endpoint, body, headers)` runs after every response: for each rule whose producer
  matches, it reads `source_path` from the flattened JSON body (or the named header) into
  `values[rule.label()]`.
- `apply_correlations(rules, table, endpoint, url, body)` runs before sending. For rules whose
  consumer matches:
  - **Literal rule** (has `recorded_value`): replace that exact string in the body and URL with the
    captured value, wherever it appears.
  - **Path rule**: `query.<name>` sets a query parameter; `body.<json.path>` sets a JSON field
    (`_set_json_path`, which never creates a missing field); `path` replaces the last URL segment.
  - **Miss**: no captured value for a rule that should fire. The request is **not sent**; it is
    recorded as `CORRELATION_MISS: <rule>` (status 0, `latency_valid=False`), so the real cause shows
    up instead of a puzzling 404 from a stale id. A literal rule that never appears in this request
    is not a miss.
  Returns a `CorrelationOutcome(url, body, applied, missing)`.

Known gap: a rule whose producer never ran or never captured is reported only as per-request
`CORRELATION_MISS` samples, not as a run-level finding (#36); `--correlate` paths do not yet
understand both jac-scale response envelopes (#37).

## 4.5 Test data: `parameterize.jac`

Applied after correlation, so substituted values cannot disturb the recorded ids correlation matches on.

**Inline tokens**: `substitute_tokens` runs `_TOKEN_PATTERN` over the body, URL and every header
value. Unknown `{{names}}` are left untouched (a blank would be harder to notice than a literal
`{{typo}}`).

| Token | Value |
|---|---|
| `{{vu_id}}`, `{{iter}}` | the VU id; the iteration number |
| `{{uuid}}` | a fresh UUID4 each use |
| `{{now}}`, `{{now+30s}}`, `{{now-5m}}`, `{{now+2h}}` | epoch seconds, optionally offset (`_parse_offset`) |
| `{{randint:a,b}}` | random integer in range (bounds validated) |
| `{{account.<col>}}` | column from the VU's account row (section 3) |
| `{{env.<VAR>}}` | environment variable, empty if unset |

**`--param 'Endpoint.body.field=values.csv'`** (repeatable): `parse_param_rules` loads the values with
`_load_values` (one value per line, or `file.csv:column`, or a JSON list file) and targets
`body.<json.path>`, `query.<name>` or `header.<name>`. `ParamRule.value_for(ctx)` picks row
`(vu_id + iteration) % len(values)`, so a VU sees new data each iteration and two VUs in the same
iteration differ. `apply_params` runs the `--param` rules first (a drawn value may itself contain a
token), then the token pass. A missing body path is a no-op, never an invented field.

**Context**: `ParamContext(vu_id, iteration, account)` is built per iteration only when `--param`
rules exist or the HAR contains a token (`_entries_have_tokens`), so plain runs pay nothing.

## 4.6 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--correlate RULE` (repeatable) | none | explicit rule (4.3) |
| `--no-auto-correlate` | detection on | skip `detect_correlations` |
| `x-jac-correlate` (HAR annotation) | none | same syntax as `--correlate` |
| `--param RULE` (repeatable) | none | file-fed field values (4.5) |
| inline `{{tokens}}` | none | written into the HAR or edited in |

---

# 5. Run orchestration

**Goal of this stage:** decide how the work is split across processes, start it, supervise it, and
end it cleanly.

**Files:** `cli.jac` (`run()`), `core/protocols.jac` (`run_all_protocols`), `core/process_runner.jac`
(`run_multiprocess`, workers), and the supervisors in `core/engine.jac` (`run_all_vus`).

## 5.1 Choosing the path in `cli.run()`

After parsing and validation (sections 1–4), `run()` builds `entries` (HTTP/GraphQL),
`ws_scenarios`, `graphql_scenarios`, the `AuthProvider`, `TopologyRouter`, correlation and param rules,
then:

```
config.workers > 1 ?  yes ─▶ run_multiprocess(...)          (spawn worker processes)
                      no  ─▶ asyncio.run(run_all_protocols(...))   (everything in this process)
```

`--workers` defaults to the CPU count, so the multiprocess path is the normal case on a multi-core
machine. `AuthenticationError` from either path becomes `Error: …`, exit `2`. The `rich` spinner
"Running load test — N VUs…" is shown on stderr meanwhile.

## 5.2 `run_all_protocols` — one process's whole workload

Starts, concurrently under one `asyncio.gather`:

- `run_all_vus(...)` if there are HTTP entries (sections 6–7);
- `run_ws_scenarios(...)` and `run_graphql_scenarios(...)` if there are scenarios (section 8). Their
  VU ids start above the HTTP VUs (`vu_id_offset + config.vus`), so a sample can still be attributed;
- a standalone duration watcher only when `--duration` is set and there are **no** HTTP entries
  (otherwise `run_all_vus` owns it).

All of them share one `MetricsCollector` and one `stop_requested` `asyncio.Event`.

## 5.3 `run_all_vus` — the in-process supervisor

1. **Poll rules**: `parse_poll_rules(config.poll_until, config.poll_error_until)` once (section 6.5).
2. **Signals**: on the main thread, the first `SIGINT` sets `stop_requested` (graceful: VUs finish the
   current request, a partial report is still produced); a second exits immediately with code `130`.
   Off the main thread (embedders) signal handling is skipped and the caller's own event is used.
3. **Authentication**: use `pre_authed_tokens` if given (worker path); else run the pre-run burst here
   (section 3.3).
4. **Baseline shapes** for the body check: `baseline_shapes_from(entries)` when `--no-body-check` is
   not set (or `--check-shape` is), computed from the HAR at no extra cost (section 7.5).
5. **Proxy pool**: `load_proxies(config.proxy_pool)`.
6. **Mode selection**, mutually exclusive: `open_loop` + `step_load` raises; `duration` + `step_load`
   raises; `--open-loop` requires `--rps > 0`; `--step-load` requires `--step-vus > 0`. Then it
   creates tasks for exactly one of `_run_open_loop`, `_run_step_load`, or one `_run_vu` per VU
   (section 6).
7. **Side tasks**: `_threshold_watcher` (only with `--abort-on-fail` and at least one
   `--fail-on-*`), `_duration_watcher` (`--duration`), `_stream_metrics` (only when an embedder passed
   a callback, every `stream_interval` seconds).
8. `await asyncio.gather(*tasks)`; in `finally`, the side tasks are cancelled and the original SIGINT
   handler is restored.

**`_threshold_watcher`** wakes every second; after `--threshold-start-delay` it evaluates
`_thresholds_breached` (error rate against `--fail-on-error-rate`; p95/p99 against `--fail-on-p95/p99`;
all-failed with no latency counts as a breach) and, on breach, prints "Threshold breached — stopping
test early" and sets `stop_requested`.
**`_duration_watcher`** sleeps `parse_duration(--duration)` then sets `stop_requested`.

## 5.4 The multiprocess path: `run_multiprocess`

1. **Worker count**: `min(--workers, VUs + scenario VUs, CPU count)`; a warning is printed if
   `--workers` exceeds the CPU count.
2. **Splitting**: `_distribute(total, parts)` gives each share the floor and the first `remainder`
   shares one extra, summing back exactly. The HTTP VUs, each WebSocket scenario's VUs and each
   GraphQL scenario's VUs are split independently (`_split_scenarios` copies the scenario with a
   smaller `vus`), so a worker can hold only scenarios, or only HTTP VUs. Workers with no work are
   dropped.
3. **`--max-samples`** is one budget: each worker gets a share proportional to the VUs it drives.
4. **`--rps`** is split across workers by VU share in `_worker_fn`, so the global budget is not
   multiplied.
5. **Pre-resolution and auth on the controller**: `_resolve_hosts` resolves the `--url` host once and
   passes the IP map to workers (`_PreResolvedResolver`), so DNS is not part of the measurement.
   `_pre_authenticate_all` runs the login burst once (section 3.3) and hands each worker only its
   `{vu_id: token}` slice.
6. **Spawn**: `multiprocessing.get_context("spawn")` is used, with a result queue and, when the
   controller owns `--abort-on-fail`, a shared `controller_abort` event. Each worker runs
   `_worker_fn`: it copies the config (`copy.copy`) and overrides only `vus`, `rps`, `max_samples` and
   `abort_on_fail`, then `asyncio.run(_worker_main(...))`, which calls `run_all_protocols`. A
   `_shared_stop_bridge` task polls the shared events at 10 Hz and mirrors them onto a plain
   `asyncio.Event`, so the engine's per-request `is_set()` check stays an in-process call.
7. **Live view and fleet abort**: workers push `("worker_snapshot", idx, StatsSnapshot)` to the queue
   (every second when the controller owns the abort, else every `stream_interval`). When every
   still-active worker has a fresh snapshot, the controller merges them (`_merge_snapshots`, which sums
   the latency histograms and reads percentiles from the sum; section 9.3). If `--abort-on-fail` is on,
   the delay has passed and `_snapshot_breached` is true, the controller prints the message and sets
   `controller_abort`. Workers do not run their own watcher (`worker_config.abort_on_fail = False`),
   because each only sees a slice of the traffic.
8. **Collect**: each worker finally sends `("ok", idx, samples, samples_evicted)` or
   `("error", idx, traceback)`. Any error raises `RuntimeError("Worker process failed: …")`. Otherwise
   `_merge_worker_results` records every sample into one `MetricsCollector` (and carries over each
   worker's eviction count).

`--step-load` with `--workers > 1` is rejected up front (section 1.7), since per-worker ramps cannot be
merged into one step report.

## 5.5 After the run

Control returns to `cli.run()` for classification, statistics, rendering and the exit code (sections
9–10).

## 5.6 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--workers` | CPU count | number of processes (5.4) |
| `--duration` | none | `_duration_watcher` (and `iterations=None`, section 1.4) |
| `--abort-on-fail` | off | `_threshold_watcher` (single process) or controller abort (multiprocess) |
| `--threshold-start-delay` | `0s` | grace period before the abort check starts |
| `--fail-on-error-rate`, `--fail-on-p95`, `--fail-on-p99` | none | the limits the abort check uses; the end-of-run gate is section 10 |
| `--max-samples` | `1000000` | sample buffer, split per worker |
| `--proxy-pool FILE` | none | one proxy URL per line, assigned per VU (`proxy_for`: `proxies[vu_id % n]`) |
| `--mode`, `--services-map` | `monolith` | microservice routing, outside this document's scope |

---

# 6. The VU loop and load shapes

**Goal of this stage:** drive each virtual user through the recorded sequence, in the load shape the
command asked for.

**File:** `core/engine.jac`.

## 6.1 One iteration: `_run_iteration`

The unit shared by every load shape: one full pass through `entries` for one logical session.

1. Create this VU's `CorrelationTable` (if there are rules) and `ParamContext` (if needed, anchored on
   `auth_provider.credential_for(vu_id).extra`).
2. Walk `entries` with an index (not a plain `for`, because a poll block consumes several entries at
   once):
   - stop if `stop_requested` is set;
   - **skip the recorded login** (`is_login`) when this VU already holds a token;
   - with `--rps`, `await asyncio.sleep(rps_interval)` first (6.2);
   - if the entry's endpoint has a `--poll-until` rule, the run is longer than 1 and this is its first
     member, call `_run_poll_block` (6.5) and advance by the run size; otherwise `_send_request`
     (section 7) and advance by 1;
   - a `None` result means "no route" (microservice mode only): warn once per path and skip;
   - `metrics.record(result)`; with `--debug`, `_print_debug` prints
     `[VU n] endpoint status latency` to stderr;
   - with `--think-time real|scaled`, sleep `think_time_ms / 1000 × --think-time-scale` (the gap
     computed in section 2.6). `none` (default) sleeps nothing.
3. If `--health-check PATH` is set, send one extra unauthenticated `GET` to it at the end of the
   iteration (`_send_health_check`, reusing `_send_request` with no auth, correlation or params). Its row
   is reported separately and excluded from the global figures.

## 6.2 Closed loop: `_run_vu` (default)

One coroutine per VU, started with a staggered delay `i / vus × ramp_up` (`--ramp-up`), each with its
own `aiohttp.ClientSession` and `TCPConnector` (using the pre-resolved host map if present). It loops
`_run_iteration` until `stop_requested` or `iteration >= --iterations`. Because each VU waits for its own
responses, a slow target lowers the achieved rate (closed loop).

`--rps` is a global cap implemented per VU: `rps_interval = vus / rps` seconds before each request
(`--rps` applies to requests, not iterations, in this mode).

## 6.3 Open loop: `_run_open_loop` (`--open-loop`)

Requires `--rps > 0`. A new iteration is launched every `1 / rps` seconds on a schedule anchored to
`loop.time()` (`next_tick += interval`, so overhead cannot accumulate drift). Iterations are *not*
awaited before the next launch, so a slow target makes concurrency grow instead of lowering the rate.
In this mode `--rps` is the **iteration arrival rate**, not a request cap. Total arrivals are
`vus × iterations`, or unbounded with `--duration`. VU ids cycle `i % vus`; the connector has
`limit=0` (no connection cap).

## 6.4 Step load: `_run_step_load` (`--step-load`)

Finds the capacity knee. Start with `--vus`, hold for `--step-duration`, then evaluate **that step's own
window** of samples (not the cumulative run, which would dilute a late breach) with `_breach_check`
against `--fail-on-error-rate/p95/p99`. Each step appends a `StepResult(step, vus, start_s, end_s,
total_requests, error_rate_pct, p95_ms, p99_ms, breached)` to `metrics.step_results`. On breach the ramp
and test stop. Otherwise `--step-vus` more VUs are spawned (capped by `--step-max-vus`) and the next
step begins; at the ceiling it holds. New VUs reuse an existing VU's token (section 3.7). The run ends
when stopped, when a step breaches, or when every VU has finished a finite `--iterations`. Validation
requires `--step-vus > 0` and either `--step-max-vus` or at least one threshold (otherwise there is
no stopping condition). Only `--workers 1` is supported, and because `--workers` defaults to the CPU count, `--step-load` must be run with an explicit `--workers 1` (otherwise it exits `2`).

## 6.5 Poll blocks: `--poll-until` / `--poll-error-until`

For a status-polling loop recorded as several adjacent calls to one endpoint, replaying the recorded
count is wrong: a launch slower than the recording runs out of polls and scores whatever the last
answer was (often still a 200).

- `parse_poll_rules` reads `ENDPOINT:PATH=VALUE[,VALUE...]` into `PollRule(endpoint, path,
  success_values, error_values)`; both flags are repeatable, one polled path per endpoint.
  `--poll-until` values are terminal success states, `--poll-error-until` terminal failures.
  `_poll_rule_for` matches the endpoint via `endpoint_matches` (full path or last segment).
- `_run_poll_block` re-sends the block's first recorded request (same correlation and params) until
  `_poll_body_match` finds the JSON path at a configured value, or `--poll-timeout` (default `60s`)
  expires. The wait between polls is `--poll-interval`, else the recorded gap, else 1 s. A transport
  error or unexpected status ends the block at once.
- The block yields **one** `RequestResult` with the total elapsed time. Outcome: success → no error;
  error value → `POLL_TERMINAL_ERROR`; real failure → its own reason; else `POLL_TIMEOUT: no terminal
  state after N poll(s) / Ts`.

Known gap: the block's long total latency enters the global p95/p99 (roadmap item).

## 6.6 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--vus`, `--iterations` | `1`, `1` | VU count; passes per VU (also the open-loop arrival count) |
| `--ramp-up` | `0s` | staggered VU start (closed loop) |
| `--rps` | `0` (off) | closed: global request cap; open loop: iteration arrival rate |
| `--open-loop` | off | 6.3 |
| `--step-load`, `--step-vus`, `--step-duration`, `--step-max-vus` | off | 6.4 |
| `--think-time`, `--think-time-scale` | `none`, `1.0` | sleep between entries |
| `--health-check PATH` | none | per-iteration probe |
| `--poll-until`, `--poll-error-until`, `--poll-timeout`, `--poll-interval` | none, none, `60s`, recorded gap | 6.5 |
| `--debug` | off | per-request stderr line |

---

# 7. Sending a request and judging it

**Goal of this stage:** turn one `HarEntry` into one HTTP request for one VU, send it, and decide
whether it succeeded, producing a `RequestResult`.

**Files:** `core/engine.jac` (`_send_request`), `bridge/body_check.jac`, `core/infra_block.jac`
(per-response fingerprint), `core/metrics.jac` (`RequestResult`).

## 7.1 Build the request (`_send_request`, before sending)

In this order:

1. **Headers**: the entry's sanitised headers, plus `Authorization: Bearer <token>` for this VU and, with
   `--csrf`, `X-CSRFToken` on non-GET requests (section 3.5).
2. **Route** (`topology.resolve`): in monolith mode the URL is already `--url`-based and the service name
   is `monolith`.
3. **Endpoint label**: `normalize_path(url)` rewrites all-digit and 32–36-char hex/UUID path segments to
   `{id}`, so rows aggregate by endpoint, not by object.
4. **Correlation**: `apply_correlations` (4.4); a miss returns a `CORRELATION_MISS` result without sending.
5. **Parameterisation**: `apply_params` (4.5), on the URL, body and headers.

## 7.2 Send and time it

`session.request(...)` with `allow_redirects=False`, an `aiohttp.ClientTimeout(total=--timeout)` set on the VU's session, an
optional per-VU proxy, and a `trace_request_ctx`. An `aiohttp` `TraceConfig` (`on_request_end`)
stores the time headers arrived, which gives **TTFB**; full latency is measured after the body is read.

## 7.3 Failure classification when no response arrives

| Exception | `error_type` | `latency_valid` |
|---|---|---|
| `asyncio.TimeoutError` | `TIMEOUT` (latency recorded as `--timeout`) | false |
| `ClientConnectorDNSError` | `DNS_ERROR` | false |
| `ClientSSLError` | `SSL_ERROR` | false |
| `ClientConnectorError` | `CONNECTION_REFUSED` | false |
| `ServerDisconnectedError` | `SERVER_DISCONNECTED` | true |
| `ClientOSError` | `CONNECTION_RESET` | true |
| anything else | upper-cased exception text | true |

`latency_valid=false` keeps fabricated latencies out of every percentile (section 9).

## 7.4 Judging a response that did arrive

In order, each step only if the previous found no failure:

1. **Status**: `status != expected_status` (the recorded status) is a failure, counted as
   `expected N got M` with the first 500 characters of the body kept for the report.
2. **Mid-run 401**: if `401` and the recording did not expect it, re-authenticate once and resend
   (section 3.6). A second 401 is `AUTH_EXPIRED`.
3. **Correlation capture**: the response body and headers go into this VU's table (4.4).
4. **`--assert-json`** (repeatable `PATH=VALUE`, optionally `ENDPOINT:PATH=VALUE`): only on a response
   whose status already matched. `parse_assert_json` returns `(path, value, endpoint)`;
   `assertions_for` keeps the global ones plus those scoped to this endpoint (`endpoint_matches`).
   `_check_json_assertions` resolves the dotted path (`_resolve_json_path`, list indices allowed);
   `*` as value means "present". Failures are `ASSERTION_FAILED: …` with a constant label, so one
   failing assertion is one bucket in the breakdown.
5. **Body check** (`--no-body-check` disables): see 7.5. Runs only when the status matched, no
   assertion failed, and no auth error occurred.
6. **Shape check** (`--check-shape`): see 7.5.
7. **Infra fingerprint**: for a failed response, `infra_fingerprint(body)` (SHA-256 prefix of the first
   2 KiB) is stored in `body_hash` — only for non-JSON bodies. Section 9.2 uses it.

The result is a `RequestResult`: endpoint, service, status, `latency_ms`, `ttfb_ms`, bytes, timestamp,
`vu_id`, `error_type`, `body_hash`, `expected_status`, `response_text`, `occurrence` counters, `trace_id`
(first of `traceparent`, `x-trace-id`, `x-b3-traceid`, `x-amzn-trace-id`, `x-request-id` found by
`extract_trace_id`), `protocol`, `correlation_applied`, `poll_match`.

## 7.5 `bridge/body_check.jac` — failures inside an HTTP 200

jac-scale walkers often answer 200 with the failure in the body, so a status check alone can report a
0% error rate while nothing works.

- `_unwrap_jac_scale` looks past `data` and `data.result` for the level that carries `reports`, `error`
  or `errors`, falling back to the body itself.
- `check_body(raw, baseline)` returns `APP_ERROR_IN_200: …` for: a non-empty `error`/`errors`; an inner
  `status` ≥ 400; any `reports[].success == false`; an empty `reports` where the **recording** had
  results (baseline). Non-JSON bodies and bodies with none of these markers are left alone. A bare
  `{"ok": false}` is deliberately not flagged (use `--assert-json`).
- `baseline_shapes(entries)` builds, once per run and from the HAR only, an endpoint → `ResponseShape`
  map (top-level keys, whether `reports` was non-empty).
- `check_shape(raw, baseline)` (`--check-shape`) returns `SHAPE_DRIFT: missing key(s) …` when a
  top-level key from the recording is absent.

Known gaps: `_unwrap_jac_scale` prefers `data.result` over `data.reports`, which on jac 0.37+ holds the walker's own fields instead of `reports` (#38);
`--fail-on-shape-drift` has no effect and drift counts as an error (#43).

## 7.6 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--timeout` | `30s` | `aiohttp` total timeout per request |
| `--assert-json EXPR` (repeatable) | none | 7.4 step 4 |
| `--no-body-check` | check on | skip 7.5 |
| `--check-shape` | off | also flag shape drift |
| `--fail-on-shape-drift` | off | declared; currently unused (#43) |
| `--csrf` | off | section 3.5 |
| `--proxy-pool` | none | per-VU proxy |
| `--debug` | off | print each result |

---

# 8. WebSocket and GraphQL

**Goal of this stage:** replay recorded WebSocket connections and GraphQL subscriptions, and report them
as their own rows next to the HTTP ones.

**Files:** `core/ws_engine.jac`, `core/graphql_engine.jac` (both launched by `run_all_protocols`,
section 5.2). GraphQL over plain HTTP is *not* here: it replays through the HTTP engine, only tagged
`protocol="graphql"` (section 2.4).

## 8.1 How scenarios arise

`scenarios_from_har_entries(all_entries, vus=config.vus, iterations=config.iterations)` in each module
makes one scenario per recorded entry of its protocol, copying the run's `--vus` and iteration count
(there is no per-scenario CLI setting). Embedders may also pass `ws_scenarios` / `graphql_scenarios` JSON
to `run_test_headless`, parsed by `parse_ws_scenarios` / `parse_graphql_scenarios`.

| Object | Fields |
|---|---|
| `WsScenarioConfig` | `url`, `messages` (sent frames), `vus`, `iterations`, `duration`, `timeout`, `name`, `think_time_ms`, `headers` |
| `GraphQLScenarioConfig` | `url`, `query`, `variables`, `operation_name`, `vus`, `iterations`, `duration`, `timeout`, `name`, `max_events`, `headers` |

`scenario_endpoint(url, name, label)` names the report row: an explicit `name`, else `WS <path>` /
`GraphQL <path>`. `duration` is parsed but currently unused (#42).

## 8.2 Raw WebSocket: `_run_ws_vu`

Per VU, per iteration:

1. Open a `ClientSession` and `ws_connect(url, headers)`.
2. Record the handshake as its own row `"<endpoint> [connect]"` (status 101, expected 101), so connect
   latency never mixes with message round trips. A connection with no frames still produces this row.
3. For each recorded message: `send_str`, then wait for one reply with `asyncio.wait_for(ws.receive(),
   timeout)`. A text or binary frame is recorded as success (status 101, latency = round trip, bytes =
   reply length); a timeout is `WS_TIMEOUT` (invalid latency); any other frame type is
   `WS_UNEXPECTED_FRAME_<TYPE>`. `think_time_ms` is slept between messages.
4. A connection error is `WS_CONNECTION_ERROR`.

Limits: one reply is expected per message, any text frame counts as success (an application error frame
is not detected), the reply is not matched to its request, and the VU's HTTP token is not sent: only
the recorded, sanitised handshake headers are (roadmap section 3).

## 8.3 GraphQL subscription: `_run_graphql_vu` / `_run_one_subscription`

Uses the `graphql-ws` subprotocol on the same WebSocket primitive:

1. `connect` with `protocols=["graphql-ws"]`; send `connection_init`; require a `connection_ack`
   (else `RuntimeError`, reported as `GRAPHQL_CONNECTION_ERROR`).
2. Send `{"id": <uuid>, "type": "start", "payload": {query, variables?, operationName?}}`
   (`_subscribe_payload`).
3. Loop on incoming frames. `data` / `next`: record one result per event, with latency measured from the
   previous event (so the first sample is time-to-first-event and the row's RPS is events per second);
   a payload with `errors` is status 500 / `GRAPHQL_ERROR`. `error`: record `GRAPHQL_ERROR` and stop.
   `complete`: stop. A silent `--timeout` is `GRAPHQL_TIMEOUT`. `max_events` (0 = unlimited) ends the
   subscription early.
4. Always send a `stop` frame on exit.

## 8.4 Metrics tagging

Every sample carries `protocol` (`ws` / `graphql` / `http`). `compute_endpoint_stats` groups by
`(protocol, endpoint)`, and the console report adds a `Proto` column when any non-HTTP row exists.

## 8.5 Flags acting at this stage

No dedicated flags. A HAR with WebSocket or subscription entries triggers these engines automatically;
`--vus`, `--iterations` and `--duration` apply to them. Chrome's plain HAR export omits WebSocket
frames, so such a connection replays as a bare connect (a warning is printed, section 2.5).

---

# 9. Metrics and post-run analysis

**Goal of this stage:** turn the raw per-request samples into the numbers the report shows, after the run
and before rendering.

**Files:** `core/metrics.jac`, `core/infra_block.jac`; called from the middle of `cli.run()`.

## 9.1 `MetricsCollector`

One per process (workers each have one, merged at the end). `record(result)`:

- increments `total_count`; increments `error_count` if `error_type` is set or `status !=
  expected_status`;
- adds the latency to a running **histogram** if `latency_valid`;
- appends to `_samples`, a `deque(maxlen=--max-samples)`. When full, the oldest sample is dropped,
  `samples_evicted` is counted and a one-time warning says percentiles then cover only the retained
  window. The JSON report sets `window_limited` when this happened.

Related objects: `RequestResult` (7.4), `EndpointStats`, `StatsSnapshot`, `StepResult` (6.4).

## 9.2 Infra-block classification (`core/infra_block.jac`)

Run once after the run: `classify(samples, threshold, t_start)`.

Behind a WAF or rate limiter, one network egress address makes many requests and a share come back as the
*same canned deny page*. Counted naively that is an app outage that never happened. The signal that
separates them: a deny page is identical across unrelated endpoints at the same time; an app failure is
specific to what was asked.

- Only failed samples with a `body_hash` (non-JSON body, 7.4) are considered.
- Samples are bucketed by 10 s (`BUCKET_SECONDS`) and hash. A hash seen on at least
  `--infra-block-threshold` distinct endpoints in one bucket (default `3`) is a block.
- Matching samples are relabelled `INFRA_BLOCK_SUSPECTED: identical non-JSON body across endpoints`.
  Nothing is deleted. Threshold below `2` disables the check (`--infra-block-threshold 1`).
- In the statistics, these are counted separately, kept in `total_requests`, and excluded from the error
  rate's numerator and denominator.

## 9.3 Statistics (`compute_endpoint_stats`)

Groups samples by `(protocol, endpoint)`; per group:

- `total`, `success_count` (no error and expected status), `infra_block_count`, `error_count = total −
  success − infra_blocks`, `success_rate = success / (total − infra_blocks)`;
- latency stats from `latency_valid` samples only: min, max, mean, `p50/p95/p99/p99.9` using the
  nearest-rank `percentile()`; mean TTFB;
- `rps = total / actual_duration`; bytes received;
- **Apdex** with `--apdex-t` (T, default 500 ms): satisfied ≤ T, tolerating ≤ 4T, counting only
  successes; score `(satisfied + ½ tolerating) / total`;
- **completion times** (seconds from run start to each response) p50/p95/p99;
- `error_breakdown`: counts per error label (including `call #N of M` for repeated paths, and `expected
  N got M: <body snippet>`), and `error_samples`: up to 3 trace ids per label.

`measured_duration_s()` is first request start to last response end, taken from the samples, so
multiprocess start-up is not billed against throughput.

## 9.4 Time series and live snapshots

- `generate_timeseries` (cumulative) and `generate_interval_timeseries` (per 10 s window) feed the JSON and
  HTML charts. The interval series shows a short burst that the cumulative one would dilute.
- `snapshot_now(t_start)` is O(1): it reads the running counters and histogram and returns a
  `StatsSnapshot` (percentiles, rps, error rate, total, bucket counts). It drives `--abort-on-fail` and
  the live callback.
- **Histogram** (`histogram_bucket`): 300 fixed exponential buckets from 0.5 ms growing 5 % each; sums
  across workers are plain addition (`merge_histograms`), and `histogram_percentile` reads a value at most
  ~5 % above the true one. It is used only for the live view and the mid-run abort; the final report
  recomputes exact percentiles from the merged raw samples.

## 9.5 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--infra-block-threshold N` | `3` | 9.2; `1` disables |
| `--apdex-t MS` | `500` | Apdex satisfied threshold |
| `--max-samples N` | `1000000` | sample buffer size |

---

# 10. Reports, thresholds and exit codes

**Goal of this stage:** present the results and turn them into a process exit code a CI job can use.

**Files:** `output/reporter.jac`, `templates/reporter_template.html` and `templates/vendor/chart.umd.min.js`,
and the tail of `cli.run()`.

## 10.1 Choosing the format

`config.report_format` (`--report-format`, default `console`):

| Format | Output |
|---|---|
| `console` | `render_console`: a `rich` table on **stderr** |
| `json` | `render_json` string, printed to stdout, or written to `--report-out` |
| `html` | `render_html`: requires `--report-out` (else exit `2`); written to that file |

## 10.2 What every report contains

- **Per endpoint**: requests, RPS, OK %, p50/p95/p99/p99.9 (rated good / acceptable / bad), Apdex, bytes,
  errors, mean TTFB, error breakdown with trace ids, infra blocks, protocol and (microservice mode) service.
- **Summary / TOTAL row**: the same figures rolled up over all rows **except** the `--health-check` row,
  with the rate computed over requests the application received (infra blocks excluded).
- Notes under the table: infra-block count and share, `--param` use, and a warning when samples were
  evicted.
- **Step load**: a table of steps (VUs, window, requests, error %, p95, p99, OK/BREACHED) and the
  **capacity knee**: the VUs of the last passing step (JSON: `step_load`, `capacity_knee_vus`).
- **JSON only**: `meta` (file, URL, mode, VUs, iterations, workers, load mode, duration, evictions,
  `window_limited`, `parameterized_fields`, `skip_failed_accounts`), `latency_benchmarks`, `endpoints`,
  `summary`, `cumulative_timeseries`, `interval_timeseries`.

## 10.3 Latency ratings and `--slo`

`_LATENCY_THRESHOLDS` define default good/bad bounds in ms: p50 100/500, p95 500/2000, p99 1000/5000, p99.9
2000/10000. `_latency_rating` returns Good below `good`, Acceptable below `bad`, else Bad. `--slo JSON`
(`parse_slo_map`, validated) overrides them per endpoint, e.g. `{"/walker/X": {"p95": {"good": 200, "bad":
800}}}`; `good` must be below `bad`. The summary rating always uses the defaults. SLOs affect colouring
and ratings only; failing the run is the job of the `--fail-on-*` flags below.

## 10.4 The HTML report

`render_html` fills `reporter_template.html` (a `string.Template`) with the JSON report and replaces the
`__CHARTJS_INLINE__` marker with the vendored Chart.js source, producing a **single self-contained file**
with the time-series charts and no network access.

## 10.5 Threshold gate and exit codes

After rendering, `cli.run()` checks `--fail-on-*` against the finished run and collects messages:

| Check | Source |
|---|---|
| `--fail-on-error-rate N` | `metrics.error_count / metrics.total_count × 100 > N` |
| bare `--fail-on-p95 MS` / `--fail-on-p99 MS` | percentile of all `latency_valid` samples, **excluding** the `--health-check` endpoint; if no sample has a measured latency, that itself fails ("a dead target must not look fast") |
| `--fail-on-p95 ENDPOINT:MS` / `--fail-on-p99 ENDPOINT:MS` (repeatable) | that endpoint's own p95/p99 from the stats; an endpoint with no samples is reported as a failure |

Each failure prints `THRESHOLD FAILED: …` to stderr. Any failure → exit **`1`**.

| Exit code | Meaning |
|---|---|
| `0` | run completed, no threshold failed (or none set) |
| `1` | at least one `--fail-on-*` threshold failed |
| `2` | bad command: invalid config or flag, unreadable HAR, no entries, authentication failed, missing `--report-out` for HTML |
| `130` | second Ctrl-C during the run |

An uncaught worker error raises, so the process ends with a Python error. Note that
`--fail-on-error-rate` currently counts infra blocks and health-check samples that the report excludes,
so the gate and the printed rate can disagree (#41).

## 10.6 Embedders

`headless.run_test_headless(config_dict, …)` runs sections 2–9 without the CLI wrapper and returns the
result for `render_json()` / `render_html()`; it announces no correlation rules on stderr and does not
sys.exit. The CLI is just one front end.

## 10.7 Flags acting at this stage

| Flag | Default | Effect |
|---|---|---|
| `--report-format console\|json\|html` | `console` | 10.1 |
| `--report-out PATH` | none | file for json/html |
| `--slo JSON` | none | per-endpoint rating bounds |
| `--fail-on-error-rate N` | none | 10.5 |
| `--fail-on-p95`, `--fail-on-p99` | none | 10.5 (global or `ENDPOINT:MS`) |
| `--apdex-t` | `500` | Apdex scoring (9.3) |

# Flag index

Every flag and the section where it takes effect:

| Section | Flags |
|---|---|
| 1 | `har_file`, `--url`, `--mode`, `--debug` (config only) |
| 2 | `--include-static`, `--login-path`, `--think-time*` (data), `--poll-*` (data) |
| 3 | `--accounts`, `--username`, `--password`, `--register-path`, `--no-auto-register`, `--skip-failed-accounts`, `--auth-delay`, `--auth-batch-size`, `--auth-batch-delay`, `--csrf` |
| 4 | `--correlate`, `--no-auto-correlate`, `--param` |
| 5 | `--workers`, `--abort-on-fail`, `--threshold-start-delay`, `--proxy-pool`, `--max-samples`, `--services-map` |
| 6 | `--vus`, `--iterations`, `--duration`, `--ramp-up`, `--rps`, `--open-loop`, `--step-load`, `--step-vus`, `--step-duration`, `--step-max-vus`, `--think-time`, `--think-time-scale`, `--health-check`, `--poll-until`, `--poll-error-until`, `--poll-timeout`, `--poll-interval` |
| 7 | `--timeout`, `--assert-json`, `--no-body-check`, `--check-shape`, `--fail-on-shape-drift` |
| 8 | (none; automatic from the HAR) |
| 9 | `--infra-block-threshold`, `--apdex-t` |
| 10 | `--report-format`, `--report-out`, `--slo`, `--fail-on-error-rate`, `--fail-on-p95`, `--fail-on-p99` |
