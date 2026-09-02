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

Four ways to deliver `jac x loadtest`:

| Option | Description | Why We Rejected It |
|--------|-------------|-------------------|
| **A — jac-scale plugin (native)** | Code lives inside jac-scale from day one | Slows iteration; requires PRs into the main jac-scale repo for every change |
| **B — Admin portal integration** | Load generation tied to the running server | Noisy-neighbor risk; the tool under test also generates load |
| **C — Standalone microservice** | Deployed as a separate service | Dev/test tool with deployment overhead — overkill |
| **D — Truly standalone** | Completely independent tool, no jac-scale knowledge | Loses auth integration (`/user/login` + JWT) and microservice topology awareness |

**We chose a hybrid:** standalone Jac package that is jac-scale-aware from day one, designed to migrate cleanly into jac-scale later.

---

## Why This Approach

Three key properties:

**1. `jac x loadtest` from day one.**
Declared as a `loadtest` console script via `[entrypoints.scripts]` in `jac.toml`. `jac install jac-loadtest-cli` and `jac x loadtest` resolves it — no separate binary, no PATH changes. (Jac has no third-party `jac <name>` subcommand plugin system; `jac x` is the supported way to run an installed package's console-script.)

**2. Core isolation.**
`core/` (parser, engine, metrics) has zero jac-scale knowledge — it works against any HTTP server. The jac-scale-specific logic (auth, microservice routing) lives in a thin `bridge/` layer on top. This makes the tool independently testable and means migration later is a file move, not a rewrite.

**3. jac-scale aware where it matters.**
The `bridge/` layer speaks jac-scale natively: knows the `/user/login` request shape, reads `jac.toml` for service topology, and mirrors `ServiceRegistry.match_route()` for microservice routing.

---

## Ultimate Goal

**Two stages:**

**Stage 1 — Standalone Jac package** (`jac install jac-loadtest-cli`) ✓
Delivers `jac x loadtest` immediately. Written entirely in Jac. Iterated fast outside the main jac-scale repo.

**Stage 2 — Native jac-scale integration** (`jac install jac-scale[loadtest]`)
Code moves into jac-scale. The `bridge/` adapters gain in-process access to jac-scale internals — no more HTTP calls for auth, no more disk reads for topology. The command name never changes. Users see nothing different.

---

## Steps We Follow

This document's own phase table has been retired. **[`docs/COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md)
is the single, live source of truth** for what's built, in progress, and next — see its
`Phase Status Overview` table.

As of the 2026-09 restructure the project is **CLI-first**: the web app is frozen at its
Phase 6 MVP and every capability from Phase 7 onward is CLI + headless engine code only. The
priorities (multi-user realism, then result fidelity and CI regression gating, then the fold
into jac-scale) come from a market comparison and an ecosystem assessment recorded in
[`docs/MARKET_COMPARISON.md`](MARKET_COMPARISON.md). The AI-assisted discovery/persona
features from the earlier plan were removed — a general coding agent does that job better
than a bespoke agent inside the tool.

The two-stage arc above (standalone package → native jac-scale integration) still holds:
Stage 1 is `COMBINED_ROADMAP.md` Phases 0–5 (done); Stage 2 is Phase 12d's jac-scale
integration item.
