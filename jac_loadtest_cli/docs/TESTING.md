# jac-loadtest Testing

269 tests, written in Jac `test "name" { }` blocks.

**Rules.** Unit tests never touch the network. Component tests run a real Locust run, in a child
process, against a mock jac-scale server that counts every request it receives, and check what the
tool *reports* against what the server *saw*. The test process never imports Locust: importing it
patches the standard library with gevent, so runs go through `runner/subproc.jac`.

## Running

```bash
PYTEST_XDIST_AUTO_NUM_WORKERS=1 jac test tests/   # all tests, single worker
jac test tests/unit/                              # no network, run first
jac test tests/component/                         # real Locust runs against the mock (~25 s)
jac test tests/unit/test_thresholds.jac -t "error rate over the limit breaches"
```

## Layout

```
tests/
  fixtures/        minimal.har, mixed_static.har, microservice.toml
  support/
    mock_server    jac-scale mock: login/register contract, walkers, GraphQL, WebSocket, fault switches
  unit/            261 tests
    test_har_parser     68  filtering, URL rewrite, ws/graphql tagging, adjacent-run tags
    test_config         45  layered resolution, from_dict, scoped thresholds
    test_correlation    37  detection, explicit rules, hydration, per-VU tables
    test_parameterize   26  tokens, --param files, row advance
    test_poll_until     22  rule parsing, terminal-state matching
    test_topology       21  routing, longest prefix
    test_body_check     20  failure-inside-200, envelope unwrap, shape drift
    test_accounts       11  --accounts parsing
    test_thresholds      6  pass/fail over a finished report
    test_json_report     5  report built from Locust stats: totals, auth split, error types, web keys
  component/       8 tests
    test_runner          8  counts match the server, correlation, register on 401, failure inside 200,
                            infra blocks, WebSocket frames, threshold breach, two workers
```

## What the component tests prove

Each one injects something known and checks the report names it: a failure inside an HTTP 200
shows up as `APP_ERROR_IN_200` on that endpoint; identical deny pages across endpoints become infra
blocks outside the error rate; two worker processes produce the same totals the server counted and
never log in the same account twice.

## Not tested

Locust itself, jac-scale server behaviour, the HTML report's appearance (it is Locust's), and
more than a handful of VUs in CI. Step-load and `--abort-on-fail` are exercised by hand against the
mock and a real dev target; automated shape tests are still to do.
