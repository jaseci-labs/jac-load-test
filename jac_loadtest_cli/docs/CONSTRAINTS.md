# jac-loadtest Constraints and Design Decisions

This document records the known constraints of `jac-loadtest`, explains why the current approach is correct within its scope, and maps out the future enhancements that address each limitation.

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

**For this reason `jac-loadtest` only supports a single `--username` / `--password` pair.** Using the same credentials as the recording user is the only mode that avoids ownership-check failures for mixed workflows. For throughput and latency measurement — the primary purpose of load testing — a single shared account is the correct and sufficient choice.

### Future Enhancement: Response Correlation

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

Option 1 is the most pragmatic first step. It is consistent with the zero-scripting philosophy (the HAR is still the test script; the flag is a narrow annotation, not a full script).

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

### Future Enhancement: CSV Parameterization

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

VU 0 uses row 0, VU 1 uses row 1, wrapping around — equivalent to JMeter's CSV Data Set Config and k6's `SharedArray`.

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

### Future Enhancement: k6 Backend

For extreme VU counts (tens of thousands), the architecture reserves `--engine k6` as a future flag. When set, `jac-loadtest` converts the HAR to a k6 script and invokes the `k6` binary as a subprocess. k6 runs Go goroutines with no GIL constraint and handles tens of thousands of VUs from a single machine. The k6 results are parsed back into `jac-loadtest`'s JSON report format so the output is identical to the native engine.

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

### Future Enhancement: Pluggable Auth Adapters

The `AuthProvider` class in `bridge/auth.jac` is already the single point of responsibility for all auth logic. Adding a pluggable adapter interface there would address all the unsupported cases without changing the engine or reporter.

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

## 5. Accepted Flags With No Effect

The following flag is parsed without error, stored in `LoadTestConfig`, and forwarded to worker processes — but no part of the engine, parser, or reporter currently reads it to change behaviour. Passing it is silently ignored.

| Flag | Config field | What was intended | Status |
|---|---|---|---|
| `--csrf` | `config.csrf` | Detect CSRF tokens in HAR responses and inject them into subsequent requests automatically | Not implemented — `engine.jac` and `har_parser.jac` never read `config.csrf` |

### Why This Flag Exists

`--csrf` was added to `LoadTestConfig` and the CLI parser during early design before the implementing code was written. It represents a genuine planned feature and is kept so that future `jac.toml` files and shell scripts that reference it do not break when the implementation lands.

### `--csrf` Future Implementation

CSRF token injection requires two new behaviours in the engine:

1. **Detection** — after each response, scan the body and headers for a CSRF token pattern (e.g. a cookie named `csrftoken`, a response header `X-CSRF-Token`, or a JSON field `"csrf_token"`).
2. **Injection** — before the next request, add the detected token as the appropriate header (e.g. `X-CSRFToken`) or replace the matching field in the request body.

This requires per-VU state (each VU holds its own CSRF token) and a detection heuristic or configurable token field name. The flag is the correct entry point; the implementation lives in `_send_request()` in `engine.jac`.

---

## 6. No Response Assertion

### Current Approach

The tool records HTTP status codes and measures latency. A request that returns HTTP 200 with an error payload (`{"ok": false, "error": "node not found"}`) is counted as a success.

### Why This Is Good

Load testing is about performance, not functional correctness. Asserting on response bodies is the responsibility of integration tests (e.g. `pytest` with `aiohttp.test_utils`). Mixing the two concerns into one tool creates false confidence — a load test that also checks business logic is neither a good load test nor a good functional test.

### The Problem

For jac-scale apps, a walker that returns `{"ok": false}` with status 200 is a silent application-level error. The current tool has no way to distinguish this from a genuine success.

### Future Enhancement: Response Assertions

An optional `--assert-json "ok == true"` flag could allow users to declare a JSONPath condition that must hold for a response to be counted as a success. Responses that satisfy the assertion increment `success_count`; those that do not increment `error_count` with `error_type="ASSERTION_FAILED"`. This would surface jac-scale application-level errors in the report without requiring users to write test scripts.
