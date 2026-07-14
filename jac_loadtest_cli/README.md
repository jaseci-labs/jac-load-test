# jac-loadtest-cli

HAR-based load testing CLI built on [Jac](https://github.com/jaseci-labs/jaseci). Capture real browser traffic via Chrome DevTools, export it as a `.har` file, and replay it under load — no scripting required.

The tool registers itself as a `jac` subcommand, so after installation you run `jac loadtest` alongside `jac start`, `jac deploy`, and the rest of the jac ecosystem.

> **Compatibility:** Works with any HTTP server — jac-scale, Django, FastAPI, Node.js, etc. The only jac-scale-specific feature is auth: if your app uses jac-scale's `/user/login` JWT flow, credentials are automatically handled. For other auth schemes the raw request from the HAR is replayed as-is.

## Testing Modes

**Monolith mode** (default) — all requests go through a single `--url`. Use this for production-realistic load testing: it measures what users actually experience end-to-end through the gateway.

**Microservice mode** — route requests directly to individual service processes by URL path prefix. Use this locally or inside your cluster to isolate per-service latency and identify which service is the bottleneck — without gateway overhead masking the signal.

```bash
# Monolith: all traffic through the gateway
jac loadtest recording.har --url http://localhost:8000 --vus 10 --iterations 20

# Microservice: bypass gateway, route by path prefix to individual services
jac loadtest recording.har --mode microservice \
  --url http://localhost:8000 \
  --services-map '{"order_service":"http://localhost:18001","inventory_service":"http://localhost:18002"}' \
  --vus 10 --iterations 20
```

> **Note:** Microservice mode requires direct network access to service ports. This means it's only usable locally (`jac serve`) or from inside a Kubernetes cluster — not from outside production. For remote or production load testing, use monolith mode.

## Quick Start

```bash
# Minimal: 1 VU, 1 HAR replay
jac loadtest recording.har --url http://localhost:8000

# 50 VUs, each replaying the HAR 100 times, with 10s ramp-up
jac loadtest recording.har --url http://localhost:8000 \
  --vus 50 --iterations 100 --ramp-up 10s

# Realistic pacing: replay at recorded think times, halved
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --iterations 30 --think-time scaled --think-time-scale 0.5

# Rate-limited stress test: cap global throughput to 50 req/s
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --iterations 50 --rps 50

# CI gate: fail if p95 > 500ms or error rate > 1%, stop early on first breach
jac loadtest recording.har --url http://staging:8000 \
  --vus 20 --iterations 100 \
  --fail-on-p95 500 --fail-on-error-rate 1 \
  --threshold-start-delay 10s --abort-on-fail

# Per-request debug output
jac loadtest recording.har --url http://localhost:8000 --vus 2 --iterations 5 --debug
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Test completed; all thresholds passed (or none configured) |
| `1` | At least one threshold failed (`--fail-on-error-rate`, `--fail-on-p95`, `--fail-on-p99`) |
| `2` | Config or tool error (missing flag, bad HAR file, auth failure) |

Failed thresholds are printed to stderr before exit:

```
THRESHOLD FAILED: error_rate 3.2% > limit 1.0%
THRESHOLD FAILED: p95 612.4ms > limit 500.0ms
```

## Key Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vus` | `1` | Concurrent virtual users (asyncio coroutines per worker) |
| `--iterations` | `1` | Stop each VU after N full HAR replays |
| `--ramp-up` | `0s` | Stagger VU startup — prevents thundering herd at test start |
| `--workers` | CPU count | Worker processes; each runs its own event loop (capped at `--vus` and CPU count) |
| `--rps` | `0` (unlimited) | Global requests-per-second cap across all VUs |
| `--timeout` | `30s` | Per-request timeout; exceeded requests are recorded as `TIMEOUT` errors |
| `--think-time` | `none` | `none` / `real` / `scaled` — inter-request delay from HAR timings |
| `--think-time-scale` | `1.0` | Multiplier on think times (`0.5` = half speed, `2.0` = double) |
| `--fail-on-error-rate` | — | Fail (exit 1) if global error rate exceeds N% |
| `--fail-on-p95` | — | Fail (exit 1) if global p95 latency exceeds N ms |
| `--fail-on-p99` | — | Fail (exit 1) if global p99 latency exceeds N ms |
| `--threshold-start-delay` | `0s` | Ignore threshold checks for this long after the test starts |
| `--abort-on-fail` | `false` | Stop the test immediately when a threshold is first breached |
| `--debug` | `false` | Print one line per request to stderr: VU ID, endpoint, status, latency |
| `--report-format` | `console` | `console` / `json` / `html` |
| `--report-out` | — | Write report to file (required for `--report-format html`) |

See [docs/COMMANDS.md](docs/COMMANDS.md) for the full flag reference including microservice mode, auth, and `jac.toml` configuration.

## Authentication

The tool auto-detects the login request in the HAR by matching `--login-path` (default `/user/login`). At test start each VU logs in once and injects the returned JWT into all subsequent requests.

```bash
# All VUs log in with the same account used during HAR recording
jac loadtest recording.har --url http://localhost:8000 \
  --username admin@example.com --password secret
```

## Developer Setup

```bash
# 1. Navigate to the CLI directory
cd jac_loadtest_cli

# 2. Install the package in editable mode (also installs runtime deps)
jac install -e .

# 3. Verify the command is registered
jac loadtest --help
```

### Running tests

```bash
cd jac_loadtest_cli
jac test tests/          # all 148 tests
jac test tests/unit/     # unit tests only
jac test tests/integration/  # integration tests (needs aiohttp servers)
```

### Mock service for local testing

The `scripts/mock_service.jac` script spins up lightweight HTTP servers to test against without a real backend:

```bash
# Start two fake services on ports 8001 and 8002
jac run scripts/mock_service.jac -- order_service:8001 inventory_service:8002
```

## Project Layout

```
jac_loadtest_cli/          ← sub-project root
├── scripts/
│   └── mock_service.jac   ← lightweight fake HTTP servers for local testing
└── jac_loadtest_cli/      ← Python package (importable as jac_loadtest_cli)
    ├── plugin.jac         ← registers `jac loadtest` via jaclang entry-points
    ├── cli.jac            ← argument wiring, run orchestration, exit codes
    ├── config.jac         ← LoadTestConfig + three-layer config resolution
    ├── headless.jac       ← run_test_headless() — CLI-free entry point for web/embedder use
    ├── core/
    │   ├── har_parser.jac     ← parse HAR 1.2, filter, URL rewrite
    │   ├── engine.jac         ← asyncio VU coroutines, RPS cap, threshold watcher
    │   ├── metrics.jac        ← RequestResult, MetricsCollector, p50/p95/p99
    │   └── process_runner.jac ← multi-process worker orchestration
    ├── bridge/
    │   ├── auth.jac       ← login detection, JWT injection, credential rotation
    │   └── topology.jac   ← TopologyRouter, longest-prefix matching
    └── output/
        └── reporter.jac   ← Rich console, JSON, HTML reporters
```

## HAR Compatibility

Tested with HAR **1.1** and **1.2** (the format exported by Chrome DevTools, Firefox, Postman, and Insomnia). Files from other versions are parsed with a warning — open an issue if something breaks.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — module map, data flow, design decisions
- [Commands](docs/COMMANDS.md) — full CLI flag reference
- [Roadmap](docs/COMBINED_ROADMAP.md) — delivery phases for CLI and web UI
- [Testing](docs/TESTING.md) — test strategy and coverage guide
