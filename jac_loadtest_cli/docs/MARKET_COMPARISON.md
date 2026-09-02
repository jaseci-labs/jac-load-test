# jac-loadtest vs. the Market

A comparison of `jac-loadtest-cli` against the load-testing tools in common use as of 2026,
and how each of them solves the problems recorded in [`CONSTRAINTS.md`](CONSTRAINTS.md). This
document is the evidence base for the priority order in
[`COMBINED_ROADMAP.md`](COMBINED_ROADMAP.md).

---

## 1. Where jac-loadtest sits

| Tool | Test definition | Concurrency model | Scale-out | Recording |
|---|---|---|---|---|
| **jac-loadtest** | **HAR file (zero scripting)** | asyncio coroutines × N worker processes | none (single machine) | Chrome DevTools → export `.har` |
| k6 | JavaScript | Go goroutines | k6-operator (k8s), Grafana Cloud | browser extension, k6 Studio, HAR converter |
| JMeter | GUI-built `.jmx` XML | Java threads | remote/distributed mode, BlazeMeter | built-in HTTP(S) proxy recorder |
| Gatling | Scala/Kotlin/Java DSL | Akka actors (async) | Gatling Enterprise | recorder proxy + HAR import |
| Locust | Python classes | gevent greenlets | master/worker | `har2locust` converter |
| Artillery | YAML | Node.js event loop | AWS Lambda / Fargate fan-out | HAR converter |
| GoReplay / Speedscale / Keploy | captured production traffic | replay engine | varies | **traffic capture (NIC / eBPF sidecar)** |

**jac-loadtest's differentiator is real and worth protecting:** the HAR *is* the test script,
and the tool is jac-scale-aware (knows `/user/login` + JWT, reads `jac.toml` topology,
mirrors `ServiceRegistry.match_route()`). No other tool understands a jac-scale app out of
the box. The gaps below are about *depth within that niche*, not about becoming a k6
competitor.

---

## 2. Capability gaps (what the market has that jac-loadtest doesn't)

| Capability | jac-loadtest | k6 | JMeter | Gatling | Locust | Roadmap |
|---|:--:|:--:|:--:|:--:|:--:|---|
| Zero-scripting test definition | ✅ | ❌ | ❌ | ❌ | ❌ | — (keep) |
| jac-scale auth / topology awareness | ✅ | ❌ | ❌ | ❌ | ❌ | — (keep) |
| Response correlation (extract → inject) | ❌ | ✅ | ✅ (+ auto wizard) | ✅ | ✅ | **P7a** |
| Per-VU identity / account pool | ❌ | ✅ | ✅ | ✅ | ✅ | **P7b** |
| Re-auth on token expiry | ❌ | ✅ | ✅ | ✅ | ✅ | **P7b** |
| Test-data feeders (CSV / generated) | ❌ | ✅ | ✅ | ✅ | ✅ | **P7c** |
| Randomized think time | partial | ✅ | ✅ | ✅ | ✅ | **P7d** |
| Traffic-mix / persona weighting | ❌ | ✅ (scenarios) | ✅ (thread groups) | ✅ | ✅ (weights) | **P7e** |
| Per-request assertions/checks | global only | ✅ | ✅ | ✅ | ✅ | **P8b** |
| Run-to-run regression / baseline gate | ❌ | partial (thresholds) | ❌ | ✅ (Enterprise) | ❌ | **P8c** |
| Distinguish infra block from app error | ❌ | manual | manual | manual | manual | **P8a** |
| Pluggable / non-standard auth | ❌ | ✅ | ✅ | ✅ | ✅ | **P10a** |
| Built-in recorder (no DevTools) | ❌ | ✅ | ✅ | ✅ | ❌ | **P10b** |
| OpenAPI / spec import | ❌ | ✅ (converter) | ✅ (plugin) | ❌ | ❌ | **P10c** |
| Distributed load generation | ❌ | ✅ | ✅ | ✅ | ✅ | **P11** |
| Live metrics → Prometheus / Grafana | ❌ | ✅ | ✅ (plugin) | ✅ | ✅ | **P12a** |
| JUnit / CI-native report | ❌ | ✅ | ✅ | ✅ | ❌ | **P12b** |
| gRPC / DB / MQTT protocols | ❌ | ✅ (partial) | ✅ | partial | partial | **P13** |

Legend: **P7a** = Roadmap Phase 7, item a.

---

## 3. How the market solves each `CONSTRAINTS.md` problem

### §1 — HAR session diversity / multi-user data

Every mature tool separates the **workflow** (sequence of requests) from the **user-specific
data** in it. jac-loadtest currently conflates them by replaying HAR bytes verbatim.

- **Correlation.** JMeter has post-processors (regex / JSON / boundary extractors) plus a
  *correlation recorder* that auto-detects dynamic values during recording and inserts the
  extractors for you. Gatling's recorder does the same. k6 and Locust do it in script code
  (`res.json().id` → next request). **→ jac-loadtest Phase 7a** copies the JMeter/Gatling
  auto-detect-and-suggest model (`--correlate-scan`) plus an explicit flag.
