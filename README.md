# jac-loadtest

HAR-based load testing CLI for [jac-scale](https://github.com/jaseci-labs/jaseci/tree/main/jac-scale) applications. Capture real browser traffic via Chrome DevTools, export it as a `.har` file, and replay it under load — no scripting required.

The tool registers itself as a `jac` subcommand, so after installation you run `jac loadtest` alongside `jac start`, `jac deploy`, and the rest of the jac ecosystem.

## Quick Start

```bash
# Minimal: 1 VU, 30s
jac loadtest recording.har --url http://localhost:8000

# 50 VUs with 10s ramp-up
jac loadtest recording.har --url http://localhost:8000 --vus 50 --ramp-up 10s --duration 60s

# Authenticated test with per-VU credentials
jac loadtest recording.har --url http://localhost:8000 --vus 20 --credentials-file creds.csv

# CI-friendly with thresholds
jac loadtest recording.har --url http://localhost:8000 \
  --vus 10 --duration 30s --fail-on-p95 500 --fail-on-error-rate 1
```

## Developer Setup

```bash
# 1. Create and activate a conda env (Python 3.12 required)
conda create -n load python=3.12
conda activate load

# 2. Install the package in editable mode (runtime deps only)
pip install -e .

# 3. Also install test dependencies (when running tests)
pip install -e ".[test]"

# 4. Verify the command is registered
jac loadtest --help
```

## Project Layout

```
jac_loadtest/
├── plugin.py      — registers `jac loadtest` via jaclang entry-points
├── cli.py         — argument wiring; JacMetaImporter bootstrap
├── config.py      — LoadTestConfig dataclass (three-layer resolution)
├── core/          — HAR parser, load engine, metrics (no jac-scale knowledge)
├── bridge/        — jac-scale-aware adapters (auth, topology)
└── output/        — console, JSON, HTML reporters
```

The hard boundary between `core/` and `bridge/` is what keeps the eventual migration to `jac-scale[loadtest]` a file move rather than a rewrite.

## HAR Compatibility

Tested with HAR **1.1** and **1.2** (the format exported by Chrome DevTools, Firefox, Postman, and Insomnia). Files from other versions are parsed with a warning — open an issue if something breaks.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — module map, data flow, design decisions
- [Roadmap](docs/ROADMAP.md) — delivery phases and exit criteria
- [Verification](docs/VERIFICATION.md) — phase-by-phase manual and automated verification checklists
