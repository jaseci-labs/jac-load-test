# jac-loadtest-cli

HAR-based load testing CLI built on [Jac](https://github.com/jaseci-labs/jaseci). Record real
browser traffic in Chrome DevTools, export it as a `.har` file, and replay it under load. No
scripting. Run it with `jac x loadtest` after installing the package.

## What it does

- **Replays a recorded session** with N virtual users, each with its own account and token
  (`--accounts`; missing accounts are registered automatically).
- **Threads each VU's own server-generated IDs** through the workflow (auto-detected correlation),
  and varies data with `{{tokens}}` and `--param` files.
- **Counts failures correctly:** a jac-scale walker that answers HTTP 200 with the failure in the
  body is a failure; WAF / rate-limit pages are separated from application errors; polling loops
  can be scored on the job's real outcome (`--poll-until`).
- **Load shapes:** closed loop, `--open-loop`, `--step-load` (capacity knee), `--duration`,
  ramp-up, think time, multi-process workers.
- **CI gating:** `--fail-on-error-rate`, `--fail-on-p95/p99`, `--abort-on-fail`, exit codes.
- **Protocols:** HTTP, WebSocket and GraphQL, auto-detected from the HAR.
- **Reports:** console, JSON and a self-contained HTML file.

It works against any HTTP server. Login, microservice routing and the default body check are
jac-scale-specific; see [docs/CONSTRAINTS.md](docs/CONSTRAINTS.md) for what that means for other
targets, and [docs/MARKET_COMPARISON.md](docs/MARKET_COMPARISON.md) for where the tool stands.

## Quick start

```bash
# 1 VU, 1 replay
jac x loadtest recording.har --url http://localhost:8000

# 50 VUs, 100 iterations each, 10 s ramp-up
jac x loadtest recording.har --url http://localhost:8000 --vus 50 --iterations 100 --ramp-up 10s

# 20 distinct accounts
jac x loadtest recording.har --url http://localhost:8000 --vus 20 --accounts accounts.csv

# CI gate: fail on p95 > 500 ms or errors > 1%, stop early
jac x loadtest recording.har --url http://staging:8000 --vus 20 --iterations 100 \
  --fail-on-p95 500 --fail-on-error-rate 1 --threshold-start-delay 10s --abort-on-fail

# HTML report
jac x loadtest recording.har --url http://localhost:8000 --report-format html --report-out results.html
```

**Modes.** Monolith (default) sends everything through `--url`. Microservice
(`--mode microservice`, with service apps declared in `jac.toml` or `--services-map`) sends each request straight to
its service by path prefix; it needs direct access to service ports, so it works locally or inside
a cluster only.

**Exit codes.** `0` passed · `1` a threshold failed · `2` config or tool error.

The full flag reference is in [docs/COMMANDS.md](docs/COMMANDS.md).

## Developer setup

```bash
cd jac_loadtest_cli
jac install -e .                                  # install in editable mode
jac x loadtest --help                             # verify the command is registered
PYTEST_XDIST_AUTO_NUM_WORKERS=1 jac test tests/   # all tests (~630), single worker
jac run scripts/mock_service.jac -- order_service:8001 inventory_service:8002   # fake services
```

The package layout is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). HAR 1.1 and 1.2 are
supported (Chrome, Firefox, Postman, Insomnia); other versions parse with a warning.

## Documentation

- [Introduction](docs/INTRO.md) · [Architecture](docs/ARCHITECTURE.md) · [Commands](docs/COMMANDS.md)
- [Market comparison](docs/MARKET_COMPARISON.md) · [Constraints](docs/CONSTRAINTS.md) · [Roadmap](docs/ROADMAP.md)
- [Testing](docs/TESTING.md) · [Upgrading](docs/UPGRADING.md)