- **Per-VU identity.** All of them read an accounts file and assign a row per VU (JMeter `CSV
  Data Set Config`, k6 `SharedArray`, Gatling `feed()`, Locust `on_start` login). **→ Phase
  7b** (`--accounts`), shipped *with* correlation because neither fixes multi-user replay
  alone.
- **Re-auth.** Handled in script (`if res.status == 401: login()`). **→ Phase 7b** does it
  automatically per VU.

### §2 — Static request bodies / parameterization

CSV feeders (`CSV Data Set Config`, `SharedArray` + papaparse, Gatling feeders) and inline
generators (`${__Random}`, `uuidv4()`, `Faker`). **→ Phase 7c** (`--param` + `{{tokens}}`).

### §3 — asyncio VU ceiling

Distributed master/worker (Locust, JMeter remote mode) or a k8s operator (k6-operator) or
cloud fan-out (Artillery on Lambda, Gatling Enterprise). Nobody shells out to a *different*
load generator to scale. **→ Phase 11** native controller/worker. The `--engine k6` idea is
dropped.

### §4 — Auth coupled to jac-scale format

Auth is ordinary scenario code (k6, Locust, Gatling) or a pluggable Auth Manager (JMeter).
**→ Phase 10a** adds `--auth-type` profiles + `--auth-adapter` escape hatch. Low priority —
the jac-scale contract is the point of the tool.

### §5 — Global-only response assertion

Per-request `check()` (k6), `Assertion` children scoped to a sampler (JMeter),
`.check(status.is(200), jsonPath("$.id").exists)` (Gatling). Aggregate pass/fail is a
*separate* concept (k6 `thresholds`, Gatling `assertions`). jac-loadtest already has the
aggregate side (`--fail-on-*`); it's missing per-endpoint checks. **→ Phase 8b.**

### §6 — Single source IP (issue #24)

Distributed cloud generators spread egress across many IPs by construction; LoadView markets
this explicitly. On-prem tools document the constraint and expect an allowlist. **→ Phase 8a**
(detect + classify + `--proxy-pool`) and **Phase 11** (real multi-IP).

---

## 4. Recording: is there an easier way than HAR export?

Five tiers, easiest-for-the-user last:

| Tier | Mechanism | Tools | Friction |
|---|---|---|---|
| 1 | HAR file converter | jac-loadtest today, `har2locust`, k6 converter | record in DevTools → export → locate file → convert |
| 2 | Built-in proxy recorder | JMeter, Gatling, k6 Studio, mitmproxy | set browser proxy → click → get a test |
| 3 | Browser-extension recorder | k6 | click "record" in the browser, no proxy setup |
| 4 | Traffic capture from a running system | GoReplay (NIC/pcap), Speedscale / Keploy (eBPF sidecar) | deploy a sidecar once; real traffic becomes tests + mocks |
| 5 | Spec-driven | OpenAPI / Swagger import | no recording at all if a spec exists |

**Verdict for jac-loadtest:**

- **Tier 2 (`jac x loadtest record`) is the right near-term win** — Phase 10b. It removes the
  DevTools round-trip with a small, dependency-light forward proxy — **and it fixes the
  WebSocket blind spot** (`CONSTRAINTS.md` §7): a Chrome DevTools HAR export drops all
  WebSocket frames, so subscription/WS endpoints currently have nothing to replay. A proxy
  (or Playwright's `recordHar({ mode: "full" })`, or CDP capture) sees the frames on the wire.
  A `--ws-scenario` file flag (Phase 9) is the interim escape hatch.
- **Tier 5 (OpenAPI import) is nearly free** for jac-scale, which can emit an OpenAPI spec —
  Phase 10c.
- **Tier 4 is powerful but out of scope.** eBPF capture + auto-mocking is a product in its
  own right; a general coding agent driving Playwright covers the "no HAR, no spec" case
  without the tool owning a capture stack.

---

## 5. Strategic read — how much does a mature tool matter to Jaseci?

**High strategic importance, but scope it tightly.** Jaseci's positioning leans on
"scale-invariance" — the same code runs from a laptop to a k8s cluster. That claim needs
*evidence*, and there is currently no first-party way to produce it. A load-test tool that
can model a realistic multi-tenant workload against a jac-scale app, and gate runtime
performance regressions in CI, is the instrument that backs the brand claim.

The value is **front-loaded on internal / first-party use**: perf regression gates for the
jac-scale runtime, capacity numbers for flagship apps. External adoption follows later and is
served by the same CLI.

"Mature" should mean, specifically:

1. **Multi-user realism** — correlation, per-VU identity, test data (Phase 7).
2. **Trustworthy results + CI gating** — infra-block fidelity, body-level correctness,
   baseline regression (Phase 8).
3. **Shipped with the framework** — `jac install jac-scale[loadtest]` (Phase 12d).

It should **not** mean chasing k6 on protocol breadth or raw VU throughput. Fold it into
jac-scale as planned; keep it jac-scale-native and deep rather than broad.
