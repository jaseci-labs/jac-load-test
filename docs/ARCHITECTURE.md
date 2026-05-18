# jac-loadtest Architecture

## Table of Contents

1. [Overview](#overview)
2. [HAR 1.2 Primer](#har-12-primer)
3. [Module Map](#module-map)
4. [Config Resolution](#config-resolution)
5. [End-to-End Data Flow](#end-to-end-data-flow)
6. [Virtual User Lifecycle](#virtual-user-lifecycle)
7. [HAR Parser](#har-parser)
8. [Load Engine](#load-engine)
9. [Exit Codes and Thresholds](#exit-codes-and-thresholds)
10. [Auth Module](#auth-module)
11. [Topology Module](#topology-module)
12. [Metrics Collector](#metrics-collector)
13. [Reporter](#reporter)
14. [CLI Reference](#cli-reference)
15. [Extension Points](#extension-points)
16. [Constraints and Known Limitations](#constraints-and-known-limitations)

---

## Overview

`jac-loadtest` is a HAR-based load testing CLI tool designed for [jac-scale](https://github.com/jaseci-labs/jaseci/tree/main/jac-scale) applications. Instead of writing test scripts in JavaScript (k6) or Python (Locust), users capture real browser traffic via Chrome DevTools, export it as a `.har` file, and feed it directly to this tool. The tool replays those requests under load and reports latency, error rates, and throughput.

### Design Philosophy

**Zero scripting.** The HAR file is the test script. The only configuration is load shape: how many virtual users, for how long, with what ramp-up.

**Core isolation.** The HAR parser, load engine, and metrics collector have zero knowledge of jac-scale internals. They work against any HTTP server. The jac-scale-specific logic (auth via `/user/login`, microservice topology from `jac.toml`) lives in a thin bridge layer on top of the core.

**`jac loadtest` from day one.** The standalone `jac-loadtest` PyPI package registers itself as a `jac` subcommand via `[project.entry-points."jac"]` — the same mechanism jac-scale uses. Installing `jac-loadtest` immediately makes `jac loadtest` available alongside `jac start`, `jac deploy`, etc. There is no separate `jac-loadtest` binary to learn. When the tool matures, the plan is to absorb it as `pip install jac-scale[loadtest]` — the code moves into jac-scale's `plugin.jac`, and the command name stays exactly the same. The architecture is designed so that migration is a file move, not a rewrite.

**Two deployment topologies.** jac-scale apps run in two modes: a single-process monolith (`jac start`) or a gateway-plus-services microservice cluster. The tool supports both.

---

## HAR 1.2 Primer

A `.har` file is a JSON document produced by Chrome DevTools, Firefox, or any traffic recorder. It captures every HTTP transaction your browser made during a recording session.

### Structure

```
{
  "log": {
    "version": "1.2",
    "creator": { "name": "Chrome", "version": "..." },
    "pages": [ ... ],       ← page load events (we skip these)
    "entries": [ ... ]      ← HTTP transactions (this is what we care about)
  }
}
```

### Entry Object (one HTTP transaction)

```
entry
├── startedDateTime   ISO 8601 timestamp
├── time              total elapsed ms (sum of timings)
├── request
│   ├── method        GET / POST / PUT / DELETE / PATCH
│   ├── url           full absolute URL
│   ├── httpVersion   "HTTP/1.1" or "HTTP/2"
│   ├── headers       [ {name, value}, ... ]
│   ├── queryString   [ {name, value}, ... ]
│   ├── cookies       [ {name, value, domain, path, ...}, ... ]
│   ├── postData      { mimeType, text, params }   ← body (optional)
│   ├── headersSize   bytes (-1 if unknown)
│   └── bodySize      bytes (-1 if unknown)
├── response
│   ├── status        HTTP status code
│   ├── statusText    "OK", "Not Found", ...
│   ├── headers       [ {name, value}, ... ]
│   ├── content       { size, mimeType, text, encoding, compression }
│   ├── redirectURL   "" or redirect target
│   ├── headersSize   bytes
│   └── bodySize      bytes
├── cache             { beforeRequest, afterRequest }   ← we skip this
└── timings
    ├── blocked       ms waiting in browser queue     (-1 = N/A)
    ├── dns           ms for DNS resolution            (-1 = N/A)
    ├── connect       ms for TCP connect               (-1 = N/A)
    ├── ssl           ms for TLS handshake             (-1 = N/A)
    ├── send          ms to send request               (≥ 0, required)
    ├── wait          ms waiting for first byte (TTFB) (≥ 0, required)
    └── receive       ms to receive full response      (≥ 0, required)
```

### HAR 1.1 vs HAR 1.2

HAR 1.2 adds optional fields to 1.1. All additions are backward-compatible:

| Added in 1.2 | Where | Meaning |
|---|---|---|
| `ssl` | `timings` | TLS handshake duration |
| `comment` | most objects | Free-text annotation |
| `encoding` | `content` | e.g. `"base64"` for binary responses |
| `serverIPAddress` | `entry` | Resolved server IP |
| `connection` | `entry` | TCP connection ID |
| `secure` | cookie | HTTPS-only flag |

jac-loadtest targets HAR 1.2 but gracefully handles 1.1 files (all 1.2-only fields are optional).

### What We Parse vs Skip

| HAR field | We use it? | Reason |
|---|---|---|
| `entries[].request` | Yes — core replay data | |
| `entries[].timings.wait` | Yes — think-time source | TTFB = server processing time |
| `entries[].response.status` | Yes — logged for recording only | Not replayed; actual server decides |
| `entries[].response.content.mimeType` | Yes — filter logic | Skip image/*, font/*, text/css |
| `entries[].cache` | No | Not relevant for load replay |
| `pages` | No | Page-level metrics not needed |
| `creator` / `browser` | No | Metadata only |

### MIME Type Filter (default: skip static assets)

The following MIME types are skipped by default. These are static assets that add noise without testing server-side logic:

```
image/*         (image/png, image/jpeg, image/webp, image/svg+xml, ...)
font/*          (font/woff2, font/ttf, ...)
text/css
application/javascript / text/javascript   (JS bundles)
application/wasm
```

Kept by default:

```
application/json       ← API responses
text/html              ← server-rendered pages
application/xml
multipart/form-data    ← file uploads
application/x-www-form-urlencoded
```

Use `--include-static` to disable filtering and replay everything.

---

## Module Map

```
jac_loadtest/
├── plugin.py           Registers `jac loadtest` via jaclang CommandRegistry (entry-points hook)
├── cli.py              Argument parsing and module wiring — called by plugin.py
├── config.py           LoadTestConfig — three-layer resolution: jac.toml → CLI flags → defaults
│
├── core/               ← NO jac-scale knowledge. Works with any HTTP server.
│   ├── har_parser.py   Parse HAR 1.2, filter entries, rewrite URLs
│   ├── engine.py       asyncio VU pool, ramp-up, RPS cap, duration/iteration control
│   └── metrics.py      Per-request recording, latency histograms, percentile calc
│
├── bridge/             ← jac-scale-aware layer. Thin adapters over core.
│   ├── auth.py         Login via jac-scale /user/login, per-VU JWT injection
│   └── topology.py     Build prefix→URL routing table from jac-scale ServiceRegistry
│
└── output/
    └── reporter.py     Console (Rich), JSON, HTML report rendering
```

### Dependency Rules

```
plugin.py
  └── imports from jaclang.cli.registry — registers `jac loadtest` subcommand

cli.py
  └── registers JacMetaImporter (must happen before any jac_scale import)
  └── uses config, core/*, bridge/*, output/

core/*          depends on: standard library + aiohttp only
bridge/auth     depends on: core/har_parser, aiohttp
bridge/topology depends on: jac_scale.config_loader, jac_scale.microservices.service_registry
output/*        depends on: core/metrics, rich
```

The `core/` modules must never import from `bridge/`. This is the hard boundary that makes the eventual migration to `jac-scale[loadtest]` a simple file move.

### Python and Package Requirements

```toml
[project]
requires-python = ">=3.12"    # hard floor set by jaclang and jac-scale

[project.dependencies]
jaclang   = "==0.15.2"
jac-scale = "==0.2.16"
rich      = ">=13.0.0"
# aiohttp comes transitively via jac-scale — do not declare separately
# tomllib is no longer needed — jac-scale config_loader handles jac.toml

[project.entry-points."jac"]
loadtest = "jac_loadtest.plugin:loadtest"
```

`[project.entry-points."jac"]` is the same mechanism jac-scale uses to register its own commands (`scale = "jac_scale.plugin:JacCmd"`). When `pip install jac-loadtest` runs, jaclang discovers `JacLoadtestCmd` at startup and `jac loadtest` appears alongside all other `jac` subcommands.

### plugin.py — Command Registration

`plugin.py` is the entry-point hook that registers `jac loadtest` with jaclang's `CommandRegistry`.

**Critical:** registration must happen at module import time via a module-level decorator. jaclang imports the module when it loads the entry-point — it does **not** instantiate `JacLoadtestCmd`. The class is an empty marker only.

```python
from jaclang.cli.registry import get_registry
from jaclang.cli.command import Arg, ArgKind

registry = get_registry()

@registry.command(
    name="loadtest",
    help="HAR-based load testing for jac-scale apps",
    args=[
        Arg.create("har_file", kind=ArgKind.POSITIONAL, help="Path to .har file"),
        Arg.create("url",      typ=str, default=None, short="", help="Target base URL"),
        Arg.create("vus",      typ=int, default=1,    short="", help="Number of virtual users"),
        Arg.create("duration", typ=str, default="30s",short="", help="Test duration (e.g. 30s, 2m)"),
        # ... remaining flags, all with short=""
    ],
    group="testing",
    source="jac-loadtest",
)
def loadtest(args: object) -> None:
    from jac_loadtest.cli import run
    run(args)
```

**API notes:**
- Use `Arg.create()`, not `Arg(...)`. The factory method signature is `Arg.create(name, kind=..., typ=..., default=..., help=..., short=...)`.
- `typ=bool` produces a boolean flag (no `ArgKind.FLAG` needed — the registry handles it).
- `Arg.create()` auto-generates a short flag from the first letter of the name. Pass `short=""` to disable — an empty string bypasses auto-generation and is falsy in `_add_argument`, so no short flag is added.

This is the only file in `jac_loadtest/` that imports from `jaclang.cli`. All test logic stays in `cli.py`, `core/`, `bridge/`, and `output/`.

### JacMetaImporter Bootstrap

`jac-scale`'s microservice modules are written in Jac and compiled to Python on the fly.
The meta importer must be registered at the very start of `cli.py` before any other import:

```python
from jaclang.meta_importer import JacMetaImporter
import sys
if not any(isinstance(f, JacMetaImporter) for f in sys.meta_path):
    sys.meta_path.insert(0, JacMetaImporter())
```

Without this, `from jac_scale.microservices.service_registry import ServiceRegistry` will fail.

---

## Config Resolution

`config.py` resolves all settings through a three-layer priority chain. CLI flags always
win; `jac.toml` provides project-level defaults; built-in defaults are the fallback when
neither is provided. This means a team can commit shared test settings in `jac.toml`
and override them per-run via CLI flags without changing the file.

### Fallback Chain

```
Priority 1 — CLI flag          (e.g. --vus 50)           ← always wins
Priority 2 — jac.toml          ([plugins.scale.loadtest]) ← project default
Priority 3 — Built-in default  (hardcoded in config.py)   ← always present
```

### How It Works

jac-scale's `PluginConfigBase` (from `jaclang.project.plugin_config`) handles jac.toml
reading, deep-merge with defaults, and caching automatically. `config.py` calls:

```python
from jac_scale.config_loader import get_scale_config

toml_config = get_scale_config().get_section("loadtest", defaults=BUILT_IN_DEFAULTS)
```

This reads `[plugins.scale.loadtest]` from `jac.toml`, deep-merging with built-in defaults
so missing keys always fall through to the default. CLI flags are then applied on top:

```python
LoadTestConfig(
    vus      = cli_args.vus      if cli_args.vus      is not None else toml_config["vus"],
    duration = cli_args.duration if cli_args.duration is not None else toml_config["duration"],
    timeout  = cli_args.timeout  if cli_args.timeout  is not None else toml_config["timeout"],
    # ... same pattern for all flags
)
```

If `jac.toml` does not exist, `get_scale_config()` returns all built-in defaults — the
tool works in any directory with no configuration file required.

### jac.toml Example

```toml
[plugins.scale.loadtest]
# Load shape
vus                   = 20
duration              = "60s"
ramp_up               = "10s"
timeout               = "30s"

# Traffic
mode                  = "monolith"
think_time            = "none"
rps                   = 0            # 0 = unlimited
include_static        = false

# Auth
login_path            = "/user/login"

# CI thresholds (team SLOs)
fail_on_error_rate    = 1.0          # percent
fail_on_p95           = 500          # ms
fail_on_p99           = 1000         # ms
threshold_start_delay = "30s"

# Output
report_format         = "console"
max_samples           = 1000000
```

### What stays CLI-only

Some settings are intentionally excluded from `jac.toml` — they change per run,
per environment, or contain sensitive data that must not be version-controlled:

| Flag | Reason |
|------|--------|
| `har_file` | Positional arg, different every run |
| `--url` | Changes between dev / staging / prod |
| `--credentials-file` | Security-sensitive — never commit |
| `--username` / `--password` | Security-sensitive |
| `--services-map` | Environment-specific URL overrides |
| `--report-out` | Output path changes per run |

### Phase 2 migration

When jac-loadtest is absorbed into jac-scale, the `loadtest` section is added to
`JacScalePluginConfig.get_config_schema()` as a new nested entry — the same pattern
used by `microservices`, `monitoring`, and `events`. Existing user `jac.toml` files
that already have `[plugins.scale.loadtest]` continue to work without any changes.

---

## End-to-End Data Flow

```mermaid
flowchart TD
    A[".har file"] --> B["HAR Parser\ncore/har_parser.py"]
    B --> C{"Filter entries\nMIME type check"}
    C -->|kept| D["HarEntry list\nordered"]
    C -->|dropped| Z1["discarded"]

    D --> E["Topology Module\nbridge/topology.py"]
    E --> F{"Mode?"}
    F -->|monolith| G["Single target URL\nfrom --url flag"]
    F -->|microservice| H["Read jac.toml\nbuild prefix to URL table"]

    G --> I["Load Engine\ncore/engine.py"]
    H --> I

    I --> J["Auth Module\nbridge/auth.py\nif credentials given"]
    J --> K["Per-VU JWT token"]
    K --> I

    I --> L["N Virtual Users\nasyncio coroutines"]
    L --> M["HTTP Requests\naiohttp"]
    M --> N["Target Server"]
    N --> M

    M --> O["Metrics Collector\ncore/metrics.py"]
    O --> P["RequestResult records\nlatency, status, endpoint"]
    P --> Q["Reporter\noutput/reporter.py"]
    Q --> R["Console / JSON / HTML"]
```

---

## Virtual User Lifecycle

Each virtual user (VU) is an `asyncio` coroutine. All VUs run concurrently within a single event loop.

```mermaid
stateDiagram-v2
    [*] --> Waiting : ramp-up delay

    Waiting --> Authenticating : credentials provided
    Waiting --> Iterating : no credentials

    Authenticating --> AuthFailed : login returned non-2xx
    Authenticating --> Iterating : got JWT token

    AuthFailed --> [*]

    Iterating --> SendingRequest : pick next HarEntry
    SendingRequest --> WaitingThinkTime : response received\nrecord latency and status
    WaitingThinkTime --> SendingRequest : next entry in sequence
    SendingRequest --> Iterating : all entries replayed\none iteration done

    Iterating --> [*] : duration elapsed\nor iteration cap reached
```

### Ramp-up

If `--ramp-up 10s --vus 50` is set, VU startup is staggered:

```
start_delay = ramp_up_seconds / num_vus

VU 1  starts at t=0.0s
VU 2  starts at t=0.2s
VU 3  starts at t=0.4s
...
VU 50 starts at t=9.8s
```

This avoids a thundering herd at test start and allows the server to warm up gradually, matching real-world traffic ramp patterns.

### RPS Cap (Token Bucket)

When `--rps N` is set, a shared `asyncio.Semaphore` with periodic token refill acts as a rate limiter. All VUs compete for tokens before sending each request. Tokens are refilled at `N tokens/second`. This enforces a global RPS ceiling regardless of how many VUs are running.

---

## HAR Parser

**File:** `core/har_parser.py`

### Inputs

- Path to `.har` file
- `base_url`: the recorded origin to replace (extracted automatically from the first HAR entry)
- `target_url`: the actual test target (from `--url` flag)
- `include_static`: bool — whether to skip the MIME type filter
- `login_path`: path to detect as the login entry (default `/user/login`)

### Output

An ordered list of `HarEntry` dataclass instances:

```python
@dataclass
class HarEntry:
    method: str                  # "GET", "POST", etc.
    url: str                     # rewritten URL (target_url + original path + query)
    headers: dict[str, str]      # sanitized request headers
    body: str | None             # postData.text or None
    body_mime: str | None        # postData.mimeType
    think_time_ms: float         # timings.wait from HAR recording
    is_login: bool               # True if path matches login_path
    original_url: str            # original recorded URL (for debugging/logging)
```

### URL Rewriting

The recorded HAR contains absolute URLs pointing to wherever the recording was made. We replace only the origin (scheme + host + port), preserving path and query string exactly:

```
HAR URL:    http://localhost:8000/walker/search?q=hello
target_url: http://staging.myapp.com:9000
Result:     http://staging.myapp.com:9000/walker/search?q=hello
```

### Security Warning

HAR files recorded in Chrome contain the original session's credentials — Authorization
headers (JWT tokens, API keys) and Cookie headers — from the moment of recording.

At startup, the parser scans all HAR request headers. If any entry contains an
`Authorization` or `Cookie` header with a non-empty value, a warning is printed to stderr:

```
Warning: HAR file contains Authorization/Cookie headers from the recording session.
These headers are stripped before replay, but the file itself contains sensitive data.
Do not commit this HAR file to version control.
```

This is a warning only — the tool still runs. The sensitive headers are stripped
during Header Sanitization below and never sent to the target server.

### Header Sanitization

These headers are stripped before replay — they are session-specific and are set fresh at runtime:

```
Authorization   replaced by auth module with fresh JWT
Cookie          managed by per-VU aiohttp cookie jar
Host            set by aiohttp based on target URL
Content-Length  recalculated by aiohttp from body
```

### Think Time

`timings.wait` in the HAR represents the server's response time as observed by the browser (Time To First Byte). It is the most meaningful inter-request pacing value because it reflects realistic user wait time.

| Mode | Behaviour |
|---|---|
| `none` (default) | No delay between requests — maximum stress |
| `real` | Wait exactly `timings.wait` ms between each request |
| `scaled` | Wait `timings.wait * scale_factor` ms (e.g. `--think-time-scale 0.5`) |

---

## Load Engine

**File:** `core/engine.py`

### Concurrency Model

```python
async def run_all_vus(entries, config, topology, auth_provider, metrics):
    tasks = []
    for vu_id in range(config.vus):
        delay = (vu_id / config.vus) * config.ramp_up_seconds
        task = asyncio.create_task(run_vu(vu_id, delay, entries, ...))
        tasks.append(task)
    await asyncio.gather(*tasks)
```

Each VU is an independent coroutine. There is no shared mutable state between VUs — each has its own:
- `aiohttp.ClientSession` (owns cookie jar, connection pool, and timeout config)
- JWT token (set during auth phase)
- Iteration counter and request sequence position

### Request Timeout

Each VU's `ClientSession` is created with a configurable timeout. Without this, a VU waiting
on a hung server blocks indefinitely and the test never ends.

```python
timeout = aiohttp.ClientTimeout(total=config.timeout_seconds)
session = aiohttp.ClientSession(timeout=timeout)
```

Controlled by `--timeout 30s` (default: 30 seconds). Timed-out requests are recorded as
`error_type="TIMEOUT"` with `status=0` and `latency_ms` equal to the timeout value.

### Request Execution

```python
async def send_request(session, entry, token, rps_limiter):
    async with rps_limiter:          # acquire RPS token if cap is set
        headers = {**entry.headers}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        t_start = loop.time()
        try:
            async with session.request(
                entry.method,
                entry.url,
                headers=headers,
                data=entry.body,
                allow_redirects=False,   # record the redirect itself, not its destination
            ) as resp:
                t_end = loop.time()
                return RequestResult(
                    endpoint=normalize_path(entry.url),
                    status=resp.status,
                    latency_ms=(t_end - t_start) * 1000,
                    bytes_received=resp.content_length or 0,
                    timestamp=t_start,
                    error_type=None,
                )
        except asyncio.TimeoutError:
            return RequestResult(endpoint=normalize_path(entry.url), status=0,
                                 latency_ms=config.timeout_seconds * 1000,
                                 bytes_received=0, timestamp=t_start, error_type="TIMEOUT")
        except aiohttp.ClientConnectorError:
            return RequestResult(endpoint=normalize_path(entry.url), status=0,
                                 latency_ms=0, bytes_received=0, timestamp=t_start,
                                 error_type="CONNECTION_REFUSED")
```

### Duration vs Iteration Control

| Mode | Config | Behaviour |
|---|---|---|
| Duration | `--duration 30s` | Each VU runs until wall clock exceeds start + duration |
| Iterations | `--iterations 100` | Each VU stops after completing 100 full HAR replays |
| Both | both set | First limit reached wins |

### Graceful Shutdown (Two-Signal Model)

Adopted from k6. A single Ctrl+C does not kill the process immediately — it allows
in-flight work to complete and generates a partial report from data collected so far.

| Signal | Behaviour |
|--------|-----------|
| First SIGINT (Ctrl+C) | Set shared `stop_requested: asyncio.Event`. VUs finish their current iteration then exit. Report is generated from all data collected up to this point. |
| Second SIGINT | Immediate abort. No report generated. |

```python
stop_requested = asyncio.Event()

async def run_vu(vu_id, ...):
    while not stop_requested.is_set():
        if duration_elapsed or iteration_cap_reached:
            break
        await replay_one_iteration(...)
```

The signal handler sets `stop_requested` on first SIGINT, then registers a hard-exit
handler for the second. This ensures a 10-minute test interrupted at minute 9 still
produces a useful partial report.

---

## Exit Codes and Thresholds

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Test completed normally and all thresholds passed |
| `1` | One or more thresholds failed |
| `2` | Tool or config error (malformed HAR, connection refused at start, invalid flags) |

This allows CI pipelines to gate deployments:

```bash
jac loadtest recording.har --url http://staging:8000 --vus 20 \
  --fail-on-error-rate 1 --fail-on-p95 500
echo $?   # 0 = passed, 1 = threshold failed, 2 = tool error
```

### Threshold Flags

| Flag | Description |
|------|-------------|
| `--fail-on-error-rate N` | Exit 1 if error rate exceeds N percent (e.g. `--fail-on-error-rate 1`) |
| `--fail-on-p95 N` | Exit 1 if p95 latency exceeds N milliseconds |
| `--fail-on-p99 N` | Exit 1 if p99 latency exceeds N milliseconds |
| `--abort-on-fail` | Stop test immediately when any threshold is breached (k6 `abortOnFail`) |
| `--threshold-start-delay Ns` | Do not evaluate thresholds until N seconds into the run (default `0s`) |

### Threshold Start Delay

The server is cold at test start — JIT not warmed, caches empty, connection pools not
established. Early latency spikes would falsely fail a `--fail-on-p95` threshold.

`--threshold-start-delay 30s` defers pass/fail evaluation until 30 seconds into the run.
Metrics are still **collected** from t=0 and appear in the report — only the threshold
check is delayed. This is the same as k6's `delayAbortEval` pattern.

```
t=0s  ─── metrics collected, thresholds NOT evaluated
t=30s ─── threshold evaluation begins
t=60s ─── test ends, final threshold check, exit code set
```

---

## Auth Module

**File:** `bridge/auth.py`

This module is jac-scale-aware. It knows the `/user/login` endpoint request and response shape.

### Login Flow

Before the test starts, each VU authenticates independently:

```mermaid
sequenceDiagram
    participant VU as Virtual User N
    participant Auth as Auth Module
    participant Server as jac-scale Server

    VU->>Auth: get_token(vu_id, credentials_list)
    Auth->>Server: POST /user/login
    Note right of Server: {"identity": {...},<br/>"credential": {...}}
    Server-->>Auth: {"ok": true, "data": {"token": "eyJ..."}}
    Auth->>VU: JWT token string
```

### Credentials Assignment

If `--credentials-file creds.csv` is provided:
- Row `i` is assigned to VU `i`
- If there are fewer rows than VUs, credentials wrap around: VU N gets row `N % num_rows`

If only `--username` / `--password` flags are given:
- All VUs share the same login credentials — each gets a separate fresh token from the server

If no credentials are provided:
- No login step — requests are sent without `Authorization` header
- Suitable for testing `:pub` walkers that require no authentication

### jac-scale Login Request Shape

```json
POST /user/login
{
  "identity": {
    "type": "username",
    "value": "myuser"
  },
  "credential": {
    "type": "password",
    "password": "secret"
  }
}
```

Response on success (HTTP 200):

```json
{
  "ok": true,
  "data": {
    "token": "eyJ...",
    "user_id": "550e8400-...",
    "role": "user"
  }
}
```

`data.token` is extracted and injected as `Authorization: Bearer <token>` on all subsequent requests for that VU.

### Cookie Jar

Each VU's `aiohttp.ClientSession` maintains its own `aiohttp.CookieJar`. Cookies set during login are automatically included in subsequent requests. This mirrors real browser session behaviour.

### CSRF (Optional, `--csrf` flag)

jac-scale itself does not use CSRF tokens — it uses JWT. CSRF only matters if a reverse proxy adds CSRF protection in front of the jac-scale server. When `--csrf` is enabled:

1. After login, scan response `Set-Cookie` headers for a cookie named `csrftoken` or `_csrf`
2. Extract its value
3. Inject `X-CSRFToken: <value>` header on all subsequent non-GET requests for that VU
4. Rotate the value if a new token arrives in a subsequent response

---

## Topology Module

**File:** `bridge/topology.py`

Translates a HAR entry's path into the correct target server URL. The behaviour differs between the two deployment modes.

### Monolith Mode

All requests route to the single `--url` value. Only the origin is replaced; path and query string are preserved from the HAR entry.

```
entry.url = "http://recorded-host:8000/walker/search?q=test"
--url      = "http://staging.app.com:9000"
result     = "http://staging.app.com:9000/walker/search?q=test"
```

### Microservice Mode

In microservice mode, jac-scale runs a **gateway** that routes requests to individual services by URL path prefix (implemented in `jac-scale/jac_scale/microservices/service_registry.jac` as `ServiceRegistry.match_route()`). Our tool replicates this routing so it can send requests directly to individual services, bypassing the gateway. This lets us measure per-service latency independently.

#### Reading jac.toml

The routing table is built from the project's `jac.toml`:

```toml
[plugins.scale.microservices]
enabled = true

[[plugins.scale.microservices.services]]
name   = "order_service"
file   = "order_service.jac"
prefix = "/walker/order"
port   = 18001

[[plugins.scale.microservices.services]]
name   = "inventory_service"
file   = "inventory_service.jac"
prefix = "/walker/inventory"
port   = 18002
```

This produces the routing table:

```python
{
    "/walker/order":     "http://localhost:18001",
    "/walker/inventory": "http://localhost:18002",
}
```

#### Longest-Prefix Routing

This mirrors jac-scale's `ServiceRegistry.match_route()` algorithm exactly. Given a request path, prefixes are sorted by length descending — the longest matching prefix wins:

```mermaid
flowchart LR
    A["Request path:\n/walker/order/create"] --> B["Sort prefixes by length DESC"]
    B --> C["/walker/order\n/walker/inventory\n/walker\n/user"]
    C --> D{"Does path start\nwith this prefix?"}
    D -->|yes| E["Route to\nhttp://localhost:18001"]
    D -->|no, try next| D
```

#### Service URL Resolution

Each service URL is `http://localhost:<port>` by default, using the port from `jac.toml`. For remote or CI deployments where no `jac.toml` is present, use `--services-map` instead:

```bash
jac-loadtest recording.har --mode microservice \
  --services-map '{"order_service": "http://order.internal:8001"}'
```

`--services-map` bypasses `jac.toml` entirely — use it when there is no `jac.toml` or when you want to override all service URLs at once.

#### Fallback

If a request path does not match any service prefix, it is routed to `--url` (the gateway). If `--url` is also not set, the request is skipped and a warning is emitted.

---

## Metrics Collector

**File:** `core/metrics.py`

### Per-Request Record

```python
@dataclass
class RequestResult:
    endpoint: str           # normalized: "POST /walker/search"
    service: str            # service name or "monolith"
    status: int             # HTTP status code; 0 if network-level error
    latency_ms: float       # request dispatch to response received
    bytes_received: int     # response body bytes
    timestamp: float        # unix timestamp of request start
    vu_id: int              # which VU sent this
    error_type: str | None  # None = HTTP response received (any status)
                            # "TIMEOUT", "CONNECTION_REFUSED", "DNS_ERROR", "SSL_ERROR"
```

When `error_type` is set, `status` is always `0`. This distinguishes network-level
failures (no response at all) from HTTP-level errors (server responded with 4xx/5xx).

### Three-Layer Metrics Storage

Metrics are stored in three independent layers to handle long runs correctly:

```
Layer 1 — total_count: int
  Incremented on every request, never dropped.
  Used for RPS: total_count / elapsed_seconds.

Layer 2 — deque(maxlen=--max-samples) of RequestResult
  Bounded raw samples for percentile calculation.
  Oldest results are dropped when the deque is full (long runs only).
  --max-samples default: 1,000,000.

Layer 3 — list[StatsSnapshot] (one entry per 5 seconds)
  Aggregated stats at each interval: p50, p95, p99, rps, error_rate.
  Written every 5 seconds during the run. Never dropped.
  Used for the RPS-over-time and latency-over-time charts in HTML report.
```

This design ensures RPS is always accurate (Layer 1 never drops), percentile
calculation uses recent samples (Layer 2 bounded), and time-series charts are
available for the full run duration (Layer 3 complete history).

### Aggregation

After the run, stats are computed per endpoint (and per service in microservice mode):

```python
@dataclass
class EndpointStats:
    endpoint: str
    service: str
    total_requests: int
    success_count: int           # 2xx responses
    error_count: int             # non-2xx + network errors
    success_rate_pct: float
    min_ms: float
    max_ms: float
    mean_ms: float
    p50_ms: float                # median
    p95_ms: float
    p99_ms: float
    rps: float                   # from Layer 1 total_count / test_duration_seconds
    error_breakdown: dict[str, int]  # {"500": 3, "TIMEOUT": 2, "CONNECTION_REFUSED": 1}
```

Note: `error_breakdown` keys are strings — either HTTP status codes (`"500"`, `"404"`)
or network error type names (`"TIMEOUT"`, `"CONNECTION_REFUSED"`).

### Endpoint Normalization

`normalize_path()` in `core/metrics.py` is applied to every URL before storing
the `endpoint` field. UUID and integer path segments are replaced with `{id}`:

```
/walker/user/123         → /walker/user/{id}
/walker/order/abc-def-0  → /walker/order/{id}
/walker/search           → /walker/search        (unchanged)
```

Detection rules:
- Pure integer segment: `^\d+$`
- UUID segment: `^[0-9a-f-]{32,36}$` (with or without hyphens)

Without normalization, `/walker/user/123` and `/walker/user/456` appear as two
separate rows in the report — useless at scale.

### Percentile Calculation

Uses the nearest-rank method on sorted latency values. No external dependencies:

```python
def percentile(latencies: list[float], p: float) -> float:
    if not latencies:
        return 0.0
    sorted_l = sorted(latencies)
    idx = int(math.ceil(p / 100.0 * len(sorted_l))) - 1
    return sorted_l[max(0, idx)]
```

---

## Reporter

**File:** `output/reporter.py`

### stdout vs stderr

All human-readable output goes to **stderr**. Machine-readable output goes to **stdout**
(or to a file when `--report-out` is set). This separation is critical for CI pipelines
that parse stdout — mixing progress output into stdout breaks `jq` and similar tools.

| Output type | Stream |
|-------------|--------|
| Live progress bar | stderr |
| `--debug` per-request lines | stderr |
| Console summary table | stderr |
| Warning messages (HAR security, missing services) | stderr |
| `--report-format json` content | stdout (or file if `--report-out` set) |
| `--report-format html` content | file only — never written to stdout |

### Console Output (default)

Uses the `rich` library for formatted terminal output.

**Live progress during run:**

```
Running load test ━━━━━━━━━━━━━━━━━━━━ 45%  0:00:16 remaining  VUs: 10  RPS: 47.3
```

**Summary table after run:**

```
┌─────────────────────────────┬───────┬──────┬──────┬──────┬──────┬───────┬───────┐
│ Endpoint                    │ Reqs  │  OK% │  p50 │  p95 │  p99 │  RPS  │ Errs  │
├─────────────────────────────┼───────┼──────┼──────┼──────┼──────┼───────┼───────┤
│ POST /walker/search         │  2341 │ 99.8 │  45ms│ 210ms│ 890ms│  78.0 │   5   │
│ POST /walker/get_users      │  1170 │ 100  │  12ms│  38ms│  95ms│  39.0 │   0   │
│ POST /user/login            │    10 │ 100  │  88ms│  92ms│  94ms│   0.3 │   0   │
├─────────────────────────────┼───────┼──────┼──────┼──────┼──────┼───────┼───────┤
│ TOTAL                       │  3521 │ 99.9 │  28ms│ 145ms│ 712ms│ 117.3 │   5   │
└─────────────────────────────┴───────┴──────┴──────┴──────┴──────┴───────┴───────┘

Duration: 30.0s   VUs: 10   Ramp-up: 5s   Mode: monolith
```

In microservice mode, an additional table groups stats by service name.

### JSON Output (`--report-format json`)

Machine-readable format for CI pipelines:

```json
{
  "meta": {
    "har_file": "recording.har",
    "target_url": "http://localhost:8000",
    "vus": 10,
    "duration_s": 30,
    "ramp_up_s": 5,
    "mode": "monolith",
    "started_at": "2026-05-18T14:23:00Z",
    "finished_at": "2026-05-18T14:23:30Z"
  },
  "summary": {
    "total_requests": 3521,
    "success_rate_pct": 99.9,
    "overall_rps": 117.3,
    "p50_ms": 28,
    "p95_ms": 145,
    "p99_ms": 712
  },
  "endpoints": [
    {
      "endpoint": "POST /walker/search",
      "service": "monolith",
      "total_requests": 2341,
      "success_rate_pct": 99.8,
      "p50_ms": 45,
      "p95_ms": 210,
      "p99_ms": 890,
      "rps": 78.0,
      "error_breakdown": { "500": 5 }
    }
  ]
}
```

### HTML Output (`--report-format html`)

Self-contained HTML file. Chart.js is embedded inline so no internet access is needed at render time. Contains:

- Summary cards (total requests, success rate, overall p95)
- Latency distribution bar chart per endpoint
- RPS-over-time line chart (using `timestamp` from each `RequestResult`)
- Full endpoint stats table

---

## CLI Reference

### Command

```bash
jac loadtest <har_file> [options]
```

The `jac loadtest` subcommand is available after `pip install jac-loadtest` — no separate binary, no PATH changes. It is registered via `[project.entry-points."jac"]` and appears alongside all other `jac` subcommands (`jac start`, `jac deploy`, etc.).

### All Flags

CLI flags always override `jac.toml`. The `jac.toml?` column marks which flags can also
be set under `[plugins.scale.loadtest]` in your project's `jac.toml`.

| Flag | Default | jac.toml? | Description |
|---|---|---|---|
| `har_file` | required | No | Path to `.har` file |
| `--url` / `-u` | required in monolith mode | No | Target base URL — changes per environment |
| `--mode` | `monolith` | Yes | `monolith` or `microservice` |
| `--vus` / `-v` | `1` | Yes | Number of virtual users |
| `--duration` / `-d` | `30s` | Yes | Test duration. Accepts `30s`, `2m`, `1h` |
| `--iterations` | — | Yes | Iteration cap per VU. Alternative to `--duration`. |
| `--ramp-up` | `0s` | Yes | Time to ramp up to full VU count |
| `--timeout` | `30s` | Yes | Per-request timeout. Exceeded requests recorded as TIMEOUT error. |
| `--think-time` | `none` | Yes | `none`, `real`, or `scaled` |
| `--think-time-scale` | `1.0` | Yes | Multiplier used when `--think-time scaled` |
| `--username` | — | No | Security-sensitive — CLI only |
| `--password` | — | No | Security-sensitive — CLI only |
| `--credentials-file` | — | No | Security-sensitive — CLI only |
| `--login-path` | `/user/login` | Yes | URL path to detect as the login entry |
| `--include-static` | false | Yes | Do not skip image/font/CSS entries |
| `--rps` | unlimited | Yes | Global requests-per-second cap |
| `--max-samples` | `1000000` | Yes | Max raw request records to keep in memory (Layer 2) |
| `--services-map` | — | No | Environment-specific URL overrides — CLI only |
| `--csrf` | false | Yes | Enable CSRF token detection and injection |
| `--fail-on-error-rate` | — | Yes | Exit 1 if error rate exceeds N percent (e.g. `1.0`) |
| `--fail-on-p95` | — | Yes | Exit 1 if p95 latency exceeds N milliseconds |
| `--fail-on-p99` | — | Yes | Exit 1 if p99 latency exceeds N milliseconds |
| `--abort-on-fail` | false | Yes | Stop test immediately when any threshold is breached |
| `--threshold-start-delay` | `0s` | Yes | Delay threshold evaluation N seconds from test start |
| `--report-format` | `console` | Yes | `console`, `json`, or `html` |
| `--report-out` | — | No | Output path changes per run — CLI only |
| `--debug` | false | No | Print each request and response status to stderr during run |

### Examples

```bash
# Minimal: 1 VU, 30 seconds
jac loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up, 60s duration
jac loadtest recording.har --url http://localhost:8000 \
  --vus 50 --ramp-up 10s --duration 60s

# Authenticated test with per-VU credentials
jac loadtest recording.har --url http://localhost:8000 \
  --vus 20 --duration 30s --credentials-file creds.csv

# Realistic pacing using recorded think times
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 60s --think-time real

# Microservice mode — reads jac.toml from current directory
jac loadtest recording.har --mode microservice \
  --vus 30 --duration 60s

# Microservice mode with explicit remote service URLs
jac loadtest recording.har --mode microservice \
  --services-map '{"order_service":"http://order.svc:8001","inventory_service":"http://inv.svc:8002"}' \
  --vus 30 --duration 60s

# HTML report
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 30s --report-format html --report-out results.html

# JSON report for CI assertions
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 30s --report-format json --report-out results.json
```

---

## Extension Points

The architecture is designed so migrating from standalone `jac-loadtest` to `jac-scale[loadtest]` requires no rewrite — only relocation and wiring.

### Core stays pure

`core/har_parser.py`, `core/engine.py`, and `core/metrics.py` have zero imports from jac-scale. They are independently testable against any HTTP server.

### Three-Phase Migration Path

```
Phase 1 — Standalone PyPI package (current)
  Published as jac-loadtest on PyPI.
  plugin.py registers `jac loadtest` via [project.entry-points."jac"].
  bridge/topology.py imports jac_scale config_loader + ServiceRegistry via JacMetaImporter.
  bridge/auth.py makes HTTP POST to /user/login.

Phase 2 — Native jac-scale integration
  Tool absorbed as pip install jac-scale[loadtest].
  core/ and output/ modules move into jac_scale/loadtest/ unchanged.
  bridge/auth.py swaps HTTP call for in-process UserManager access.
  bridge/topology.py swaps disk read for in-memory ServiceRegistry access.
  plugin.py entry point replaced by @registry.command("loadtest", ...) in jac-scale's plugin.jac.
  Command stays `jac loadtest` — no user-visible change.

Phase 3 — Jac rewrite (optional, future)
  Tool modules rewritten in Jac using JacRuntime.
  Only pursued if the team adopts Jac as the primary language for this codebase.
```

Each phase is a module-level change. The hard boundary between `core/` and `bridge/`
is what makes each transition a file move rather than a rewrite.

### Bridge layer is the migration seam

In Phase 2, the changes are confined to `bridge/` and `plugin.py` only:

- `bridge/auth.py` gains access to jac-scale's `UserManager` in-process instead of making HTTP calls to `/user/login`
- `bridge/topology.py` gains access to jac-scale's in-memory `ServiceRegistry` directly instead of reading `jac.toml` from disk
- `plugin.py` is replaced by a `@registry.command("loadtest", ...)` block in jac-scale's `plugin.jac`

### Future additions (out of scope for Phase 1)

| Feature | Location | Notes |
|---|---|---|
| InfluxDB metrics push | `output/influxdb_sink.py` | Same pattern as hargo's `influxdb.go` |
| Prometheus metrics endpoint | `output/prometheus_sink.py` | Expose `/metrics` during run |
| WebSocket replay | `core/ws_engine.py` | Handle `ws://` entries in HAR |
| HAR validation command | `cli.py` subcommand | Verify HAR schema before running |
| `--engine k6` | `core/k6_engine.py` | Convert HAR → k6 script, invoke k6 as subprocess for high VU counts |
| Distributed load generation | separate orchestrator | Coordinate multiple `jac-loadtest` worker processes |

---

## Constraints and Known Limitations

### Python asyncio VU ceiling

Python's GIL means all VU coroutines share one OS thread. For pure I/O-bound HTTP workloads, asyncio scales well to approximately **200–500 concurrent VUs** on a modern machine before event loop overhead becomes the bottleneck. Beyond this ceiling:

- Run multiple `jac-loadtest` processes in parallel and merge the JSON reports
- Use `--engine k6` (future feature) which invokes the k6 binary with no GIL constraint

This limit is sufficient for validating dev and staging deployments. Production-scale stress testing requiring thousands of VUs is out of scope for Phase 1.

### HAR session diversity problem

A HAR file records one user session. Multi-VU replay means N identical request sequences. This:
- Tests the server under concurrent identical load — valid for throughput measurement
- Does NOT simulate N distinct users with different data access patterns
- May produce unrealistically warm server-side cache hits

Mitigation: `--credentials-file` gives each VU a distinct user identity. Application-level data diversity (different query values per VU) requires parameterization, which is a future roadmap item.

### No response assertion

The tool only measures latency and HTTP status codes. It does not assert on response body content. A request that returns HTTP 200 with an error payload will be counted as a success. Functional correctness testing is out of scope — use dedicated integration tests for that.
This is by design — load testing is about performance, not correctness. Your integration tests handle correctness.

### jac.toml required for microservice auto-discovery

In microservice mode there are exactly two ways to provide service URLs:

| Situation | What to use |
|-----------|-------------|
| Running from a jac project directory | Auto-discovery reads `./jac.toml` — nothing extra needed |
| CI, remote host, or no `jac.toml` present | `--services-map '{"svc": "http://host:port"}'` |

If neither is available the tool exits with a clear error listing what was tried. The `--jac-toml` flag does not exist — use `--services-map` instead of pointing at a file in another directory.

### No distributed load generation

All VUs run on the single machine executing `jac-loadtest`. The tool cannot coordinate load across multiple machines. Distributed testing is explicitly out of scope for Phase 1 due to orchestration complexity.

### CSRF support is best-effort

CSRF token handling assumes standard cookie names (`csrftoken`, `_csrf`) and standard header name (`X-CSRFToken`). Non-standard CSRF implementations are not supported. Since jac-scale does not use CSRF by default, this is a rare edge case and the feature is opt-in via `--csrf`.
