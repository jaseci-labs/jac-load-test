# jac-loadtest Constraints and Design Decisions

This document records the known constraints of `jac-loadtest`, explains why the current approach is correct within its scope, and maps out the future enhancements that address each limitation.

> **Roadmap cross-reference.** The enhancements below are scheduled in
> [`COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md):
> §1 (session diversity) and §2 (parameterization) → **Phase 7**;
> §5 (per-endpoint assertion) and §6 (single-source IP) → **Phase 8**;
> §7 (WebSocket frame capture) → **Phase 9 remaining + Phase 10b**;
> §4 (pluggable auth) → **Phase 10**;
> §3 (VU ceiling) → **Phase 11** (native distributed generation; the `--engine k6` idea is
> dropped — see §3).

---

## 1. HAR Session Diversity (Multi-User Data Problem)

### Current Approach

A HAR file is a recording of one user's browser session. `jac-loadtest` replays that recording across N virtual users (VUs) concurrently. Each VU sends the same sequence of requests with the same request bodies that were captured at record time.

Authentication happens exactly **once per run, not once per VU**: `AuthProvider.authenticate()` is awaited a single time before the replay loop starts (`core/engine.jac`'s `run_all_vus`, and `core/process_runner.jac`'s `_pre_authenticate_all` in multiprocess mode), and the single resulting JWT is copied to every VU. `authenticate()` does accept a `vu_id` parameter, but it is only used in the `AuthenticationError` message text — it does not cause a separate login call per VU. The original recorded token is stripped and never replayed; the one shared token is injected as `Authorization: Bearer <token>` on all subsequent requests for all VUs.

Credentials are supplied via `--username`/`--password`. All VUs share the same account — the account used when the HAR was recorded — and, as a consequence of the single shared login, they also share the same token.

### Why This Is Good

- **Zero scripting.** The HAR file is the entire test script. No test code to write or maintain.
- **Correct for throughput testing.** When the goal is measuring server capacity under concurrent load (RPS, latency, error rate), replaying the same sequence from N VUs is valid and sufficient. The server handles N concurrent identical workloads — the bottleneck is real.
- **One login call regardless of `--vus`.** Ramping up VU count doesn't multiply login traffic against the target's auth endpoint.

### Known Limitation: Shared Token, Not Per-VU Tokens

Because every VU replays with the *same* token instead of authenticating independently:

- **No re-authentication on expiry.** The token is fetched once at t=0 and never refreshed. A soak test that runs longer than the JWT's lifetime will degrade into 100% auth failures partway through, with no automatic recovery.
- **Single-user contention, not multi-user contention.** On jac-scale, every request executes against the authenticated user's own root graph. Sharing one token across N VUs means all N VUs serialize on that one user's graph — this measures single-user contention under concurrent load, not the multi-user scalability profile a real production traffic mix would exercise.

If either of these matters for your test (long soak runs, or multi-user contention modeling), be aware the current implementation does not provide it despite `authenticate()`'s `vu_id` parameter suggesting per-VU support exists.

**Scheduled fix — Phase 7b.** `--accounts accounts.csv` gives each VU its own identity and
its own token (authenticated once on the controller before the replay loop, same pre-fork
model as today's single login), and a mid-run `401` triggers one automatic re-login + retry
per VU. Together with response correlation (below) this makes true multi-user replay work.

### The Problem

jac-scale walkers that operate on existing nodes embed the node ID in the request body:

```json
POST /walker/ToggleTodo
{"nd": "a3f7c2d1-9f4b-4e2a-b123-..."}
```

This node ID was captured at record time and belongs to the user who made the recording. When a different user replays the HAR with their own token, the server correctly rejects the request — the node exists in the database but is owned by a different account.

The token substitution is working correctly. The problem is not auth — it is that the **request body payloads are static snapshots** of one user's data at one point in time. No amount of credential rotation fixes this because the node IDs themselves are the issue.

Example of what happens during replay with different credentials:

```
Recording (sahan):
  AddTodo    → server creates node "a3f7c2d1" for sahan
  ToggleTodo → body: {"nd": "a3f7c2d1"}   ← captured at record time

Replay (alice, valid token):
  AddTodo    → server creates node "ff91b823" for alice  ✅
  ToggleTodo → body: {"nd": "a3f7c2d1"}   ← still sahan's ID  ❌ 404/403
```

The HAR replay engine has no knowledge of the relationship between `AddTodo`'s response and `ToggleTodo`'s request body. It replays bytes, not semantics.

### Practical Guidance (Current)

| Scenario | Works? | Guidance |
|---|---|---|
| Throughput / latency measurement | ✅ | Use same credentials the HAR was recorded with |
| Auth correctness (token injection, cookie jar) | ✅ | Supply `--username`/`--password` matching the recording |
| Mixed create + update/delete workflows | ✅ | Use the same credentials as the recording; node IDs match |
| Pure create-only or read-only workflows | ✅ | Single credential is sufficient |

### Why CSV Credentials Cannot Fix the Node ID Problem

A common first instinct is to supply multiple accounts so that different VUs replay with different user identities. Even with per-VU account diversity the HAR node ID problem remains unsolved:

- VU 0 replays with alice's token but sends `{"nd": "a3f7c2d1"}` — a node belonging to sahan (the recording user). The server rejects it.
- VU 1 replays with bob's token and sends the same `{"nd": "a3f7c2d1"}`. Same rejection.

The credential column is orthogonal to the request body column. Rotating tokens does not rotate the node IDs embedded in the request payloads. Every VU fails the same requests for the same reason, just under different names.

**This is why per-VU accounts and response correlation ship together in Phase 7.** Account
diversity alone (`--accounts`) fixes identity but not the stale node IDs; correlation alone
fixes the IDs but leaves every VU on one graph. With both, VU 0 logs in as `alice`, creates
*her own* todo, and toggles the ID *she* just received. Until Phase 7 lands, use the same
`--username` / `--password` as the recording user — the only mode that avoids ownership-check
failures for mixed workflows, and correct and sufficient for pure throughput/latency
measurement.

### Future Enhancement: Response Correlation — Phase 7a

The correct long-term solution is **response correlation** — automatically extracting a value from one response and injecting it into a subsequent request body before sending.

For the Todo example:

```
After AddTodo response:
  extract: data.id → stored as $todo_id

Before ToggleTodo request:
  replace: body.nd = $todo_id
```

This would allow multi-user replay to work correctly: each VU creates its own todo and then operates on the ID it just received, not the ID from the recording.

**Implementation options (future):**

1. **Explicit annotation via CLI flag:**
   ```
   --correlate "AddTodo.response.data.id → ToggleTodo.body.nd"
   ```
   User declares the extraction rule. Tool applies it at runtime per VU. Simple to implement; requires user knowledge of the response shape.

2. **Automatic detection:**
   Scan HAR response bodies for values that also appear in subsequent request bodies. Treat matches as correlation candidates and substitute them at runtime. No user input required, but heuristics may produce false positives.

3. **Annotated HAR format:**
   Extend the HAR with a `x-jac-correlate` custom field per entry. Users annotate the HAR once; the tool honours the annotations on every run. Most explicit and reliable.

**Phase 7a ships options 1 and 2 together:** `--correlate "AddTodo.response.reports.0.id ->
ToggleTodo.body.nd"` for the explicit rule, and `--correlate-scan` — a single no-load
baseline pass that finds values which appear in a response and then reappear in a later
request, and prints ready-to-paste `--correlate` flags for each. Option 3 (the
`x-jac-correlate` HAR annotation) is also supported for teams that prefer to annotate a HAR
once and commit it. This stays consistent with the zero-scripting philosophy — the flag is a
narrow annotation, not a script.

---

## 2. Static Request Bodies (Parameterization)

### Current Approach

Request bodies are replayed exactly as recorded. Query values, filter strings, pagination offsets, and all other body fields are identical across every VU and every iteration.

### Why This Is Good

- Predictable, reproducible results. Every run is identical in terms of what is sent to the server.
- No setup required. There are no data files to prepare beyond the HAR itself.
- Cache hit patterns are consistent across runs, making benchmarks comparable.

### The Problem

Identical request bodies across all VUs may produce unrealistically warm server-side cache hits. A search query that always sends `{"q": "hello"}` will hit the same cache entry every time, producing latency results lower than real-world usage where queries are diverse.

For write operations, replaying the same payload repeatedly may also cause uniqueness constraint violations (e.g. creating a resource with the same name twice).

### Future Enhancement: CSV Parameterization — Phase 7c

Allow users to supply a CSV file of values to substitute into request bodies:

```bash
jac x loadtest recording.har --url http://localhost:8000 \
  --param "AddTodo.body.title=titles.csv"
```

`titles.csv`:
```
Buy milk
Call dentist
Fix the CI
```

VU 0 uses row 0, VU 1 uses row 1, wrapping around — equivalent to JMeter's CSV Data Set
Config and k6's `SharedArray`. Phase 7c also adds inline substitution tokens usable anywhere
in a body/query/header value — `{{vu_id}}`, `{{iter}}`, `{{uuid}}`, `{{randint:a,b}}`,
`{{now}}`, `{{account.<col>}}`, `{{env.<VAR>}}` — so uniqueness constraints and cache-buster
diversity are covered without a CSV file for the simple cases. When `--accounts` is set, the
`--param` row follows the VU's account-pool row so a VU's data stays internally consistent.

---

## 3. Python asyncio VU Ceiling

### Current Approach

VUs run as `asyncio` coroutines. When `--workers N` is set (default: CPU core count), the tool spawns N separate OS processes via `multiprocessing.get_context("spawn")`, each running its own asyncio event loop with an equal slice of the total VU count. Worker results are merged into a single `MetricsCollector` before reporting.

Each worker is capped at `min(--workers, --vus, cpu_count)` to prevent spawning idle processes or OOM-crashing the machine. The CPU cap is enforced automatically with a warning when the requested `--workers` count exceeds available cores.

### Why This Is Good

- **GIL is bypassed.** Each worker process is a separate Python interpreter with its own GIL. CPU-bound work (metrics recording, latency arithmetic) in one worker does not block others.
- **Practical VU ceiling is multiplied.** A 4-core machine can sustain `4 × 200–500 VUs ≈ 800–2000 VUs` before event loop overhead becomes the bottleneck — sufficient to saturate most dev and staging servers.
- **Single-machine simplicity is preserved.** No distributed coordination, no external scheduler, no message bus. The subprocess fan-out and merge are handled transparently by `core/process_runner.jac`.
- **Credentials are pre-distributed.** Auth is performed centrally before forking. Each worker receives its slice of the credential-to-token map, so no worker needs to call the login endpoint independently.

### Remaining Limitation

Beyond `cpu_count × ~500 VUs`, the per-process event loop overhead accumulates faster than the network I/O savings. At this scale the bottleneck is the load generator itself, not the target server. The GIL-free asyncio ceiling per process cannot be raised without switching to a non-CPython runtime.

### Future Enhancement: Native Distributed Generation — Phase 11

For VU counts beyond one machine, `jac-loadtest` adds a controller/worker model rather than
shelling out to another load generator:

- `jac x loadtest worker --port N` — a lightweight `aiohttp` server that runs
  `run_multiprocess()` locally on a POSTed config + HAR.
- `--worker-nodes [region:]host:port,...` on the controller — splits `--vus` across nodes
  (each gets a `vu_id_offset` for globally unique IDs), pre-authenticates the account pool
  centrally, streams and merges every node's metrics into one report, and groups per-node
  latency by an optional `region:` label.
- mDNS discovery (`--discover`) so nodes on a LAN self-register.

**The `--engine k6` idea is dropped.** A k6 shim would fork the report format, the jac-scale
auth bridge, and the metrics pipeline into a second code path that has to be kept in sync
forever. `cpu_count × ~500` per machine, multiplied across cheap worker nodes, covers the
realistic range — and the distributed nodes' distinct source IPs also address the
single-source-IP problem in §6.

---

## 4. Authentication Coupled to jac-scale Auth Format

### Current Approach

Authentication is handled by `bridge/auth.jac` (`AuthProvider.authenticate`). When `--username`/`--password` is provided, the tool performs a login call before the replay loop and injects the resulting token as `Authorization: Bearer <token>` on every subsequent request.

Both the login request payload and the response parsing are hardcoded to match jac-scale's specific auth protocol:

**Request payload (always sent as JSON):**
```json
{
  "identity": {"type": "email", "value": "user@example.com"},
  "credential": {"type": "password", "password": "secret"}
}
```

**Response parsing (always extracts this path):**
```python
body["data"]["token"]
```

**Token injection (always this header):**
```
Authorization: Bearer <token>
```

The `--login-path` flag allows overriding the endpoint path (default: `/user/login`), but the payload shape and response shape are not configurable.

### Why This Is Good

- Zero configuration for jac-scale apps. No auth setup step needed — point at a jac-scale server, supply credentials, and it works.
- Fresh tokens per run. Auth happens before the replay loop, so tokens are live for the entire test duration with no expiry risk.
- Pre-fork auth. In multiprocessing mode (`--workers N`), all tokens are acquired before forking. Workers receive their credential slice as a plain dict — no login endpoint traffic during the load phase itself.

### The Problem

Any server that does not use jac-scale's exact auth contract is unsupported:

| Auth style | Supported? |
|---|---|
| jac-scale `POST /user/login` → `{"data": {"token": "..."}}` | ✅ |
| Different JSON login response shape (e.g. `{"access_token": "..."}`) | ❌ |
| Different JSON login request body shape | ❌ |
| Static API key (`X-Api-Key` header or `?api_key=` query param) | ❌ |
| HTTP Basic Auth | ❌ |
| OAuth 2.0 client credentials flow | ❌ |
| Cookie-based session (no `Authorization` header) | ❌ |
| No auth (public endpoints) | ✅ (omit `--username`/`--password`) |

This means `jac-loadtest` cannot currently load test non-jac-scale services that require auth, and cannot be used against a jac-scale server that has customised its auth response envelope.

### Future Enhancement: Pluggable Auth Adapters — Phase 10a

The `AuthProvider` class in `bridge/auth.jac` is already the single point of responsibility for all auth logic. Adding a pluggable adapter interface there would address all the unsupported cases without changing the engine or reporter.

> This constraint is **accepted as low-priority**: the tool's primary job is testing
> jac-scale apps, which use exactly the supported auth contract. Phase 10a broadens it
> mainly so a jac-scale server with a customised auth envelope, or a non-jac-scale
> microservice in the same test, isn't blocked.

**Option 1 — Auth profile flags (simplest):**
```bash
# API key
jac x loadtest recording.har --auth-type apikey --auth-header "X-Api-Key" --auth-value "abc123"

# Basic auth
jac x loadtest recording.har --auth-type basic --username alice --password secret

# Custom login response path
jac x loadtest recording.har --auth-token-path "access_token"
```
`AuthProvider` reads `--auth-type` and branches to the correct adapter. The engine and process_runner stay unchanged.

**Option 2 — Auth adapter plugin (most flexible):**
Allow a Python module path as `--auth-adapter mypackage.auth:MyAdapter`. The tool imports and instantiates it, calling `await adapter.authenticate(vu_id, session, base_url) -> str`. This gives complete freedom over the auth flow for any target server.

Option 1 covers the most common cases with no code beyond the existing CLI. Option 2 is the escape hatch for anything unusual.

---

## 5. Optional Response Assertion (`--assert-json`)

### Current Approach

By default the tool records HTTP status codes and measures latency only — a request that returns HTTP 200 with an error payload (`{"ok": false, "error": "node not found"}`) counts as a success. This is deliberate (see "Why This Is Good" below), but for jac-scale apps a walker returning `{"ok": false}` with status 200 is a silent application-level error worth catching, so an *optional* `--assert-json PATH=VALUE` flag exists to close that gap without forcing functional-correctness checks on every user.

`--assert-json` requires a JSON response-body field to equal a value for a request to count as successful, in addition to the status code. Syntax is a flat `PATH=VALUE` pair, not a boolean expression: `--assert-json 'ok=true'`. The path traverses nested objects and array indices with dots, e.g. `--assert-json 'reports.0.ctx.success=true'`. `VALUE` is parsed as JSON when possible (`true`/`false`/`null`/numbers), else compared as a literal string. The flag is repeatable — all given assertions must pass. Responses that fail get `error_type="ASSERTION_FAILED: '<path>' expected <value>"` (or `... missing from response` / `... response body is not valid JSON`), which flows through the normal error-count and error-breakdown pipeline with no other reporting changes needed. Implemented in `core/engine.jac` (`parse_assert_json`, `_check_json_assertions`); see `docs/COMMANDS.md` for full flag documentation.

### Why This Is Good

Load testing is about performance, not functional correctness. Asserting on response bodies is primarily the responsibility of integration tests (e.g. `pytest` with `aiohttp.test_utils`). `--assert-json` stays opt-in and narrow (one flat field-equality check, not a scripting language) precisely so it doesn't turn into a second functional-test framework bolted onto a load-test tool — it exists only to stop an obviously-wrong `{"ok": false}` from silently reading as a passing run.

### Remaining Limitation

Assertions apply globally to every response in the run, not per-endpoint — a HAR replay whose endpoints have structurally different response shapes may need to pick a field common to all of them, or skip the flag. Assertions are also only evaluated when the status code already matched `expected_status`; a status mismatch is treated as the (sole) failure reason rather than layering a second one on top.

### Future Enhancement: Per-endpoint Assertions + Body-level Correctness — Phase 8b

Status-code checking answers "is the server up?", not "is it correct under load?" — and for
jac-scale, where walkers routinely return HTTP `200` with the failure inside the JSON body,
that second question is the one worth asking. Phase 8b adds:

- **Per-endpoint `--assert-json`** — scoping syntax mirroring `--slo`:
  `--assert-json "/walker/AddTodo:reports.0.id=*"`. The global form keeps working.
- **A jac-scale-aware default body check** (no config) — flags a `200` response that carries
  an `error`/`errors` key, an inner `status >= 400`, or an empty `reports` array where the
  recorded response for that endpoint had a non-empty one. Toggle with `--no-body-check`.
- **Baseline shape diffing** — the `--correlate-scan` pass records each endpoint's response
  shape; structural divergence under load is flagged as `SHAPE_DRIFT`.

---

## 6. Single Source IP (Infrastructure Blocks) — Issue #24

### Current Approach

Every VU — and, in multiprocess mode, every worker — egresses from the load generator's
single network interface. All load appears to the target as concurrent traffic from one
source IP.

### Why This Is Usually Fine

For load testing a jac-scale app in a dev, staging, or CI environment — the primary use
case — there is no WAF or edge rate limiter in the path, and a single source IP is exactly
what you want: it isolates the application and its datastore as the bottleneck, with no
network-layer variable in between.

### The Problem

When the target *is* behind a WAF, an API gateway rate limiter, or a CDN bot filter (common
for anything internet-facing), that layer sees hundreds of requests per second from one IP
and starts returning an identical non-JSON deny page — typically HTTP `403` or `429` with an
HTML body — for a fraction of requests. Today the engine classifies each of those as a
per-endpoint application error, so:

- the headline error rate is inflated by traffic the application never saw;
- the per-endpoint breakdown blames whichever endpoints happened to get blocked;
- p95/p99 for those endpoints are skewed by the fast deny-page responses.

The run looks like an application failure when it is really the generator tripping a network
control.

### Future Enhancement — Phase 8a

- **`INFRA_BLOCK_SUSPECTED` detection.** When byte-identical non-JSON response bodies appear
  across ≥ N distinct endpoints within one time bucket (`--infra-block-threshold N`, default
  3), classify them as infrastructure blocks: counted and reported *separately*, subtracted
  from the headline error rate, with a footnote naming the likely cause.
- **`--proxy-pool proxies.txt`.** Round-robin egress across an HTTP/SOCKS5 proxy list — a
  cheap partial mitigation.
- **Real multi-IP** comes from Phase 11's distributed workers, whose distinct source IPs
  spread the load below any per-IP threshold.

### Practical Guidance (Current)

| Situation | Guidance |
|---|---|
| Target in dev / staging / CI, no edge protection | No action needed — single IP is correct |
| Target behind a WAF / rate limiter you control | Allowlist the generator's IP for the test window |
| Target behind a CDN / WAF you don't control | Expect infra-block noise; sanity-check by re-running at low `--vus`; wait for Phase 8a/11 |

---

## 7. WebSocket Frame Capture (Chrome DevTools HAR Limitation)

### The Problem

`jac-loadtest` detects and replays WebSocket connections and GraphQL subscriptions found in a
HAR (`core/har_parser.jac` tags them, `ws_engine.jac` / `graphql_engine.jac` replay them).
Replaying a WebSocket connection means re-sending the message frames that were captured. Those
frames live in a **non-standard `_webSocketMessages` field** on the HAR entry.

**A Chrome DevTools "Save all as HAR with content" export does not write that field.** It
records that the WebSocket connection *happened* (the URL, the upgrade request) but includes
none of the frames sent over it. So a plain Chrome HAR gives the tool a WebSocket connection
with nothing to replay — the connection opens and then sits idle. Firefox, Postman, and
Insomnia HAR exports have the same gap.

Some recorders *do* capture frames: Playwright's HAR recorder (`recordHar` with `mode:
"full"`), mitmproxy, and anything driving Chrome over the DevTools Protocol
(`Network.webSocketFrameSent` / `Network.webSocketFrameReceived`).

When this happens today, the engine still detects the connection and replays it (opening it
counts as one sample), and prints a one-time stderr warning that there are no frames.

### Why This Is Not a Fundamental Limitation

The frames exist on the wire; only Chrome's *export* drops them. Capturing at a layer that
sees the raw traffic preserves them.

### Future Enhancement

Three complementary fixes, scheduled in [`COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md):

