# jac-loadtest

Monorepo containing two projects:

| Project | Description |
|---|---|
| [`jac_loadtest_cli/`](jac_loadtest_cli/) | HAR-based load testing CLI — published to PyPI as `jac-loadtest-cli`. **Active development.** |
| [`jac_loadtest_web/`](jac_loadtest_web/) | Web application built on the CLI engine using jac-client. **Frozen at its Phase 6 MVP** — the project is CLI-first (see the [roadmap](jac_loadtest_cli/docs/ROADMAP.md)). |

---

## Prerequisites: Install Jac

Both projects run on the [Jac](https://github.com/jaseci-labs/jaseci) toolchain — install the `jac` binary before doing anything else:

```bash
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash
```

This installs a self-contained native `jac` binary to `~/.local/bin` (no system Python/pip required) and adds it to your `PATH`. Verify with:

```bash
jac -V
```

No system Python is needed: the `jac` binary bundles its own runtime (Python 3.14), and `jac install` builds the project-local venv (`.jac/venv`) from it.

> **Version pinning:** the toolchain is pinned to **`0.39.2`** in two places that must stay in
> step — `jac-version` in [`jac_loadtest_cli/jac.toml`](jac_loadtest_cli/jac.toml) and
> `JAC_VERSION` in `.github/workflows/{test,release}.yml`. **`jac-loadtest-cli` supports jac 0.39.2
> only.** Jac does not keep backward compatibility between releases: keywords stopped being valid
> identifiers, bare `list` / `dict` annotations became errors, and type checking now runs on every
> compile, so a different toolchain can reject this source outright (it does not compile on 0.34).
> The modules this project imports from jaclang move too (`jaclang.project.config` is used for
> `jac.toml` lookup). To match CI exactly:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash -s -- --version 0.39.2
> ```

---

## jac-loadtest-cli

HAR-based load testing CLI for [jac-scale](https://github.com/jaseci-labs/jaseci/tree/main/jac-scale) applications. Capture real browser traffic via Chrome DevTools, export it as a `.har` file, and replay it under load — no scripting required.

The tool installs as a console script into your project's jac venv, so after installation you run it with `jac x loadtest` alongside any other tool in `jac x --list`.

### Testing Modes

**Monolith mode** (default) — all requests go through a single `--url`. Use this for production-realistic load testing: it measures what users actually experience end-to-end through the gateway.

**Microservice mode** — route requests directly to individual service processes by URL path prefix. Use this locally or inside your cluster to isolate per-service latency and identify which service is the bottleneck — without gateway overhead masking the signal.

```bash
# Monolith: all traffic through the gateway (default, production-realistic)
jac x loadtest recording.har --url http://localhost:8000 --vus 10

# Microservice: bypass gateway, route by path prefix to individual services
jac x loadtest recording.har --mode microservice \
  --url http://localhost:8000 \
  --services-map '{"order_service":"http://localhost:18001","inventory_service":"http://localhost:18002"}' \
  --vus 10
```

> **Note:** Microservice mode requires direct network access to service ports. This means it's only usable locally (`jac serve`) or from inside a Kubernetes cluster — not from outside production. For remote or production load testing, use monolith mode.

### Quick Start

```bash
# Minimal: 1 VU, 1 iteration
jac x loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up, 100 iterations each
jac x loadtest recording.har --url http://localhost:8000 --vus 50 --ramp-up 10s --iterations 100

# CI-friendly with thresholds
jac x loadtest recording.har --url http://localhost:8000 \
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
jac x loadtest --help

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
    ├── plugin.jac             ← argparse CLI entry point, exposed as the `loadtest` console script
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
- [Roadmap](jac_loadtest_cli/docs/ROADMAP.md) — CLI/engine delivery phases and exit criteria
- [Constraints](jac_loadtest_cli/docs/CONSTRAINTS.md) — current known limitations
- [Market comparison](jac_loadtest_cli/docs/MARKET_COMPARISON.md) — vs. k6/JMeter/Gatling/Locust; the evidence base for the roadmap
- [Testing](jac_loadtest_cli/docs/TESTING.md) — test strategy and coverage guide
- [Upgrading](jac_loadtest_cli/docs/UPGRADING.md) — what changes between releases, and why your numbers may move

---

## jac-loadtest-web

Browser-based GUI that wraps the CLI engine using jac-client. **Frozen at its Phase 6 MVP** —
a working GUI for standard HTTP load testing (auth, workspace wizard, HAR upload, run form,
live dashboard, JSON/HTML download). The project is CLI-first; new capabilities land in the
CLI engine. See the [web roadmap](jac_loadtest_web/docs/ROADMAP.md).
