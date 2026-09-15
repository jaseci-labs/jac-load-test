# jac loadtest — Command Reference

```
jac x loadtest <har_file> [options]
```

Settings are resolved in three layers — the **Use in** column shows where each flag can be configured:

```
CLI flag (--vus 50)          ← always wins
  ↓ if not passed
jac.toml ([plugins.scale.loadtest])  ← project/team default
  ↓ if not present
Built-in default             ← shown in the Default column below
```

Flags marked **CLI only** are never read from `jac.toml` — they change per environment or contain sensitive credentials.

---

## Positional

| Argument | Required | Description |
|----------|----------|-------------|
| `har_file` | One of `har_file` / `--spec` | Path to the `.har` file exported from Chrome DevTools or any traffic recorder. |

---

## Testing straight from an OpenAPI / Swagger spec

No HAR file needed at all when the target already publishes an OpenAPI 3.0/3.1 or Swagger 2.0
document (JSON or YAML, path or URL — a FastAPI/jac-scale service's `/openapi.json` works
directly). Two ways to use it, both driven by `core/spec_parser.jac`'s
`parse_api_spec(source: str) -> list[dict]`:

**1. Load test directly (`--spec`) — no `.har` file ever touches disk:**

```
jac x loadtest --spec <source> --url <target> [options]
```

`--spec` replaces the `har_file` positional; the spec is parsed straight into HarEntry-compatible
entries in memory and fed into the normal run — same auth/correlation/`--param`/report flags as
a HAR-driven run. `har_file` and `--spec` are mutually exclusive; exactly one is required.

| Argument | Required | Description |
|----------|----------|-------------|
| `--spec` | One of `har_file` / `--spec` | Path or URL to the OpenAPI/Swagger document. |

**2. Generate a `.har` file first (`from-spec`)** — when you want to inspect, hand-edit, or
commit the recording before replaying it:

```
jac x loadtest from-spec <source> --out <recording.har>
jac x loadtest <recording.har> --url <target> [options]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `source` | Yes | Path or URL to the OpenAPI/Swagger document. |
| `--out` | Yes | Output `.har` file path. |

Both paths synthesise one entry per operation: method, URL, headers/query params from the
spec's `parameters`, and a request body built from the schema's `example`/`default` (falling
back to a type-shaped placeholder). Path templates (`/pets/{petId}`) are left untouched in the
synthesised URL — there is no recorded value to substitute in their place. Supply the real one
at run time with `--param 'GetPet.path=ids.txt'` or `--correlate '... -> GetPet.path'`.

---

## Protocol Support (WebSocket & GraphQL)

No flag needed — `jac x loadtest` automatically detects and replays WebSocket connections and
GraphQL traffic recorded in the HAR, alongside the regular HTTP entries, in the same run:

| What the HAR contains | What happens |
|---|---|
| A WebSocket connection (`_resourceType: "websocket"`, or any `ws://`/`wss://` URL — no `_resourceType` needed) | Replayed via the WebSocket adapter: connects, sends whatever message frames were captured, records reply latency. Rewritten to `ws://`/`wss://` under `--url`'s host, same as HTTP entries are rewritten. |
| A GraphQL subscription over that WebSocket connection (a `graphql-ws` `"start"`/`"subscribe"` frame carrying a `query`) | Replayed as a GraphQL subscription: records time-to-first-event latency and events/second, reported separately from raw WebSocket traffic. |
| A GraphQL query/mutation over plain HTTP (any JSON POST body with a top-level `query` field containing a `{` selection-set brace) | Replayed exactly like any other HTTP entry, just labeled `graphql` in the report so it doesn't blend into REST latency numbers. |

The report groups every endpoint by `(protocol, endpoint)` — a `Proto`/`Protocol` column
appears in the console/JSON/HTML output only when a run actually contains something other than
plain HTTP; a HAR with no WebSocket/GraphQL traffic produces the exact same report as before.

