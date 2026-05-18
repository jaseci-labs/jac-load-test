# jac-loadtest — Introduction

## The Problem: Current Load Testing Methods Are Not Built for Jac Users

jac-scale developers who want to load test their apps today have three realistic options — all of them have a friction problem:

1. **JMeter** — heavy Java GUI tool; you build XML test plans through a visual editor, requires a separate install, steep learning curve, and has nothing to do with how Jac apps are structured.

2. **k6** — write your test scenario as a JavaScript file; separate binary to install, no concept of jac-scale's auth (`/user/login` + JWT), no awareness of microservice topology.

3. **Locust** — write Python test classes inheriting from `HttpUser`; still requires learning Locust's specific API patterns, and again no jac-scale awareness.

The shared pain across all three: you have to write a *script* that describes your app's behavior from scratch — even though you already recorded exactly that behavior in your browser.

---

## What We Decided

Use the HAR file (HTTP Archive) as the test script. Chrome DevTools already produces a precise recording of every HTTP request your app made during a session. Instead of translating that into Locust/k6 scripting, feed it directly to the tool. **Zero scripting.**

---

## Implementation Options Considered

Four ways to deliver `jac loadtest`:

| Option | Description | Why We Rejected It |
|--------|-------------|-------------------|
| **A — jac-scale plugin (native)** | Code lives inside jac-scale from day one | Slows iteration; requires PRs into the main jac-scale repo for every change |
| **B — Admin portal integration** | Load generation tied to the running server | Noisy-neighbor risk; the tool under test also generates load |
| **C — Standalone microservice** | Deployed as a separate service | Dev/test tool with deployment overhead — overkill |
| **D — Truly standalone** | Completely independent tool, no jac-scale knowledge | Loses auth integration (`/user/login` + JWT) and microservice topology awareness |

**We chose a hybrid:** standalone PyPI package that is jac-scale-aware from day one, designed to migrate cleanly into jac-scale later.

---

## Why This Approach

Three key properties:

**1. `jac loadtest` from day one.**
Registers as a `jac` subcommand via `[project.entry-points."jac"]`, the same mechanism jac-scale itself uses. `pip install jac-loadtest` and the command appears alongside `jac start`, `jac deploy`, etc. No separate binary.

**2. Core isolation.**
`core/` (parser, engine, metrics) has zero jac-scale knowledge — it works against any HTTP server. The jac-scale-specific logic (auth, microservice routing) lives in a thin `bridge/` layer on top. This makes the tool independently testable and means migration later is a file move, not a rewrite.

**3. jac-scale aware where it matters.**
The `bridge/` layer speaks jac-scale natively: knows the `/user/login` request shape, knows how to read `jac.toml` for service topology, mirrors `ServiceRegistry.match_route()` for microservice routing.

---

## Ultimate Goal

**Two stages:**

**Stage 1 — Standalone PyPI package** (`pip install jac-loadtest`)
Delivers `jac loadtest` immediately. Iterated fast outside the main jac-scale repo.

**Stage 2 — Native jac-scale integration** (`pip install jac-scale[loadtest]`)
Code moves into jac-scale. The `bridge/` adapters gain in-process access to jac-scale internals — no more HTTP calls for auth, no more disk reads for topology. The command name never changes. Users see nothing different.

---

## Steps We Follow

| Phase | What Gets Built | Exit Criterion |
|-------|----------------|----------------|
| **0 — Foundation** | Repo skeleton, `plugin.py`, entry-points wired | `jac loadtest --help` runs |
| **1 — MVP** | HAR parser, async engine, metrics, console report | `jac loadtest recording.har --url ... --vus 10 --duration 30s` works end-to-end |
| **2 — Auth + Think Time** | Per-VU JWT login, credentials file, ramp-up, think time | `--credentials-file` runs with 0 auth errors |
| **3 — Microservice Mode** | Topology routing, per-service metrics breakdown | `--mode microservice` reports per-service latency |
| **4 — Production Hardening** | Graceful shutdown, exit codes, thresholds, RPS cap | Interrupted test still generates partial report; CI pipeline detects failures |
| **5 — Reporting** | JSON + HTML reports with charts, live progress bar | `--report-format html` produces self-contained file with charts |
| **6 — PyPI Release** | Tests, README, polished `pyproject.toml`, publish | `pip install jac-loadtest && jac loadtest --help` works from PyPI |
| **7 — jac-scale Native** | Code moves into jac-scale; bridge adapters swap to in-process | `pip install jac-scale` (no `jac-loadtest`) and `jac loadtest` still works |
| **8 — Jac Rewrite** | `cli.py` / `config.py` rewritten in Jac | No Python shim in critical path |
