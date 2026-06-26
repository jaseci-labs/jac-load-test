# jac-loadtest Constraints and Design Decisions

This document records the known constraints of `jac-loadtest`, explains why the current approach is correct within its scope, and maps out the future enhancements that address each limitation.

---

## 1. HAR Session Diversity (Multi-User Data Problem)

### Current Approach

A HAR file is a recording of one user's browser session. `jac-loadtest` replays that recording across N virtual users (VUs) concurrently. Each VU sends the same sequence of requests with the same request bodies that were captured at record time.

Authentication is handled per-VU: each VU independently calls `POST /user/login` and gets a fresh JWT token, which is injected as `Authorization: Bearer <token>` on all subsequent requests. The original recorded token is stripped and never replayed.

Credentials are supplied via `--username`/`--password` (all VUs share one account) or `--credentials-file creds.csv` (VU `i` uses row `i % len(rows)` — wrap-around assignment).

### Why This Is Good

- **Zero scripting.** The HAR file is the entire test script. No test code to write or maintain.
- **Correct for throughput testing.** When the goal is measuring server capacity under concurrent load (RPS, latency, error rate), replaying the same sequence from N VUs is valid and sufficient. The server handles N concurrent identical workloads — the bottleneck is real.
- **Token freshness is guaranteed.** Each VU authenticates independently before the replay loop. There is no token expiry risk during a long run since each VU holds its own live token.
- **`--credentials-file` works for create and read workflows.** If the request bodies do not reference ownership-tied IDs (e.g. a flow that only calls `AddTodo` and `ListTodos`), each VU can log in as a distinct user and the replay produces valid results for every user independently.

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
| Auth correctness (token injection, cookie jar) | ✅ | Any valid credentials work |
| Create-only workflows (`AddTodo` only) | ✅ | `--credentials-file` gives each VU its own account |
| Read-only workflows (`ListTodos`) | ✅ | `--credentials-file` gives each VU their own data view |
| Mixed create + update/delete workflows | ❌ | Must use the same credentials as the recording |
| Testing auth isolation (user A cannot see user B's data) | ✅ | Use `--credentials-file` and assert on 403 responses |

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
jac loadtest recording.har --url http://localhost:8000 \
  --param "AddTodo.body.title=titles.csv"
```

`titles.csv`:
```
Buy milk
Call dentist
Fix the CI
```

VU 0 uses row 0, VU 1 uses row 1, wrapping around — the same assignment strategy already used for credentials. This is equivalent to JMeter's CSV Data Set Config and k6's `SharedArray`.

---

## 3. Python asyncio VU Ceiling

### Current Approach

All VUs run as `asyncio` coroutines within a single OS thread. The GIL is never released for CPU-bound work (latency measurement, metrics recording).

### Why This Is Good

- For pure I/O-bound HTTP workloads, asyncio scales to approximately 200–500 concurrent VUs on a modern machine before event loop overhead becomes the bottleneck. This is sufficient for dev and staging load testing.
- Single-process execution means simple deployment — no worker coordination, no distributed state, no message bus.
- Metrics are collected in a single process with no aggregation step.

### The Problem

Beyond ~500 VUs, the Python event loop becomes the bottleneck rather than the target server. This makes it impossible to generate enough load to saturate a high-throughput production server from a single machine.

### Future Enhancement: k6 Backend

The architecture already reserves `--engine k6` as a future flag. When set, `jac-loadtest` converts the HAR to a k6 script and invokes the `k6` binary as a subprocess. k6 runs Go goroutines with no GIL constraint and handles tens of thousands of VUs from a single machine. The k6 results are parsed back into `jac-loadtest`'s JSON report format so the output is identical to the native engine.

---

## 4. No Response Assertion

### Current Approach

The tool records HTTP status codes and measures latency. A request that returns HTTP 200 with an error payload (`{"ok": false, "error": "node not found"}`) is counted as a success.

### Why This Is Good

Load testing is about performance, not functional correctness. Asserting on response bodies is the responsibility of integration tests (e.g. `pytest` with `aiohttp.test_utils`). Mixing the two concerns into one tool creates false confidence — a load test that also checks business logic is neither a good load test nor a good functional test.

### The Problem

For jac-scale apps, a walker that returns `{"ok": false}` with status 200 is a silent application-level error. The current tool has no way to distinguish this from a genuine success.

### Future Enhancement: Response Assertions

An optional `--assert-json "ok == true"` flag could allow users to declare a JSONPath condition that must hold for a response to be counted as a success. Responses that satisfy the assertion increment `success_count`; those that do not increment `error_count` with `error_type="ASSERTION_FAILED"`. This would surface jac-scale application-level errors in the report without requiring users to write test scripts.