1. **Built-in proxy recorder (Phase 10b)** — `jac x loadtest record` is a mitmproxy-style
   forward proxy; it sees WebSocket frames (send and receive) and writes them into the HAR.
   This becomes the recommended way to record any test with WebSocket or subscription
   traffic. An optional `--via cdp` mode attaches to Chrome over the DevTools Protocol for
   full-fidelity capture with no MITM certificate.

2. **`--ws-scenario FILE` / `--graphql-scenario FILE` (Phase 9 remaining)** — a user-authored
   (or coding-agent-authored) scenario file describing the connect URL, subprotocol, VU
   count, and an ordered list of messages to send. Lets a WebSocket test run with no HAR
   frames at all. The engine internals (`WsScenarioConfig`, `parse_ws_scenarios()`,
   `run_ws_scenarios()`) already exist — this exposes them as CLI flags with a documented
   file format.

3. **Frame synthesis from schema (GraphQL only, Phase 9 remaining)** — when the HAR recorded
   a `graphql-ws` connection but not the `subscribe` frame, `introspect_schema()` plus the
   operation name (often present in an earlier HTTP request or the URL) is enough to
   generate a valid `subscribe` payload.

### Related: `--workers 1` Restriction for WebSocket / GraphQL

WebSocket and GraphQL scenarios currently run only in single-process mode (`--workers 1`);
mixing them with `--workers > 1` is rejected. This is an implementation shortcut — the
multiprocess runner (`core/process_runner.jac`) already splits VUs across processes and merges
protocol-tagged `RequestResult`s into one collector, so extending it to slice scenario VU
counts is mechanical work, scheduled in Phase 9's remaining list. It is **lower urgency** than
HTTP multiprocess: an idle WebSocket connection is cheap, so a single event loop holds a few
thousand concurrent subscriptions before saturating — for WebSocket the bottleneck is usually
message throughput, not connection count.

### Practical Guidance (Current)

| Situation | Guidance |
|---|---|
| Need to load test a WebSocket / subscription endpoint now | Record with Playwright's HAR recorder (`mode: "full"`) or mitmproxy instead of Chrome DevTools — both capture `_webSocketMessages` |
| HAR has the connection but no frames | Connection replay only measures connect latency; wait for `--ws-scenario` (Phase 9) or the proxy recorder (Phase 10b) for message replay |
| Need > ~1–2k concurrent active WebSocket VUs | Not supported yet — single-process ceiling applies until Phase 9 multiprocess work lands |
