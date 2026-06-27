# jac-loadtest Web — Product Roadmap

A browser-based web application that brings the `jac-loadtest` engine to a visual,
no-CLI interface, then expands it into a full multi-protocol load testing tool competitive
with JMeter while being far more modern and approachable.

---

## Vision

The market gap this product targets: **there is no maintained, open-source, web-native
load testing tool with multi-protocol support and a good UX.** JMeter is the only
open-source GUI tool in this space and it is 20+ years old. Every modern alternative
(k6, Locust, Gatling, Artillery) is CLI-only. Enterprise tools (NeoLoad, LoadRunner) have
web clients but cost $50k+/year and target Fortune 1000 compliance teams.

This product positions as: **"the modern JMeter"** — a web-first, open-source load
tester that covers HTTP, GraphQL, WebSocket, gRPC, and database connections in a single
visual test builder, accessible from any browser.

---

## Architecture Principle

The existing `jac-loadtest` CLI engine (`core/`, `bridge/`, `output/`) is the backend.
The web UI is a frontend shell that configures the engine and visualises its output.
The engine is never rewritten — only extended with new protocol adapters.

```
Browser (cl codespace — Vite/React)       ←  new work
  ↕ HTTP walker calls (jac-client fullstack)
jac-loadtest sv walkers (sv codespace)    ←  new work (thin adapters)
  ↓ imports as Python module
jac-loadtest engine (jac_loadtest_cli)    ←  existing core, unchanged
  ↓ extended by
Protocol Adapters                         ←  new work per protocol
```

**Stack: `jac-client` fullstack** — the Jac-native web build target built into `jaclang`
core. The `sv` codespace is a Jac HTTP server; the `cl` codespace is a Vite/React bundle.
`jac build --client web` compiles the `cl` code to a static bundle. `jac serve` runs the
`sv` server which serves the bundle and handles walker HTTP calls.

The existing `jac_loadtest_cli` Python package is imported directly inside the `sv`
walkers. The `cl` frontend calls `sv` walkers over HTTP; those walkers invoke the engine,
stream metrics events back to the UI via Server-Sent Events, and return reports as JSON.

Project config in `jac.toml`:

```toml
[project]
kind = "fullstack"
entry-point = "main.jac"

[dependencies.npm]
jac-client-node = "1.0.7"

[plugins.client]

[serve]
base_route_app = "app"
```

Build and run:

```bash
jac build --client web     # → .jac/client/dist/  (compiled React bundle)
jac serve                  # start sv HTTP server + serve the cl bundle
jac start --client web     # build + serve + open browser
```

---

## Phase 0 — Web MVP

> **Goal:** Replace the command line entirely for the existing HTTP load testing feature.
> A user with no CLI experience should be able to run a load test — including uploading
> traffic, generating test users, and running personas — from a browser tab.

### Scope

This phase wraps the **existing** engine and adds foundational UX capabilities: HAR
upload, synthetic user generation, and a basic persona system. No new protocol support
beyond HTTP. The value is entirely in the UX shell and workflow automation.

### Stack Layout

```
jac_loadtest_web/
├── jac.toml                       ← kind = "fullstack", npm deps, [plugins.client]
├── main.jac                       ← entry point: imports sv endpoints + cl app root
├── docs/
├── tests/
├── sv/                            ← server codespace: Jac walkers
│   ├── __init__.sv.jac
│   ├── engine_bridge.sv.jac       ← run_test(), stop_test(), stream_metrics() walkers
│   ├── har_walkers.sv.jac         ← parse_har(), validate_har() walkers
│   ├── recorder_walkers.sv.jac    ← start_proxy(), stop_proxy() walkers
│   └── user_gen_walkers.sv.jac    ← generate_users(), export_csv() walkers
└── cl/                            ← client codespace: React components
    ├── __init__.cl.jac
    ├── App.cl.jac
    ├── pages/
    │   ├── TestBuilder.cl.jac
    │   ├── HarImport.cl.jac
    │   ├── UserGen.cl.jac
    │   ├── PersonaBuilder.cl.jac
    │   └── Results.cl.jac
    └── components/
        ├── RunControl.cl.jac
        ├── HarEntryTable.cl.jac
        ├── MetricsDashboard.cl.jac
        └── LatencyChart.cl.jac
```

