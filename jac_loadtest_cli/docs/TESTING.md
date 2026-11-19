# jac-loadtest Testing

628 tests, written in Jac `test "name" { }` blocks.

**Rules.** Unit tests never touch the network. Integration and e2e tests use a real in-process
`aiohttp` test server, never a live jac-scale app or a subprocess. Async bodies run via
`asyncio.run()`. Patching uses `mock.patch.object` on the live module.

## Running

```bash
PYTEST_XDIST_AUTO_NUM_WORKERS=1 jac test tests/   # all tests, single worker
jac test tests/unit/                              # no network, run first
jac test tests/integration/                       # in-process servers
jac test tests/e2e/                               # full pipeline + headless
jac test tests/unit/test_metrics.jac --test_name "percentile p50"
```

`jac test` parallelises across CPU cores by default; the single-worker variable above is what the
maintainers use. CI runs the three directories in order.

## Layout

```
tests/
  fixtures/        minimal.har, mixed_static.har, microservice.toml
  unit/            404 tests
    test_har_parser     68  filtering, URL rewrite, ws/graphql tagging, adjacent-run tags
    test_metrics        57  percentiles, normalization, eviction, timeseries, TTFB, grouping
    test_config         56  layered resolution, from_dict, scoped thresholds
    test_process_runner 40  VU slicing, snapshot merge, fleet abort, sample split
    test_correlation    37  detection, explicit rules, hydration, per-VU tables
    test_parameterize   26  tokens, --param files, row advance
    test_poll_until     22  rule parsing, terminal-state matching
    test_body_check     20  failure-inside-200, envelope unwrap, shape drift
    test_accounts       18  --accounts parsing, VU assignment
    test_topology       18  routing, longest prefix
    test_ws_engine      16  scenario parsing, HAR bridging
    test_infra_block    14  deny-page fingerprinting, classification, proxy pool
    test_graphql_engine 12  scenario parsing, HAR bridging
  integration/     198 tests
    test_reporter       77  JSON / HTML / console output
    test_engine         65  VU lifecycle, open loop, step load, assertions, poll-until
    test_auth           21  login, account pool, register on demand, pacing
    test_ws_engine      10  WebSocket echo server, connect rows
    test_graphql_engine  7  graphql-ws subscription server
    test_parameterize    7  tokens and --param against a live server
    test_correlation     6  stateful server: recorded-id workflow breaks, correlation fixes it
    test_reauth          5  mid-run 401 refresh, per-account dedup, AUTH_EXPIRED
  e2e/             26 tests
    test_headless       14  run_test_headless() driven as an embedder would
    test_headless_protocols 7  ws/graphql blocks, mixed HTTP+WS report
    test_smoke           5  parse → run → stats → report
```

## Not tested

Rich pixel layout, `aiohttp` internals, jac-scale server behaviour, HTML visual appearance, HAR
files over 1 MB, and more than 50 VUs in CI (5 VUs cover correctness). Real `multiprocessing`
spawning is verified manually, because the spawn context's pickling is fragile under the full
test tree; `_worker_fn` and `_merge_snapshots` are tested in-process with a fake queue.
