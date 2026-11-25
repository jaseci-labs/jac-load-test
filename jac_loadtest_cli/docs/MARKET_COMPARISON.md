# jac-loadtest vs. the Market

Where `jac-loadtest-cli` v0.11.1 stands as a **HAR-based load-testing tool**. Competitor cells
come from general knowledge of the tools, not fresh benchmarks, and score what works out of the
box (k6, Locust and Gatling can do almost anything in code). Current limits are in
[`CONSTRAINTS.md`](CONSTRAINTS.md); planned work is in [`ROADMAP.md`](ROADMAP.md).

## Summary

- **What it is:** a zero-script tool that replays a recorded browser session under load. The HAR
  file is the test.
- **Where it leads:** things other tools need hand-written code for: auto-detected correlation,
  a self-registering per-VU account pool, a check for failures hidden inside HTTP 200, and
  separation of WAF/rate-limit blocks from application errors.
- **Where it matches:** the load engine is Locust, so scheduling, workers, statistics and the
  console/HTML reports are Locust's. On top: load shapes (ramp, fixed duration, step-load), think
  time, thresholds with exit codes, test-data feeders, per-VU identity, re-auth, WebSocket and
  GraphQL replay, multi-process scaling, JSON reports.
- **Where it is behind:** scale and ecosystem (workers only on the same machine, no metrics sinks, JUnit,
  run-to-run regression gate, built-in recorder or pluggable auth), and it can only cover what
  was recorded.
- **Biggest gap for CI use:** the baseline regression gate (Phase 8c). Absolute thresholds exist;
  "p95 got 12% worse than main" does not.

## Positioning

| Tool | Test definition | Protocols | Scale-out | Recording |
|---|---|---|---|---|
| **jac-loadtest** | **HAR file, no script** | HTTP, WebSocket, GraphQL | single machine, N processes | DevTools export |
| k6 | JavaScript / TypeScript | HTTP, WebSocket, gRPC, browser | k6-operator, Grafana Cloud | extension, k6 Studio, HAR converter |
| JMeter | GUI-built `.jmx` XML | HTTP, JDBC, JMS, LDAP, FTP, … | remote mode, BlazeMeter | built-in proxy recorder |
| Gatling | Scala / Kotlin / Java / JS DSL | HTTP, WebSocket, SSE, JMS | Gatling Enterprise | recorder proxy, HAR import |
| Locust | Python classes | HTTP; others via custom clients | master/worker | `har2locust` |
| Artillery | YAML | HTTP, WebSocket, Socket.io, gRPC | Lambda / Fargate | HAR converter |
| GoReplay / Speedscale / Keploy | captured production traffic | HTTP (+ some) | varies | NIC / eBPF capture |
| wrk / hey / oha / Vegeta | one URL, no scenario | HTTP | none | none |

The last row is a different category (raw throughput, no workflow). jac-loadtest is for workflows.

## Target compatibility

"Test definition" is how you author a test, not what you can test. Every tool above can load test
a server written in any language or framework. The difference is the target-facing behaviour:

| Tool | Auth against the target | Tied to one platform? |
|---|---|---|
| **jac-loadtest** | jac-scale's login/register contract only; static headers such as `X-Api-Key` replay as recorded; `Authorization` and `Cookie` headers from a recording are stripped | Partly: login, `jac.toml` microservice routing and the default body check are jac-scale-specific |
| k6, JMeter, Gatling, Locust, Artillery | any scheme, written in the test | No |

jac-loadtest is easier to author for but narrower on the target side. Pluggable auth (Phase 10a)
would close that gap.

## Capability matrix

✅ built in · 🟡 possible but you write it · ❌ absent

### Where jac-loadtest leads

| Capability | jac-loadtest | k6 | JMeter | Gatling | Locust |
|---|:--:|:--:|:--:|:--:|:--:|
| Zero-script test definition | ✅ | ❌ | ❌ | ❌ | ❌ |
| jac-scale auth and topology awareness | ✅ | ❌ | ❌ | ❌ | ❌ |
| Correlation auto-detected, no flags | ✅ | ❌ | 🟡 | 🟡 | ❌ |
| Per-VU accounts that self-register | ✅ | ❌ | ❌ | ❌ | ❌ |
| Failure inside HTTP 200 (framework-aware default) | ✅ | 🟡 | 🟡 | 🟡 | 🟡 |
| WAF / rate-limit block separated from app errors | ✅ | ❌ | ❌ | ❌ | ❌ |
| Response-shape drift (`--check-shape`) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Wait-until polling scored as one result (`--poll-until`) | ✅ | 🟡 | 🟡 | 🟡 | 🟡 |
| Health-check side channel gated separately | ✅ | 🟡 | 🟡 | 🟡 | 🟡 |
| Auth-burst pacing for large account pools | ✅ | ❌ | ❌ | ❌ | ❌ |