### Features

**Project & Config**
- [ ] New test wizard: enter target URL, choose HAR file or record via proxy, set VU count,
      duration, ramp-up
- [ ] Save/load test configurations as `.jactest` project files (JSON), stored server-side
      and selectable from a dropdown
- [ ] Three-layer config UI matching CLI: project defaults, per-run overrides, built-in defaults
- [ ] Thresholds panel: set `--fail-on-error-rate`, `--fail-on-p95`, `--fail-on-p99`

**HAR Management — Manual Upload**
- [ ] Drag-and-drop HAR file onto the main workspace (browser `drop` event → multipart POST
      to `parse_har` sv walker)
- [ ] File picker button (`<input type="file" accept=".har">`) as fallback
- [ ] HAR entry viewer: show all parsed requests with method, URL, status code, MIME type,
      and response time from the recording
- [ ] Toggle individual entries on/off before running (replaces the all-or-nothing MIME filter)
- [ ] HAR diff panel: when a new HAR is imported over an existing one, highlight added,
      removed, and changed entries
- [ ] HAR security warning: surfaced as a dismissible banner when `Authorization` or `Cookie`
      headers are detected in the imported file

**HAR Management — Proxy Recorder**
- [ ] Proxy recorder: the `start_proxy` sv walker spins up a local HTTP proxy on a
      configurable port; the user points their browser or `curl` at it; captured traffic is
      accumulated in-memory inside the sv codespace
- [ ] Record / Stop buttons in the toolbar: `start_proxy` and `stop_proxy` walker calls;
      `stop_proxy` returns the parsed HAR entries directly to the `cl` frontend
- [ ] URL scope filter: user enters a base URL (e.g. `https://myapp.com`) and only requests
      matching that origin are captured, ignoring third-party CDN and analytics noise
- [ ] Export recorded HAR: download the captured session as a `.har` file from the browser
- [ ] Proxy port setting: configurable from the Settings panel, defaults to `8888`

**User Generation — Random & Synthetic Users**
- [ ] Random user generator panel: specify count, choose identity fields (username, email,
      password, custom fields), and generate a synthetic credentials list
- [ ] Generation strategies:
  - *Random* — UUID-seeded random strings for each field
  - *Realistic* — human-like names and email addresses using a bundled name corpus
  - *Pattern* — user-defined template with a counter, e.g. `user_{{n}}@test.com`
- [ ] Preview table: show the first N generated rows before committing
- [ ] Export generated users: download as CSV (compatible with `--credentials-file` format)
- [ ] Import existing credentials CSV: browser file upload, shows a preview with row count
      and detected columns (`username`, `password`, custom fields)
- [ ] Credential assignment: generated or imported users are bound to a persona or
      distributed round-robin across all VUs if no persona is defined
- [ ] Wrap-around behaviour: when VU count exceeds user count, users are reused cyclically;
      a warning badge shows the reuse ratio

**Persona Builder (Basic)**

A **persona** is a named user type with its own request flow, VU count, and credential
assignment. This phase introduces the persona concept at the workflow level; advanced
per-persona metrics and weighted ramp-up are deferred to Phase 2.

- [ ] Persona manager panel: create, name, and colour-code up to 10 personas per test
- [ ] Per-persona flow editor: ordered list of request steps; steps can be reordered via
      drag-and-drop
- [ ] Assign HAR entries to a persona: drag entries from the HAR viewer onto a persona's
      flow, or use a bulk-assign dropdown ("assign all POST requests to Persona A")
- [ ] Per-persona VU count: absolute integer allocation (e.g. `vus: 20`)
- [ ] Credential binding: attach a generated user list or imported CSV to a specific persona;
      users are distributed round-robin across that persona's VUs
- [ ] Default persona: if no personas are defined, all HAR entries run as a single unnamed
      flow (backwards-compatible with the wizard path)
- [ ] Engine bridge: the `engine_bridge` sv walker serialises persona configs and passes them
      to `jac_loadtest_cli.core.engine.run_all_vus`; the `PersonaConfig` dataclass in
      `core/engine.jac` is the target format
- [ ] Per-persona run summary: after a test completes, the results panel shows a tab per
      persona with request count, error rate, and p95 latency