**WebSocket message capture is opportunistic.** A HAR entry's WebSocket frames live in a
non-standard `_webSocketMessages` field that a plain Chrome DevTools "Export HAR" does **not**
include — some other recorders (Playwright's HAR recorder with `mode: "full"`, mitmproxy) do.
Without it, the connection is still detected and replayed, just with no message sequence to
send; a one-time warning on stderr explains this when it happens. See `CONSTRAINTS.md` §7 —
the planned fixes are a built-in proxy recorder that captures frames (`jac x loadtest record`,
roadmap Phase 10b) and a `--ws-scenario` / `--graphql-scenario` file flag (Phase 9).

WebSocket/GraphQL entries work with any `--workers` count. The controller splits each detected
scenario's VU count across worker processes the same way it splits HTTP VUs, and every worker
runs the HTTP engine and the protocol adapters together against one merged report — so the same
HAR gives identical per-endpoint totals at `--workers 1` and `--workers 8`. Note that raising
`--workers` mainly helps when WebSocket VUs are *busy*; a single event loop already handles a
few thousand concurrent WebSocket VUs, since idle
connections are cheap.

**If your HAR has no WebSocket frames.** A Chrome DevTools export records that a WebSocket
connection happened but drops the frames sent over it, so there is nothing to replay. The run
continues — HTTP entries are unaffected — and you get a one-time warning plus a `[connect]` row
in the report showing handshake latency and volume. To replay actual message traffic, re-record
with a tool that preserves frames: Playwright's HAR recorder (`recordHar` with `mode: "full"`),
mitmproxy, or anything driving Chrome over the DevTools Protocol.

## Infrastructure blocks — when the WAF answers, not the app

Every VU egresses from one network interface, so the target sees all your load from a single IP.
Behind a WAF, an API gateway rate limiter, or a CDN bot filter, that trips a control and a share
of requests come back as an identical non-JSON deny page — typically a 403 or 429 with HTML.

Counted naively those are application errors, and the run reports a failure the application
never saw: the error rate is inflated, the per-endpoint breakdown blames whichever endpoints got
blocked, and their p95 is skewed by the fast deny response.

The tool separates them automatically. The signal is that **a deny page is the same page
everywhere** — an application failure is specific to what was asked, while infrastructure
returns one canned response regardless of the endpoint. So a byte-identical non-JSON body
appearing across ≥ 3 distinct endpoints in the same 10-second window is classified
`INFRA_BLOCK_SUSPECTED`:

```
Note: 20 response(s) (33.3%) classified as infrastructure blocks — identical
non-JSON bodies across several endpoints at the same moment, which is a WAF or
rate limiter rather than the application. Not counted as application errors.
```

Against a target blocking a third of traffic, this moved the headline from **46.7% errors** to
**20%**, with the blocks reported separately — and a genuinely broken endpoint kept its own 500s
throughout.

**What it deliberately will not do.** One endpoint returning the same HTML error repeatedly is
left alone: that is plausibly the application, and reclassifying it would hide a real failure.
Raise `--infra-block-threshold` to require more endpoints, or set it below 2 to switch the check
off entirely.

**How the rate is computed.** Blocked responses are excluded from the denominator, not just the
numerator. A response the edge generated never reached the application, so it can neither
succeed nor fail on its behalf — leaving it in would make a WAF look like an outage.
`total_requests` still counts everything, so the numbers reconcile: `success + errors +
infra_blocks == total`.

**Mitigating it.** `--proxy-pool proxies.txt` spreads egress across a list of proxies, assigned
per VU so each VU keeps one address (rotating mid-session would break keep-alive and distort the
latency being measured). It is a partial measure; genuinely distributing the source IPs is what
worker nodes are for.

## Varying the data each VU sends

A HAR replays one recorded payload for every VU and every iteration. That distorts results two
ways: reads hit a warm cache real traffic would miss, and writes collide — the second VU to
create a uniquely-named resource gets a 409 that says nothing about capacity.

**Inline tokens** need no data file and cover most of it. They work in any body, query or header
value, and in the URL path:

```json
{"ref": "{{uuid}}", "who": "vu{{vu_id}}-i{{iter}}", "tenant": "{{account.region}}"}
```

| Token | Expands to |
|---|---|
| `{{uuid}}` | A fresh UUID per expansion |
| `{{vu_id}}` / `{{iter}}` | VU index and iteration number |
| `{{randint:a,b}}` | Random integer in `[a, b]` |
| `{{now}}`, `{{now+30s}}`, `{{now-5m}}` | Epoch seconds, optionally offset (`s`/`m`/`h`) |
| `{{account.<col>}}` | A column from this VU's `--accounts` row |
| `{{env.<VAR>}}` | An environment variable |

`{{account.<col>}}` is what keeps a VU's data consistent with who it logged in as — give the
pool CSV a `region` column and VU 3 sends *its own* account's region.

**`--param`** draws from a file when you want realistic values rather than generated ones:

```bash
jac x loadtest recording.har --url http://localhost:8000 \
  --param "AddTodo.body.title=titles.csv" \
  --param "Search.query.q=queries.csv:term"
```

`titles.csv` is one value per line; the `:term` form picks a named column from a CSV with a
header. Rows advance by `(vu_id, iteration)`, so a VU sees different data each pass and two VUs
in the same pass differ. Values are drawn before tokens expand, so a file value can itself carry
one — `base-{{uuid}}` in the file works.

**Two things it deliberately does not do.** An unrecognised token is left exactly as written
rather than blanked, because a silently emptied field is far harder to notice than a literal
`{{typo}}` reaching the server. And a `--param` naming a field the body does not have is a no-op
rather than adding it, so a mistyped path shows as unchanged traffic instead of a puzzling 400.
A payload that merely contains braces — a JS snippet, the app's own template syntax — passes
through untouched.

**Reading the result.** A parameterized run is usually *slower* than the same run without it,
because identical payloads were hitting a cache real traffic would miss. The slower number is
the honest one. The console report notes when `--param` is in use.

## Accounts — one identity per VU

On jac-scale every request runs against the authenticated user's own root graph. Give N VUs one
shared token and all N serialize on one user's graph: that measures single-user contention under
concurrency, not the multi-user profile real traffic exercises.

`--accounts` gives each VU its own identity. The inline map is the common form:

```bash
jac x loadtest recording.har --url http://localhost:8000 \
  --accounts '{"alice":"pw1","bob":"pw2","carol":"pw3"}'
```

A file works the same way and keeps passwords out of your shell history:

```bash
--accounts accounts.csv     # header row with username,password (extra columns kept)
--accounts accounts.json    # {"alice":"pw1"} or [{"username":"alice","password":"pw1"}]
```

VUs are assigned accounts in order and wrap round-robin, so 6 VUs over 3 accounts gives each
account 2 VUs (warned once, since VUs sharing an account also share a root graph). Logins happen
once per *distinct account* on the controller before the replay loop — 500 VUs over 10 accounts
is 10 login calls, not 500 — and in multiprocess mode each worker receives only its own
VU-id→token slice, so raising `--workers` never multiplies auth traffic.

`--username`/`--password` still work; they are treated as a one-entry pool. `--accounts` wins if
both are given.

### Accounts that do not exist yet

A pool is only useful if the accounts exist, and creating them by hand defeats the point. When a
login returns 401, the account is registered via `--register-path` (default `/user/register`,
jac-scale's built-in signup) and the login retried.

The catch is that **jac-scale returns the same 401 `Invalid credentials` whether the account is
missing or the password is wrong**, so the login response alone cannot tell you whether to
register. The register response can:

| Register returns | Meaning | Result |
|---|---|---|
| `201` | Account did not exist | Created, login retried, run continues |
| `400 USER_EXISTS` | Account existed | Reported as a wrong password — nothing is overwritten |
| anything else | Server fault | Reported with the server's own message |

So a typo in `--accounts` is reported as a bad password rather than silently clobbering a real
account:

```
Error: Login failed for VU 0 ('alice'): Invalid credentials. The account exists, so this is a
wrong password rather than a missing account — fix the credential in --accounts.
```

`--no-auto-register` disables the fallback; missing accounts then fail the run instead.

### When an account cannot authenticate

By default the run aborts — a wrong credential should fail a build rather than quietly produce
a thinner test. `--skip-failed-accounts` continues instead.

Worth knowing what the unit of loss is: **one login serves every VU assigned to that account**,
so a single bad row in a 10-account pool costs a tenth of the run's identities, not one VU.

When tolerating, the requested VU count is preserved — VUs are re-spread over the accounts that
authenticated. Concurrency is what you asked to measure, so it stays; identity diversity is what
degrades, and the report says so:

```
Warning: 1 of 3 account(s) failed to authenticate; continuing on the remaining 2.
VUs were re-spread over those, so concurrency is unchanged but identity diversity
is lower than requested.
  broken: Login failed for VU 0 ('broken'): Invalid credentials...
```

Dropping the affected VUs instead would have been worse: the run would report the VU count you
asked for while having run fewer, leaving every throughput number wrong with nothing pointing at
why. A pool where *no* account authenticates still aborts regardless of the flag — that is a
misconfiguration (wrong `--url`, wrong `--login-path`, server down), not a bad row.

### When a token expires mid-run

Tokens are acquired before the replay loop, so a run longer than your JWT's lifetime used to
degrade into auth failures partway through. It now recovers: a `401` triggers one re-login for
that VU and one retry of the request.

- **Deduplicated per account.** A JWT expires at a wall time, so every VU holding it fails at
  once. The first VU to notice refreshes; the rest take that token rather than each firing their
  own login. Twelve VUs sharing an account recover on roughly one refresh, not twelve.
- **One retry.** If the retry is still refused the request fails as `AUTH_EXPIRED`, which keeps
  a genuinely wrong credential from retrying forever and keeps an expiry out of the generic 4xx
  bucket, where it is easy to mistake for the application rejecting requests.
- **A recorded 401 is left alone.** If the HAR entry expected a `401`, no refresh is attempted —
  a recording that deliberately exercises an auth-failure path still sees its 401.

Requires credentials (`--accounts`, or `--username`/`--password`); an unauthenticated run treats
a 401 as an ordinary response.

## Correlation — replaying your own IDs, not the recording's

A HAR records one user's session, so any request that operates on an existing object carries a
server-generated ID captured at record time. Replayed as-is, that ID belongs to the recording
user's data and often to a row that no longer exists, so mixed create → update → delete
workflows fail their ownership checks. Rotating credentials does not help: the ID is in the
request body, not the token.

**This is handled automatically.** At startup the recorded HAR is scanned for values that a
response hands to a later request — a value the browser copied forward is, by construction, a
value the replay has to reproduce. Each VU then threads the ID *it* was given:

```
Recording:   AddTodo -> id a3f7c2d1     ToggleTodo -> {"nd": "a3f7c2d1"}
VU 3 replay: AddTodo -> id ff91b823     ToggleTodo -> {"nd": "ff91b823"}   ✅
```

The scan reads the file only — it sends no requests and costs no extra round trip, which is why
it runs on every start rather than being a separate step. Detected rules are printed to stderr
at startup:

```
Correlation: 2 value(s) detected in the recording and threaded per-VU:
  AddTodo.response.reports.0.id -> ToggleTodo.(matched value)
  AddTodo.response.reports.0.id -> DeleteTodo.(matched value)
  (disable with --no-auto-correlate; override with --correlate)
```

**What gets correlated.** Only values that look like server-generated identifiers *and* that
exactly one response produced. Booleans, small numbers, status strings and prose are excluded,
and a value produced by two different endpoints is skipped as ambiguous. The guard is
deliberately tight: a missed correlation shows up as a 404 you can fix with `--correlate`, while
a wrong one would silently send different data than the recording did.

**When detection is not enough.** If the recording uses a value only once there is no second
occurrence to match on, so state the rule yourself:

```bash
jac x loadtest recording.har --url http://localhost:8000 \
  --correlate "AddTodo.response.reports.0.id -> ToggleTodo.body.nd"
```

Explicit rules win over detected ones for the same producer/consumer pair. A `x-jac-correlate`
field on a HAR entry is honoured the same way, for teams who prefer to annotate a HAR once and
commit it.

**Per VU, per iteration.** The variable table is created per VU and reset each iteration, so
VU 3 toggles the object VU 3 just created, and iteration 2 acts on the object iteration 2 made.

**When a value is missing.** If the producing request failed, the consumer is not sent at all —
it fails with `CORRELATION_MISS: <rule>`. Sending the recording's stale ID instead would show up
as a puzzling 404 blamed on the application.

**Turning it off.** `--no-auto-correlate` replays bodies exactly as recorded. Worth doing if you
are deliberately testing how the target handles requests for objects that do not belong to the
caller.

---

## Load Shape

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--url` | — (required in monolith mode) | URL string, e.g. `http://localhost:8000` | CLI only | Target base URL. Replaces the origin recorded in the HAR; path and query string are preserved. Changes per environment so not suitable for `jac.toml`. |
| `--health-check` | none (disabled) | URL path, e.g. `/healthz/live` | CLI + jac.toml | Fires one extra unauthenticated `GET` request to `--url` + this path, once per VU per completed iteration, alongside the HAR replay rather than as part of it. Gets its own row in the endpoint table with its own p50/p95/p99, but is excluded from the run's global/TOTAL aggregates — a fast liveness ping blended into the overall percentile would make those numbers look better than the recorded traffic actually performed. Gate it independently with `--fail-on-p95`/`--fail-on-p99`'s scoped `ENDPOINT:MS` form, e.g. `--fail-on-p99 "/healthz/live:100"`. Requires `--url`. |
| `--mode` | `monolith` | `monolith` \| `microservice` | CLI + jac.toml | Deployment topology. `monolith` routes all requests to `--url`. `microservice` reads service prefix→URL routing from `jac.toml` and sends each request directly to its service. |
| `--vus` | `1` | Positive integer, e.g. `50` | CLI + jac.toml | Number of virtual users (concurrent coroutines). Each VU replays the full HAR sequence independently. Practical ceiling is ~200–500 VUs per worker. |
| `--workers` | CPU count | Positive integer, e.g. `4` | CLI + jac.toml | Number of worker processes. Each worker runs its own asyncio event loop on a separate OS thread, bypassing the GIL. Capped automatically at `--vus` so no idle processes are spawned. Use `1` for single-process mode. |
| `--iterations` | `1` | Positive integer, e.g. `100` | CLI + jac.toml | Stop each VU after N complete HAR replays. Defaults to `1` (one full HAR replay per VU), unless `--duration` is set with no explicit `--iterations` — see below. The actual wall-clock time is measured and shown in the report regardless of this value. |
| `--duration` | — (disabled) | Time string: `10s`, `1m`, `5m` | CLI + jac.toml | Hard wall-clock cutoff for the whole run — stops all VUs once elapsed, regardless of `--iterations`. If set without an explicit `--iterations`, VUs loop indefinitely until the duration elapses instead of stopping after 1 replay, so the run length is a fixed, comparable measurement window rather than an emergent product of `vus × iterations × replay time`. Works with the default closed-loop mode and `--open-loop`. Not compatible with `--step-load`, which has its own step-based timing via `--step-duration`/`--step-max-vus`/`--fail-on-*`. |
| `--ramp-up` | `0s` | Time string: `10s`, `1m` | CLI + jac.toml | Stagger VU startup over this duration. With `--vus 50 --ramp-up 10s`, VU 1 starts at t=0s, VU 50 starts at t=9.8s. Prevents thundering herd at test start. |
| `--rps` | `0` (unlimited) | Non-negative integer, e.g. `100` | CLI + jac.toml | Global requests-per-second cap across all VUs combined. `0` means no cap. Implemented as a per-VU inter-request sleep of `vus/rps` seconds, which distributes the cap evenly. |
| `--open-loop` | `false` | Boolean flag (no value) | CLI + jac.toml | Fixed-arrival-rate mode. Launches a new session every `1/rps` seconds on a fixed schedule, regardless of how long earlier sessions are still taking to respond — unlike the default closed-loop mode, where each VU's next request is paced from its *previous response*, so achieved throughput silently degrades once the target slows down. Requires `--rps` to be a positive value; `--rps 0` (unlimited) has no fixed rate to schedule against. In this mode `--rps` means sessions/iterations per second, not a per-request cap — each session still replays its full HAR sequence once launched. Concurrency is not bounded — a slow target causes in-flight sessions to pile up, which is the point (it reveals real queueing instead of hiding it). |
| `--step-load` | `false` | Boolean flag (no value) | CLI + jac.toml | Step-load / ramp-to-failure mode. Starts at `--vus`, holds for `--step-duration`, adds `--step-vus` more, and repeats — until a `--fail-on-*` threshold breaches that step's own traffic window or `--step-max-vus` is reached. Finds the capacity knee (the last passing VU count) instead of testing at one fixed VU count; the report gets a per-step table plus a "Capacity knee" line. Each step is judged only on requests that landed *during that step*, not the cumulative run, so a breach isn't diluted by earlier passing steps. Single-process only (`--workers 1`); cannot be combined with `--open-loop`. Requires `--step-vus`, and requires `--step-max-vus` or at least one `--fail-on-*` flag as the stopping condition. |
| `--step-vus` | `0` | Positive integer, e.g. `10` | CLI + jac.toml | VUs added at each step in `--step-load` mode. |
| `--step-duration` | `30s` | Time string: `10s`, `1m` | CLI + jac.toml | How long to hold each step before evaluating thresholds and advancing to the next one, in `--step-load` mode. |
| `--step-max-vus` | `0` (no ceiling) | Non-negative integer, e.g. `200` | CLI + jac.toml | Ceiling on total VUs during the `--step-load` ramp. `0` means no ceiling — in that case at least one `--fail-on-*` threshold must be set so the ramp has a stopping condition. |

---

## Request Behavior

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--timeout` | `30s` | Time string: `10s`, `1m` | CLI + jac.toml | Per-request timeout. Requests that exceed this are recorded as `TIMEOUT` errors with `status=0` and `latency_ms` equal to the timeout value. |
| `--assert-json` | — (disabled) | `PATH=VALUE`, e.g. `'ok=true'` | CLI only, repeatable | Requires a JSON response-body field to equal a value for a request to count as successful, in addition to the status code — closes the gap where a `200` carrying an application-level error payload (e.g. `{"ok": false}`) would otherwise always count as success. Dotted path traverses objects and array indices, e.g. `'reports.0.ctx.success=true'`. Repeat the flag for multiple assertions — all must pass. `VALUE` is parsed as JSON when possible (`true`/`false`/`null`/numbers), else compared as a literal string, so `--assert-json 'status=ok'` works without shell-quoting JSON. Only evaluated when the status code already matched `expected_status` — a status mismatch is already a failure on its own. Applies globally to every response in the run, not per-endpoint; a HAR with structurally different endpoint responses may need a field common to all of them, or should skip this flag. |
| `--think-time` | `none` | `none` \| `real` \| `scaled` | CLI + jac.toml | Inter-request delay between HAR entries. `none` = no delay (maximum stress). `real` = wait the recorded `timings.wait` ms. `scaled` = same as `real` but multiplied by `--think-time-scale` (useful to run faster or slower than recorded). |
| `--think-time-scale` | `1.0` | Float, e.g. `0.5`, `2.0` | CLI + jac.toml | Multiplier applied to recorded think times when `--think-time real`. Values below `1.0` speed up pacing; values above `1.0` slow it down. |
| `--include-static` | `false` | Boolean flag (no value) | CLI + jac.toml | By default, image/*, font/*, text/css, and JS bundle entries in the HAR are skipped. Pass this flag to replay everything including static assets. |
| `--infra-block-threshold` | `3` | Positive integer | CLI + jac.toml | How many distinct endpoints must return a byte-identical non-JSON body in one 10s window before those responses are classified `INFRA_BLOCK_SUSPECTED` instead of application errors. Below 2 disables it. See § Infrastructure blocks. |
| `--proxy-pool` | none | Path to a file of proxy URLs | CLI + jac.toml | Spread egress across proxies (`http://` or `socks5://`, one per line). Assigned per VU, so each VU keeps one address and keep-alive still works. Partial mitigation for per-IP rate limits. |
| `--param` | none | `"<endpoint>.<target>=<file>"` | CLI | Feed a body, query or header field from a file of values instead of replaying the recorded one. Target is `body.<json-path>`, `query.<name>` or `header.<name>`. File is one value per line, `file.csv:column` for a named CSV column, or a `.json` list. Rows advance by `(vu_id, iteration)`. Repeatable. See § Varying the data below. |
| `--accounts` | none | Inline JSON map, JSON array, or path to `.json`/`.csv` | CLI + jac.toml | Per-VU account pool — each VU logs in as its own identity and replays with its own token, so N VUs exercise N root graphs instead of contending on one. Accounts are assigned round-robin when VUs outnumber them (warned once). One login per distinct account, on the controller, before the replay loop. An account that does not exist is registered and the login retried — see § Accounts below. **Passwords in an inline map land in shell history and `ps` output**; use a file for anything beyond a local run. |
| `--skip-failed-accounts` | off (a failure **aborts**) | Boolean flag (no value) | CLI + jac.toml | Continue when some accounts cannot authenticate. VUs are re-spread over the accounts that did, so the requested concurrency is preserved and only identity diversity drops; each failure is named on stderr and the run is flagged in the report. Still aborts if no account authenticates. |
| `--register-path` | `/user/register` | URL path | CLI + jac.toml | Endpoint used to create an account that does not exist yet. Only reached after a login 401s *and* the account is confirmed missing. |
| `--no-auto-register` | off (registration **on**) | Boolean flag (no value) | CLI + jac.toml | Never create accounts. A login failure for a missing account is reported as a failure instead. |
| `--correlate` | none | `"Producer.response.<path> -> Consumer.body.<path>"` | CLI | Thread a value from one response into a later request, per VU. Endpoints may be named by walker (`AddTodo`) or full path (`/walker/AddTodo`). Source accepts `response.<json-path>` or `header.<name>`; target accepts `body.<json-path>`, `query.<name>` or `path`. Repeatable. Wins over automatic detection for the same producer/consumer pair. Use it for correlations the scan cannot see — typically a value the recording uses only once, so there is no second occurrence to match against. |
| `--no-auto-correlate` | off (detection is **on**) | Boolean flag (no value) | CLI + jac.toml | Turn off automatic correlation detection and replay request bodies exactly as recorded. See § Correlation below for what detection does and when you would want it off. |
| `--csrf` | `false` | Boolean flag (no value) | CLI + jac.toml | Detects a CSRF cookie (`csrftoken` or `_csrf`) on any response and injects it as an `X-CSRFToken` header on subsequent non-GET requests, per VU. The stored value rotates automatically if a later response sets a new cookie value. Useful when the target sits behind a reverse proxy that adds CSRF protection (jac-scale itself uses JWT, not CSRF). |

---

## Authentication

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--username` | — | String | CLI only | Username for auth. All VUs log in with this identity and get separate JWT tokens. **Security-sensitive — never put in jac.toml.** |
| `--password` | — | String | CLI only | Password paired with `--username`. **Security-sensitive — never put in jac.toml.** |
| `--login-path` | `/user/login` | URL path string | CLI + jac.toml | Path used to detect the login entry in the HAR. This entry is handled by the auth module and not replayed directly. |

---

## Microservice Mode

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--services-map` | — | JSON string, e.g. `'{"svc":"http://host:port"}'` | CLI only | Explicit service name → URL mapping. Bypasses `jac.toml` auto-discovery entirely. Required when running in `--mode microservice` without a `jac.toml` in the current directory (e.g. CI, remote hosts). Environment-specific — CLI only. |

---

## CI Thresholds

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--fail-on-error-rate` | — (disabled) | Float (percent), e.g. `1.0` | CLI + jac.toml | Exit with code `1` if the overall error rate exceeds N percent. `1.0` means "fail if more than 1% of requests return non-2xx or network errors". Printed to stderr as `THRESHOLD FAILED: error_rate X% > limit N%`. |
| `--fail-on-p95` | — (disabled) | Float (ms), e.g. `500`, or `ENDPOINT:ms`, e.g. `/healthz/live:100` — repeatable | CLI + jac.toml (bare form only) | Exit with code `1` if a p95 latency exceeds N milliseconds. A bare number sets the global threshold, checked against all traffic combined — unchanged from before per-endpoint scoping existed. `ENDPOINT:ms` instead scopes the threshold to that one endpoint's own p95 (matched against the endpoint string as it appears in the report), most useful for `--health-check`'s side-channel endpoint so it can be gated without diluting, or being diluted by, the rest of the traffic mix. At most one bare value is allowed; combine it with any number of scoped ones by repeating the flag. Only the bare form is read from `jac.toml`; scoped values are CLI-only. |
| `--fail-on-p99` | — (disabled) | Same as `--fail-on-p95` | CLI + jac.toml (bare form only) | Exit with code `1` if a p99 latency exceeds N milliseconds. See `--fail-on-p95` for the bare-value / scoped `ENDPOINT:ms` form. |
| `--abort-on-fail` | `false` | Boolean flag (no value) | CLI + jac.toml | Stop the test immediately when any threshold is first breached, rather than waiting for all iterations. A partial report is generated from data collected so far. |
| `--threshold-start-delay` | `0s` | Time string: `30s`, `1m` | CLI + jac.toml | Defer threshold evaluation until N seconds into the run. Metrics are collected from t=0 and appear in the report — only the pass/fail check is delayed. Useful to skip cold-start latency spikes. |
| `--apdex-t` | `500` | Float (milliseconds), e.g. `300` | CLI + jac.toml | Apdex satisfaction threshold T, in ms. A request is *satisfied* if `latency_ms <= T`, *tolerating* if `T < latency_ms <= 4T`, and *frustrated* otherwise (or on error). Apdex score = `(satisfied + 0.5 * tolerating) / total`, shown per-endpoint and globally in every report format. |

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | Test completed; all thresholds passed (or none configured) |
| `1` | One or more thresholds failed |
| `2` | Tool or config error (bad HAR, missing required flag, auth failure, invalid flag value) |

---

## Output

| Flag | Default | Expected Value | Use in | Description |
|------|---------|----------------|--------|-------------|
| `--report-format` | `console` | `console` \| `json` \| `html` | CLI + jac.toml | Output format. `console` prints a Rich table to stderr. `json` writes machine-readable output to stdout (or `--report-out`). `html` writes a self-contained HTML file with charts — requires `--report-out`. |
| `--report-out` | — | File path, e.g. `results.html` | CLI only | Output file path for `json` or `html` reports. Output path changes per run — CLI only. |
| `--max-samples` | `1000000` | Positive integer | CLI + jac.toml | Maximum raw request records kept in memory for percentile calculation. Oldest records are dropped when this limit is reached. `1,000,000` is sufficient for most runs under several hours. |
| `--debug` | `false` | Boolean flag (no value) | CLI only | Print one line per request to stderr: `[VU NNN] /endpoint  STATUS  latency_ms ms`. Useful for verifying replay is hitting the right endpoints. Do not use in CI — output is very verbose with many VUs. |
| `--slo` | — | JSON string, e.g. `'{"/walker/chat": {"p95": {"good": 2000, "bad": 8000}}}'` | CLI only | Per-endpoint latency SLO overrides for report ratings (Good/Acceptable/Bad). Without this, every endpoint is judged against the same built-in bar (`p50` good&lt;100ms/bad&gt;500ms, `p95` good&lt;500ms/bad&gt;2000ms, `p99` good&lt;1000ms/bad&gt;5000ms, `p999` good&lt;2000ms/bad&gt;10000ms) — unfair to both a fast health-check endpoint and a slow LLM-backed one judged the same way. Keys are endpoint strings as they appear in the report; metrics/endpoints not listed keep the global default. Validated before the run starts — invalid JSON or `good >= bad` fails fast with a clear error. |

---

## jac.toml Example

Settings appropriate for team-wide defaults can be committed in `jac.toml`. CLI flags always override these.

```toml
[plugins.scale.loadtest]
# Load shape
vus                   = 20
workers               = 4          # worker processes (default: CPU core count)
ramp_up               = "10s"
timeout               = "30s"
mode                  = "monolith"

# Traffic
think_time            = "none"
rps                   = 0          # 0 = unlimited
include_static        = false

# Auth
login_path            = "/user/login"

# CI thresholds (team SLOs)
fail_on_error_rate    = 1.0        # percent
fail_on_p95           = 500        # ms
fail_on_p99           = 1000       # ms
threshold_start_delay = "30s"

# Output
report_format         = "console"
max_samples           = 1000000
```

**Flags intentionally excluded from jac.toml** (CLI only):

| Flag | Reason |
|------|--------|
| `har_file` | Positional arg, different every run |
| `--url` | Changes between dev / staging / prod |
| `--username` / `--password` | Security-sensitive — never commit |
| `--services-map` | Environment-specific URL overrides |
| `--report-out` | Output path changes per run |
| `--debug` | Too noisy for committed defaults |

---

## Quick Examples

```bash
# Minimal: 1 VU, 30s
jac x loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 50 --ramp-up 10s

# Realistic pacing from recorded think times
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --think-time real

# Microservice mode (reads routing from jac.toml)
jac x loadtest recording.har --mode microservice --vus 30

# Microservice mode with explicit service URLs (no jac.toml needed)
jac x loadtest recording.har --mode microservice \
  --services-map '{"order_service":"http://order.svc:8001","inventory_service":"http://inv.svc:8002"}' \
  --vus 30

# CI gate: fail if p95 > 500ms or error rate > 1%
jac x loadtest recording.har --url http://staging:8000 \
  --vus 10 --fail-on-p95 500 --fail-on-error-rate 1 --threshold-start-delay 10s

# HTML report
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --report-format html --report-out results.html

# JSON report
jac x loadtest recording.har --url http://localhost:8000 \
  --vus 10 --report-format json --report-out results.json
```

---

## Planned flags (roadmap — not yet implemented)

These are scheduled in [`COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md). Listed here so the
intended surface is visible; **none of the flags below work today.**

> **This list previously included several flags that have since shipped** —
> `--accounts`, `--param`, `--infra-block-threshold`, `--proxy-pool`, `--no-body-check`,
> `--check-shape`/`--fail-on-shape-drift`, `--step-load`, `--abort-on-fail`, the scoped
> `ENDPOINT:ms` form of `--fail-on-p95`/`--fail-on-p99`, and `--health-check` are all
> implemented; see the full flag reference above for each one's current behavior. They have
> been removed from the tables below so this section reflects only what is still missing.

### Phase 7 — Multi-User Realism

| Flag | Purpose |
|------|---------|
| `--think-time gaussian` / `--think-time-stddev` / `--think-time-jitter P` | Randomized inter-request delay. (`--think-time` today supports `none`, `real`, and `scaled` only — see above.) |
| `--persona-file personas.json` | Split load across manually-defined user archetypes (name, description, entry indices, VUs). Mutually exclusive with `--vus`. |

### Phase 8 — Result Fidelity & Regression Gating

| Flag | Purpose |
|------|---------|
| `--assert-json "/walker/AddTodo:reports.0.id=*"` | Per-endpoint response assertion (scoped form of the existing global `--assert-json`, which today applies to every response in the run). |
| `--baseline prev.json` | Load a prior JSON report for comparison. |
| `--fail-on-regression "p95:10%,error_rate:0.5pp,rps:-10%"` | Exit 1 when a metric regresses past tolerance vs. `--baseline`. |

### Phase 9 — GraphQL & WebSocket (remaining)

| Flag | Purpose |
|------|---------|
| `--ws-scenario ws.json` | Run a user-authored WebSocket scenario (connect URL, subprotocol, VUs, ordered message list) — works when the HAR has no captured frames. Repeatable; merges with HAR auto-detected scenarios. |
| `--graphql-scenario sub.json` | Same, for a GraphQL subscription scenario. |

Also planned: a clearer "no frames to replay" warning. (Multiprocess support for
WebSocket/GraphQL scenarios has shipped — there is no longer a `--workers 1` restriction.)

### Phase 10 — Auth Adapters & Authoring

| Flag / command | Purpose |
|------|---------|
| `--auth-type {jac-scale\|bearer\|basic\|apikey\|oauth2-cc\|none}` | Select the auth adapter. |
| `--auth-header NAME` / `--auth-value VALUE` | Static API-key / bearer injection. |
| `--auth-token-path PATH` | Override the login-response JSON path (default `data.token`). |
| `--auth-body-template FILE` | JSON template for a non-standard login request body. |
| `--auth-adapter pkg.mod:Class` | Import a custom auth adapter class. |
| `jac x loadtest record --port 8080 --out r.har [--scope URL]` | Built-in forward-proxy recorder — no DevTools export. |
| `jac x loadtest from-spec openapi.yaml --out r.har` | Generate a HAR-compatible entry list from an OpenAPI 3.0/3.1 or Swagger 2.0 document. |

### Phase 11 — Distributed Load Generation

| Flag / command | Purpose |
|------|---------|
| `jac x loadtest worker --port N [--discover]` | Run a worker node. |
| `--worker-nodes [region:]host:port,...` | Controller — split VUs across nodes, merge metrics, group latency by region. |

### Phase 12 — Observability & Release

| Flag | Purpose |
|------|---------|
| `--output {prometheus\|influxdb\|otlp}` / `--output-url URL` | Stream live metrics to an external sink alongside the normal report. |
| `--report-format junit` | JUnit XML report for Jenkins / GitLab / Azure DevOps. |