### At parity

| Capability | jac-loadtest | k6 | JMeter | Gatling | Locust |
|---|:--:|:--:|:--:|:--:|:--:|
| Per-VU identity, re-auth on expiry | ✅ | ✅ | ✅ | ✅ | ✅ |
| Test-data feeders and generated values | ✅ | ✅ | ✅ | ✅ | ✅ |
| Think time from the recording | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fixed duration (no open-loop arrival rate) | ✅ | ✅ | 🟡 | ✅ | 🟡 |
| Step / ramp-to-failure with capacity knee | ✅ | 🟡 | 🟡 | ✅ | 🟡 |
| Thresholds, exit codes, abort on breach | ✅ | ✅ | 🟡 | ✅ | 🟡 |
| Per-endpoint thresholds | ✅ | ✅ | 🟡 | ✅ | 🟡 |
| Per-request assertions (`--assert-json`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| WebSocket and GraphQL | ✅ | ✅ | 🟡 | ✅ | 🟡 |
| Multi-process on one machine | ✅ | ✅ | ✅ | ✅ | ✅ |
| HTML and JSON reports | ✅ | 🟡 | ✅ | ✅ | ✅ |

### Still behind

| Capability | jac-loadtest | k6 | JMeter | Gatling | Locust | Roadmap |
|---|:--:|:--:|:--:|:--:|:--:|---|
| Run-to-run regression gate | ❌ | 🟡 | ❌ | ✅ | ❌ | 8c |
| Workers on other hosts, multi-IP egress | ❌ | ✅ | ✅ | ✅ | ✅ | 11 |
| Prometheus / Grafana / OTLP streaming | ❌ | ✅ | 🟡 | ✅ | ✅ | 12 |
| JUnit report | ❌ | ✅ | ✅ | ✅ | ❌ | 12 |
| Built-in recorder, WebSocket frame capture | ❌ | ✅ | ✅ | ✅ | ❌ | 10b |
| Pluggable auth | ❌ | ✅ | ✅ | ✅ | ✅ | 10a |
| Randomised think time, personas | ❌ | ✅ | ✅ | ✅ | ✅ | 7d, 7e |
| gRPC / DB / MQTT, browser testing, hosted service | ❌ | ✅ | ✅ | 🟡 | 🟡 | 13 / not planned |

## Recording options

| Tier | Mechanism | jac-loadtest |
|---|---|---|
| 1 | HAR file from DevTools | ✅ |
| 2 | Built-in proxy recorder (JMeter, Gatling, k6 Studio) | ❌ Phase 10b |
| 3 | Browser-extension recorder (k6) | ❌ not planned |
| 4 | Traffic capture from a live system (GoReplay, Speedscale) | ❌ out of scope |
| 5 | Import an OpenAPI spec | ❌ removed: one placeholder request per operation, no real values |

## Strategic read

A load tool that can model a realistic multi-tenant workload against a jac-scale app and gate
performance regressions in CI is the evidence for jac-scale's "scale-invariance" claim. "Mature"
means three things:

| Criterion | Status | Left |
|---|---|---|
| Multi-user realism (correlation, per-VU identity, test data) | ✅ Largely met | 7d, 7e |
| Trustworthy results and CI gating | ◑ Mostly met | 8c regression gate |
| Polished standalone release | ⬜ Not started | PyPI, JUnit, metrics sinks (Phase 12) |

It should not chase k6 on protocol breadth or raw VU throughput; it stays standalone,
jac-scale-aware and deep rather than broad.

| If you are… | Use jac-loadtest when… | Use something else when… |
|---|---|---|
| Testing a jac-scale app | always first: nothing else understands its auth, topology and walker envelope | you need workers on several hosts today |
| Testing another HTTP / GraphQL / WS API | you have a HAR and want a workflow test without a script | you need non-jac-scale login flows, gRPC/DB/MQTT, or distributed load now |
| Wanting a CI performance gate | an absolute-threshold gate is enough | you need diff-against-baseline today |
| Wanting one fast number | — | `oha` / `wrk2` / `hey` |
