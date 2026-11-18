# jac-loadtest Constraints

Current limitations of `jac-loadtest-cli` v0.10.0. Fixed items are not listed (see
[`UPGRADING.md`](UPGRADING.md)); planned work is in [`ROADMAP.md`](ROADMAP.md).

## Recording-based testing

1. **Only what was recorded is tested.** A test is a HAR file, so it covers one session's happy
   path. There is no built-in recorder, so each flow means a DevTools record and export.
   *Workaround:* record one HAR per flow you need.
2. **Every VU replays the whole recording.** No personas or traffic mix, and think time is
   deterministic (`none`, `real`, `scaled`). *Workaround:* one HAR and one run per user type.
3. **WebSocket frames are missing from Chrome HAR exports.** The connection is opened and reported
   as a `[connect]` row, but there is nothing to send, and `--ws-scenario` does not exist yet.
   *Workaround:* record with Playwright (`recordHar`, `mode: "full"`), mitmproxy or CDP.
4. **`--poll-until` only applies to adjacent repeats** of one endpoint (two or more consecutive
   recorded calls), one rule per endpoint. *Workaround:* re-record with the polling calls adjacent.

## Auth and identity

5. **Auth is jac-scale's contract.** Login is `POST --login-path` with
   `{"identity": {...}, "credential": {"type": "password", ...}}` and the token is read from
   `data.token` / `data.access_token` (or top-level); registration and `USER_EXISTS` are
   jac-scale's too. Only `Authorization: Bearer` is injected.
   `Authorization` and `Cookie` headers are always stripped from the recording, so other bearer or
   basic schemes cannot be authenticated. Other headers (for example `X-Api-Key`) replay as
   recorded, and a cookie-session login included in the HAR may work, but every VU then logs in as
   the recorded user.
6. **Accounts and tokens.**
   - VUs beyond the pool size share a token and a root graph; with `--username` every VU does.
   - One login serves every VU on an account, so one bad credential costs all of them
     (`--skip-failed-accounts` re-spreads VUs but lowers identity diversity).
   - Re-auth retries once; use-limited (not time-limited) tokens can be exhausted by other VUs.
   - Inline `--accounts` leaks passwords into shell history and `ps`; use a file.
7. **Correlation is conservative.** Only 8–512 character id-like values produced by exactly one
   response are detected; a value used once is missed, and an explicit rule threads only the first
   distinct value. The table is per VU and per iteration. *Workaround:* `--correlate` or
   `x-jac-correlate`.

## Correctness checks

8. **Checks are narrow.** `--assert-json` is flat equality or presence (`PATH=VALUE`,
   `ENDPOINT:PATH=VALUE` to scope), checked only when the status matched. The default body check is
   jac-scale-specific (`error`/`errors`, inner `status >= 400`, `reports[].success: false`, empty
   `reports`, inside `data` / `data.result`); a bare `{"ok": false}` is not flagged. *Workaround:*
   `--assert-json 'ok=true'`.
9. **Block detection needs several endpoints.** `INFRA_BLOCK_SUSPECTED` needs an identical
   non-JSON body on at least `--infra-block-threshold` (3) distinct endpoints in one 10 s window; a
   WAF hitting one or two endpoints counts as application errors. `--proxy-pool` only partly helps.
10. **Health-check samples leak into live figures.** They are excluded from final totals and the
    global gate, but not from the live `--abort-on-fail` check, multi-worker streaming percentiles,
    `total_rps` or an unscoped `--assert-json`. *Workaround:* gate with the scoped
    `--fail-on-p99 "/healthz/live:100"` and read the final report.

## Scale and gating

11. **Single machine.** About 200–500 VUs per worker, no way past `cpu_count × ~500`, one source IP
    (hence the WAF issue above). Each worker paces its own share of `--rps`, so the achieved rate
    can undershoot, and the report does not flag the drift.
12. **`--step-load` is single-process** (`--workers > 1` is rejected).
13. **No baseline comparison.** Gates are absolute (`--fail-on-error-rate`, `--fail-on-p95/p99`);
    there is no "p95 got 15% worse than last run". *Workaround:* compare stored JSON reports yourself.
14. **No metrics sink or JUnit report.** Output is console, JSON and HTML only. *Workaround:* read
    the JSON report, or `on_snapshot` when embedding.

## Scope

15. **Microservice mode needs direct access to service ports**, so it only works locally or inside
    a cluster. Use monolith mode (`--url` via the gateway) for remote or production targets.
16. **HTTP, WebSocket and GraphQL only.** No gRPC, database or MQTT, and no real-browser testing.