**Credentials Panel**
- [ ] Username/password fields for a single shared credential (maps to `--username`/`--password`)
- [ ] Credentials CSV upload (maps to `--credentials-file`); displays row count and a
      preview of the first 5 rows
- [ ] Integration with the random user generator: "Generate Users" button opens the
      generator panel and imports the result directly into the credentials table

**Run Control**
- [ ] Run / Stop buttons: POST to `run_test` and `stop_test` sv walkers; stop maps to the
      engine's graceful two-signal shutdown model
- [ ] Ramp-up progress ring: shows live VU count during ramp-up phase, updated via
      Server-Sent Events streamed from the `stream_metrics` sv walker
- [ ] Live RPS counter and error rate badge updating every second via SSE

**Real-time Metrics Dashboard**
- [ ] RPS-over-time line chart (live, streaming via SSE — not post-run)
- [ ] p50/p95/p99 latency-over-time chart (live)
- [ ] Per-endpoint latency bar chart updating every 10 seconds
- [ ] Error rate gauge with colour coding (green < 1%, yellow 1–5%, red > 5%)

**Reporting**
- [ ] Results panel renders the JSON report returned by the `run_test` sv walker inline
      in the page using Chart.js
- [ ] Download as JSON: browser `Blob` download of the raw report JSON
- [ ] Download as HTML: the sv walker calls `render_html` from `jac_loadtest_cli.output.reporter`
      and returns the HTML string; browser triggers a file download
- [ ] Test history: server-side list of past runs (stored as JSON files in a `runs/`
      directory on the server); the `cl` frontend shows a list with summary stats and a
      "Load" button

**Settings**
- [ ] Worker process count selector (maps to `--workers`)
- [ ] Timeout, think-time, RPS cap controls
- [ ] Debug log panel: the sv walker streams per-request lines back via SSE when debug is on
- [ ] Proxy port setting
- [ ] Settings persisted to browser `localStorage`

### Exit Criterion

A non-technical user can: open the web app in a browser, upload a HAR file OR capture
traffic via the proxy recorder, generate synthetic test users, assign them to a persona,
click Run, watch live metrics in the browser, see a per-persona result summary, and
download an HTML report — without touching a terminal.

### MVP Must-Have Checklist

**Must have:**
- [ ] jac-client fullstack shell: `jac serve` runs sv + serves cl bundle in browser;
      `cl` frontend calls `sv` walkers via HTTP; `sv` walkers import `jac_loadtest_cli`
- [ ] Test configuration form: URL, VUs, duration, ramp-up
- [ ] Manual HAR import: drag-and-drop and browser file picker
- [ ] HAR entry viewer with per-entry enable/disable toggle
- [ ] Proxy-based HAR recorder: start/stop from the UI, captures via local HTTP proxy
- [ ] Random user generator: pattern and realistic modes, CSV download
- [ ] Credentials panel: single credential and credentials CSV import
- [ ] Basic persona builder: create personas, assign HAR entries, set VU count,
      bind credentials
- [ ] Run / Stop buttons with graceful shutdown
- [ ] Live RPS and error rate counters via SSE during run
- [ ] Per-persona post-run summary (request count, error rate, p95)
- [ ] Inline results viewer (renders JSON report as charts in the page)
- [ ] Download results as JSON and HTML
- [ ] Save/load `.jactest` project file (server-side storage)

**Nice to have (defer to Phase 1):**
- Real-time latency charts during run (SSE streaming)
- Test run history
- Threshold configuration UI
- HAR diff panel

**Explicitly out of scope for MVP:**
- Any new protocol support
- Advanced persona features (weighted VU, staggered ramp-up, live per-persona charts)
- AI flow generation
- Distributed testing
- Plugin architecture

---

## Phase 1 — GraphQL & WebSocket Support

> **Goal:** First protocol expansion beyond HTTP. Both are high-value targets with poor
> tooling in the current market (GraphQL subscriptions via WebSocket are underserved by
> every major tool).

### GraphQL (HTTP)

- [ ] GraphQL request editor: query/mutation text area with syntax highlighting
- [ ] Variables panel (JSON editor with validation)
- [ ] Schema introspection: the `sv` walker fetches `{url}/graphql` schema and returns it;
      the `cl` editor uses it for autocomplete and field validation
