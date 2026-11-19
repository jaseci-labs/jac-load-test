# jac-loadtest — Introduction

## The problem

Load testing a jac-scale app with JMeter, k6 or Locust means writing a test script that describes
behaviour you already recorded in your browser, and none of them understand jac-scale's auth
(`/user/login` + JWT) or its microservice topology.

## The approach

Use the HAR file as the test script. Chrome DevTools already records every request your app made;
`jac-loadtest` replays it under load. **Zero scripting.**

It is a **standalone Jac package** (`jac install jac-loadtest-cli`, then `jac x loadtest`), not part
of jac-scale. It reaches jac-scale only over HTTP and through `jac.toml`.

- **Generic core.** The parsers, metrics, correlation, parameterization and protocol adapters work
  against any HTTP server.
- **jac-scale awareness in `bridge/`.** The login/register shapes, `jac.toml` microservice
  routing and the `data.result.reports[]` envelope (a walker can fail while answering HTTP 200).

Other options were rejected: a native jac-scale plugin (slows iteration), an admin-portal feature
(the tool under test would generate the load), a separate microservice (overkill), and a tool with
no jac-scale knowledge (loses auth and topology).

## Where to read next

- [`MARKET_COMPARISON.md`](MARKET_COMPARISON.md) — where the tool stands against k6, JMeter, Gatling, Locust
- [`CONSTRAINTS.md`](CONSTRAINTS.md) — current limitations
- [`ROADMAP.md`](ROADMAP.md) — what is built and what is planned
- [`COMMANDS.md`](COMMANDS.md) — flag reference
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how it works
- [`TESTING.md`](TESTING.md) and [`UPGRADING.md`](UPGRADING.md)
