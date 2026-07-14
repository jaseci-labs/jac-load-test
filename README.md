# jac-loadtest

Monorepo containing two projects:

| Project | Description |
|---|---|
| [`jac_loadtest_cli/`](jac_loadtest_cli/) | HAR-based load testing CLI — published to PyPI as `jac-loadtest-cli` |
| [`jac_loadtest_web/`](jac_loadtest_web/) | Web application built on the CLI engine using jac-client |

---

## jac-loadtest-cli

HAR-based load testing CLI for [jac-scale](https://github.com/jaseci-labs/jaseci/tree/main/jac-scale) applications. Capture real browser traffic via Chrome DevTools, export it as a `.har` file, and replay it under load — no scripting required.

The tool registers itself as a `jac` subcommand, so after installation you run `jac loadtest` alongside `jac start`, `jac deploy`, and the rest of the jac ecosystem.

### Testing Modes

**Monolith mode** (default) — all requests go through a single `--url`. Use this for production-realistic load testing: it measures what users actually experience end-to-end through the gateway.

**Microservice mode** — route requests directly to individual service processes by URL path prefix. Use this locally or inside your cluster to isolate per-service latency and identify which service is the bottleneck — without gateway overhead masking the signal.

```bash
# Monolith: all traffic through the gateway (default, production-realistic)
jac loadtest recording.har --url http://localhost:8000 --vus 10

# Microservice: bypass gateway, route by path prefix to individual services
jac loadtest recording.har --mode microservice \
  --url http://localhost:8000 \
  --services-map '{"order_service":"http://localhost:18001","inventory_service":"http://localhost:18002"}' \
  --vus 10
```

> **Note:** Microservice mode requires direct network access to service ports. This means it's only usable locally (`jac serve`) or from inside a Kubernetes cluster — not from outside production. For remote or production load testing, use monolith mode.

### Quick Start

```bash
# Minimal: 1 VU, 1 iteration
jac loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up, 100 iterations each
jac loadtest recording.har --url http://localhost:8000 --vus 50 --ramp-up 10s --iterations 100

# CI-friendly with thresholds
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --iterations 50 --fail-on-p95 500 --fail-on-error-rate 1
```

### Developer Setup

```bash
# 1. Create and activate a conda env (Python 3.12 required)
conda create -n load python=3.12
conda activate load

# 2. Move into the CLI sub-project
cd jac_loadtest_cli

# 3. Install the package in editable mode (runtime deps only)
jac install -e .

# 4. Verify the command is registered
jac loadtest --help

# 5. Run the test suite
jac test tests/
```

### Project Layout

```
jac_loadtest_cli/              ← sub-project root
├── jac.toml                   ← package config and dependencies
├── docs/                      ← CLI documentation
├── scripts/                   ← developer utilities
├── tests/                     ← unit, integration, e2e tests
└── jac_loadtest_cli/          ← Python package (importable as jac_loadtest_cli)
    ├── plugin.jac             ← registers `jac loadtest` via jaclang entry-points
    ├── cli.jac                ← argument wiring and run orchestration
    ├── config.jac             ← LoadTestConfig dataclass (three-layer resolution)
    ├── core/                  ← HAR parser, load engine, metrics (no jac-scale knowledge)
    ├── bridge/                ← jac-scale-aware adapters (auth, topology)
    └── output/                ← console, JSON, HTML reporters
```

### HAR Compatibility

Tested with HAR **1.1** and **1.2** (the format exported by Chrome DevTools, Firefox, Postman, and Insomnia). Files from other versions are parsed with a warning — open an issue if something breaks.

### Documentation

- [Architecture](jac_loadtest_cli/docs/ARCHITECTURE.md) — module map, data flow, design decisions
- [Commands](jac_loadtest_cli/docs/COMMANDS.md) — full CLI flag reference
- [Roadmap](jac_loadtest_cli/docs/COMBINED_ROADMAP.md) — delivery phases and exit criteria
- [Testing](jac_loadtest_cli/docs/TESTING.md) — test strategy and coverage guide

---

## jac-loadtest-web

Browser-based GUI that wraps the CLI engine using jac-client. See [Web Roadmap](jac_loadtest_web/docs/COMBINED_ROADMAP.md) for the full product plan.