- [ ] Auto-detect GraphQL endpoints in imported HAR files and render them with the
      dedicated GraphQL UI instead of the raw HTTP panel
- [ ] Per-query response time breakdown in metrics (keyed by `operationName` if set)

### GraphQL Subscriptions (WebSocket)

- [ ] WebSocket engine adapter in `jac_loadtest_cli/core/ws_engine.jac` — connect, send
      `graphql-ws` protocol handshake, send subscription query, receive events, record
      event-to-first-message latency and message throughput
- [ ] Subscription test builder: enter subscription query, expected event schema
- [ ] Metrics: events/second, time-to-first-event p50/p95/p99, connection drop rate
- [ ] Load shape: N concurrent subscription connections, duration, ramp-up

### Raw WebSocket

- [ ] Generic WebSocket scenario builder: connect, send message sequence,
      record response latencies and message counts
- [ ] Message templates with variable substitution (e.g. `{"user_id": "{{vu_id}}"}`)
- [ ] Support both `ws://` and `wss://` with TLS certificate options

### UI Additions

- [ ] Protocol selector tab on the test builder: HTTP | GraphQL | WebSocket
- [ ] Metrics panel gains "Connections" tab for WebSocket active connection count
- [ ] Side-by-side scenario editor: define an HTTP flow + a WebSocket subscription
      in the same test run (mixed-protocol scenario)

### Exit Criterion

A user can run a load test that simultaneously hammers a REST endpoint with 50 VUs
and holds 20 concurrent GraphQL subscriptions, seeing unified metrics for both in one
dashboard.

---

## Phase 2 — Advanced Persona-Based Testing

> **Goal:** Extend the basic persona system introduced in Phase 0 with weighted VU
> allocation, staggered ramp-up, live per-persona metrics, and engine-level persona
> orchestration. This turns personas from a workflow organiser into a first-class load
> modelling primitive — no open-source tool does this in a GUI today.

### Engine Changes (jac_loadtest_cli extension)

- [ ] `PersonaConfig` dataclass: `name`, `flow`, `vus`, `think_time`, `ramp_up`, `weight`
- [ ] `run_personas()` orchestrator: launches one `run_all_vus` coroutine per persona
      concurrently, all sharing a single `MetricsCollector`
- [ ] `RequestResult` gains `persona: str` field for per-persona metric breakdown
- [ ] `EndpointStats` grouped by `(persona, endpoint)` — reports show per-persona rows

### Advanced Persona Builder

- [ ] Per-persona VU weight: percentage of total VUs (`weight: 0.4` → 40%) as an
      alternative to the absolute count set in Phase 0
- [ ] Per-persona ramp-up: stagger persona activation independently (e.g. "new users"
      ramp up over 30s, "power users" are always-on)
- [ ] Per-persona think time override: set a different think-time strategy per persona
      independent of the global setting
- [ ] Persona import/export: download/upload a persona definition as a `.jacpersona` file
      (JSON) that can be shared across test configurations

### Live Per-Persona Metrics

- [ ] Live RPS line chart broken down by persona colour during a run; streamed from
      the `stream_metrics` sv walker to the `cl` frontend via SSE
- [ ] Live error rate badge per persona in the run control bar

### Metrics & Reporting

- [ ] Persona comparison chart: side-by-side p95 latency per persona over time
- [ ] Per-persona error rate timeline
- [ ] Persona traffic mix chart: RPS contribution of each persona during the run
- [ ] HTML report gains a "Personas" section with individual persona summary cards

### Exit Criterion

A user defines two personas ("new visitor: browse + add to cart" and "returning user:
search + checkout"), assigns weight-based VU allocation, sets independent ramp-ups, runs
the test, and sees live per-persona RPS alongside separate p95 latency and error rate
per persona in the final report.

---

## Phase 3 — AI-Powered Flow Generation

> **Goal:** Make persona definition zero-effort for users who have an OpenAPI spec or
> can describe their app in plain English. This is the feature that has no equivalent
> in any existing tool.

### API Surface Discovery

Three input methods, offered as a wizard in the UI:

1. **OpenAPI/Swagger spec** — enter `{url}/openapi.json` or upload a `.yaml` file.
   The sv walker fetches and parses all endpoints, methods, request schemas, and response
   schemas server-side, then returns the surface to the `cl` frontend.
2. **HAR recording** — use the existing HAR import or proxy recorder. Parsed endpoints
   become the candidate step list.
3. **Sitemap crawl** — enter the base URL. The sv walker fetches `sitemap.xml` and
   crawls discovered URLs to identify API endpoints.

The discovered surface is shown as a checklist of endpoints the user can include or
exclude before generating flows.

### LLM Flow Generation

- [ ] Persona description text input: user writes a plain-English description of the
      user type (e.g. "A first-time visitor who browses product categories, views 3
      product pages, adds one item to cart, then abandons without purchasing")
- [ ] "Generate Flow" button: the `generate_flow` sv walker calls the Claude API
      (`anthropic` Python SDK, imported in the sv codespace). The prompt includes:
      - The persona description
      - The list of available endpoints with method and path
      - Schema hints from OpenAPI (request body shape, required fields)
      - Instruction to return an ordered JSON array of steps with method, path,
        example body, and suggested think time
- [ ] Generated flow is shown in the flow editor as editable draft steps — the user
      reviews, reorders, edits, or deletes steps before saving
- [ ] Safety gate: any step touching destructive endpoints (DELETE, paths containing
      `/delete`, `/destroy`, `/reset`) is flagged with a warning banner and requires
      explicit user confirmation before it is included

### Iteration & Refinement

- [ ] "Regenerate" button with feedback: user can tell the LLM "make the think times
      shorter" or "add more product views before checkout" and the sv walker revises the flow
- [ ] Flow diff view: compare the revised flow against the previous version
- [ ] Save generated flows as reusable persona templates (`.jacpersona` file format, JSON)

### LLM Configuration

- [ ] API key management: entered in the Settings panel; stored in the server's environment
      or a local `.env` file — never exposed to the browser
- [ ] Model selector: default to `claude-sonnet-4-6`, allow override
- [ ] Offline mode: if no API key is configured server-side, AI generation is disabled
      with a clear explanation — the rest of the tool works without it

### Exit Criterion

A user pastes an OpenAPI URL, writes a two-sentence persona description, clicks
"Generate Flow", reviews the 8-step draft, approves it, and runs a 50-VU load test
against the generated flow — all without writing a single line of code or config.

---

## Phase 4 — gRPC & Database Connections

> **Goal:** Match JMeter's multi-protocol coverage in a modern interface. Database
> testing is the biggest gap in the open-source market and the highest-value addition
> for backend engineers.

### gRPC

- [ ] gRPC scenario builder: upload `.proto` file (browser file upload → sv walker parses
      it), browse service definitions and methods in a tree view, select a method to test
- [ ] Request message editor: form-based editor generated from the proto schema,
      plus raw JSON mode for advanced users
- [ ] All streaming modes: unary, server-streaming, client-streaming, bidirectional
- [ ] Metadata (header) editor for gRPC-specific headers (auth tokens, tracing)
- [ ] Metrics: calls/second, message latency p50/p95/p99, stream duration, error codes
      (gRPC status codes mapped to error breakdown)
- [ ] TLS configuration: upload CA cert, client cert, client key; stored server-side

### Database Connections

Supported initially: **PostgreSQL**, **MySQL**, **MongoDB**.

- [ ] Database connection panel: host, port, database name, username, password,
      connection pool size, SSL mode — entered in the browser, sent to sv walker
- [ ] Query editor per database type:
  - SQL (PostgreSQL/MySQL): raw SQL with syntax highlighting, result preview
  - MongoDB: JSON query document editor (find, aggregate, insert, update)
- [ ] Connection pool load testing: define a pool size, run N concurrent queries,
      measure: connection acquisition time, query execution time p50/p95/p99,
      pool exhaustion events, failed connections
- [ ] Transaction scenario: multi-step SQL sequence that commits or rolls back as a
      unit — measures total transaction time
- [ ] Parameterised queries: substitute `{{vu_id}}`, `{{iteration}}`, or values from
      a CSV column into query parameters to avoid cache-hit uniformity
- [ ] Metrics: queries/second, connection pool utilisation (%), deadlock count,
      slow query count (above configurable threshold)

### Mixed-Protocol Scenarios

- [ ] Scenario editor allows mixing steps across protocols in a single persona flow:
      e.g. POST HTTP → open WebSocket subscription → run 3 SQL queries → close WebSocket
- [ ] Dependency chaining: extract a value from one step's response and use it in the
      next step's request body (e.g. extract `order_id` from HTTP response, pass to
      the next SQL query)
- [ ] Think times and ramp-up apply uniformly across mixed steps

### Exit Criterion

A user runs a scenario that: (1) logs in via HTTP, (2) opens a WebSocket subscription,
(3) inserts a row into PostgreSQL, (4) calls a gRPC method, (5) verifies the subscription
received the expected event — all in a single persona flow measured end-to-end.

---

## Phase 5 — Distributed Testing

> **Goal:** Break the single-machine VU ceiling and enter the team-scale testing vertical.

### Distributed Load Generation

- [ ] Worker node agent: a lightweight `jac-loadtest-agent` process that runs on
      remote machines and connects back to the web server controller
- [ ] Controller UI: add remote worker nodes by IP/port, see their status (connected,
      running, idle) from the browser
- [ ] VU distribution: total VUs split across all worker nodes (local + remote) by the
      `engine_bridge` sv walker
- [ ] Metrics aggregation: results streamed back to the controller sv in real time,
      merged into a single `MetricsCollector` and pushed to the `cl` frontend via SSE
- [ ] Geo distribution: label each worker node with a region; report latency
      breakdown by region in the HTML report
- [ ] Worker node discovery: mDNS-based auto-discovery for nodes on the same LAN

### MQTT

- [ ] MQTT connection builder: broker URL (`mqtt://`, `mqtts://`), port, client ID,
      username/password, TLS options, keep-alive interval
- [ ] Protocol versions: MQTT 3.1.1 and MQTT 5
- [ ] QoS levels: 0 (at most once), 1 (at least once), 2 (exactly once)
- [ ] Scenario builder: publish messages to topics on a schedule, subscribe to topics
      and measure message delivery latency (publish timestamp → receive timestamp)
- [ ] Topic parameterisation: `sensors/{{vu_id}}/temperature` for per-VU topics
- [ ] Metrics: messages/second, delivery latency p50/p95/p99, connection drops,
      reconnect count, message loss rate (for QoS 0)

### Exit Criterion

A user orchestrates a 5,000-VU load test split across 3 worker nodes in different
network segments, and sees unified per-region latency in the browser dashboard in real time.

---

## Phase 6 — Polish & Ecosystem

> **Goal:** Production-ready release. CI integration, plugin ecosystem, public launch.

### CI/CD Integration

- [ ] Headless API mode: `POST /api/run` accepts a `.jactest` config JSON and returns
      results as JSON — no browser needed; same exit-code semantics as the CLI
      (0 = pass, 1 = threshold fail, 2 = tool error)
- [ ] GitHub Actions plugin: `jaseci-labs/jac-loadtest-action@v1` that posts to the
      headless API and posts a summary comment on the PR with pass/fail and key metrics
- [ ] JUnit XML output: `/api/run?format=junit` for CI systems that consume XML
      test results (Jenkins, Azure DevOps, GitLab)

### Plugin Architecture

- [ ] Protocol plugin interface: a defined Python ABC (`ProtocolAdapter`) that
      third-party authors can implement to add new protocols without modifying the core
- [ ] Plugin registry: install plugins server-side; the UI auto-discovers installed
      plugins and adds their protocol tab to the test builder on next page load
- [ ] Official plugin list: maintained index of community protocol adapters
- [ ] Example plugins: Redis, Kafka, AMQP (RabbitMQ) as reference implementations

### UX Polish

- [ ] Onboarding tour: step-by-step walkthrough for first-time users
- [ ] Test templates library: pre-built test configs for common patterns
      (REST API stress test, WebSocket broadcast, DB connection pool test)
- [ ] Dark / light theme toggle (persisted to `localStorage`)
- [ ] Keyboard shortcuts for all primary actions
- [ ] Accessibility audit (WCAG 2.1 AA)

### Deployment

- [ ] Docker image: single container running `jac serve` — drop-in for any Docker Compose
      or Kubernetes setup
- [ ] `docker-compose.yml` example: web app + optional worker node agents
- [ ] Public website with docs, changelog, and a hosted demo instance
- [ ] Auth layer (optional): toggle-able login wall for team deployments; API token
      support for headless CI use

---

## Milestone Summary

| Phase | Name | Key Deliverable | Market Position |
|---|---|---|---|
| **0 — MVP** | Web Shell | HAR upload, proxy recorder, user generation, basic personas | Better JMeter UX for HTTP, runs in any browser |
| **1** | GraphQL & WebSocket | First non-HTTP protocols | Ahead of Artillery, matches k6 |
| **2** | Advanced Personas | Weighted VUs, staggered ramp-up, live per-persona charts | Unique in open-source market |
| **3** | AI Flow Generation | LLM-generated flows from persona descriptions | No equivalent exists |
| **4** | gRPC & Databases | PostgreSQL, MySQL, MongoDB, gRPC | Matches JMeter's protocol breadth |
| **5** | Distributed Testing | Multi-machine VU distribution, MQTT | Surpasses JMeter |
| **6** | Polish & Ecosystem | Plugin system, CI integration, Docker, public launch | Full product release |

---

## Protocol Support Target (Final Product)

| Protocol | Phase | Notes |
|---|---|---|
| HTTP/HTTPS | 0 (MVP) | Existing CLI engine |
| GraphQL (query/mutation) | 1 | HTTP POST, operation name keying |
| GraphQL subscriptions | 1 | WebSocket transport, `graphql-ws` protocol |
| WebSocket (raw) | 1 | Generic message sequences |
| gRPC | 4 | All streaming modes, mTLS |
| PostgreSQL | 4 | Native driver, connection pool testing |
| MySQL | 4 | Native driver, transaction scenarios |
| MongoDB | 4 | Driver-based, aggregation pipeline support |
| MQTT | 5 | 3.1.1 + 5, QoS 0/1/2, TLS |
| Redis | 6 (plugin) | Community plugin reference implementation |
| Kafka | 6 (plugin) | Community plugin reference implementation |
| AMQP (RabbitMQ) | 6 (plugin) | Community plugin reference implementation |

---

## Competitive Positioning

| Capability | jac-loadtest Web | JMeter | k6 | Gatling | NeoLoad |
|---|---|---|---|---|---|
| Web GUI | Yes (browser-native) | Yes (Java Swing, dated) | No | No | Yes (enterprise) |
| HTTP | Yes | Yes | Yes | Yes | Yes |
| Session recorder | Yes (local proxy) | Yes (HTTP proxy) | No | No | Yes |
| Random user generation | Yes (built-in) | Via CSV Dataset | Via scripts | Via scripts | Yes |
| Persona-based testing | Yes (visual, Phase 0) | Manual | Manual code | Manual code | Manual |
| GraphQL subscriptions | Yes | Via plugin | Manual WS | No | Yes |
| gRPC | Yes | Via plugin | Yes | Yes | Yes |
| Database load testing | Yes (built-in) | Yes (JDBC) | Via extension | No | Unclear |
| MQTT | Yes | No | Via extension | Yes | Yes |
| AI flow generation | Yes | No | No | No | Partial |
| Runs in browser | Yes | No | No | No | Yes |
| Open source | Yes | Yes | Yes | Partial | No |
| Price | Free | Free | Free | Free/paid | Enterprise |

---

## Path to Desktop (Future)

Once jaseci issue #6436 lands (embedded `sv` walker support in `jac-desktop`), the web
codebase converts to a native desktop app with **zero changes** to the `cl` or `sv` code:

```toml
# jac.toml change only:
[project]
kind = "desktop"     # was: "fullstack"

[plugins.desktop]
name = "jac-loadtest"
identifier = "io.jaseci.jac-loadtest"
version = "0.1.0"

[plugins.desktop.window]
title = "jac-loadtest"
width = 1280
height = 800
```

```bash
jac build --client desktop   # same sv + cl source → single native binary
```

The only web-specific pieces that need desktop replacements are the browser file upload
(`<input type="file">`) and `Blob` downloads — these swap for `@jac/desktop` `dialog` and
`fs` plugin calls, which are an additive change on top of the existing `cl` components.
