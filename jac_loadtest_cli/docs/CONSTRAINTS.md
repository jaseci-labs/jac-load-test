# jac-loadtest Constraints

Current limitations of `jac-loadtest-cli` (Locust engine, v0.11.1). Fixed items are not listed (see
[`UPGRADING.md`](UPGRADING.md)); planned work is in [`ROADMAP.md`](ROADMAP.md).

## Recording-based testing

1. **Only what was recorded is tested.** A test is a HAR file, so it covers one session's happy
   path. There is no built-in recorder, so each flow means a DevTools record and export.
   *Workaround:* record one HAR per flow you need.
2. **Every VU replays the whole recording.** No personas or traffic mix, and think time is
   deterministic (`none` or `real`). *Workaround:* one HAR and one run per user type.
3. **WebSocket frames are missing from Chrome HAR exports.** The connection is opened and reported
   as a `[connect]` row, but there is nothing to send, and `--ws-scenario` does not exist yet.
   *Workaround:* record with Playwright (`recordHar`, `mode: "full"`), mitmproxy or CDP.
4. **`--poll-until` only applies to adjacent repeats** of one endpoint (two or more consecutive
   recorded calls), one rule per endpoint. *Workaround:* re-record with the polling calls adjacent.

## Auth and identity

5. **Auth is jac-scale's contract.** Login is `POST --login-path` with
   `{"identity": {...}, "credential": {"type": "password", ...}}` and the token is read from
   `data.token` / `data.access_token` (or top-level); registration and the duplicate-account codes (`IDENTITY_TAKEN`, `USER_EXISTS`) are
   jac-scale's too. Only `Authorization: Bearer` is injected.
   `Authorization` and `Cookie` headers are always stripped from the recording, so other bearer or
   basic schemes cannot be authenticated. Other headers (for example `X-Api-Key`) replay as
   recorded, and a cookie-session login included in the HAR may work, but every VU then logs in as
   the recorded user.
6. **Accounts and tokens.**
   - VUs beyond the pool size share an account and so a root graph (each still logs in on its own);
     with `--username` every VU does.
   - A bad credential stops that user. Without `--skip-failed-accounts` the run aborts (exit 2); with
     it the remaining users run, so concurrency drops by the number of failed accounts.
   - Re-auth retries once; use-limited (not time-limited) tokens can be exhausted by other users.
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
   WAF hitting one or two endpoints counts as application errors.
10. **Health-check requests are outside the totals, the report's error rate and every global gate**,
    live or final. They appear as their own `health: <path>` row. An unscoped `--assert-json` still
    applies to them. *Workaround:* gate the probe with a scoped threshold on its row.
11. **Infra blocks are only known at the end.** The WAF/deny-page pass runs after the run, so the
    final report and `--fail-on-*` exit code exclude blocked responses, but the live
    `--abort-on-fail` check still counts them as errors.

## Scale and gating

12. **One machine's source IP.** `--workers` splits the load over processes on this machine; all
    of them egress from one IP (hence the WAF issue above). There is no proxy pool: a separate HTTP
    client per user is not a separate source address. For several IPs, run Locust workers on several
    hosts.
13. **Percentiles are approximate.** Locust keeps bucketed response times, so percentiles are
    close, not exact, and reported in whole milliseconds. There is no TTFB column.
14. **No baseline comparison.** Gates are absolute (`--fail-on-error-rate`, `--fail-on-p95/p99`);
    there is no "p95 got 15% worse than last run". *Workaround:* compare stored JSON reports yourself.
15. **No metrics sink or JUnit report.** Output is console, JSON and HTML only. *Workaround:* read
    the JSON report, or `on_snapshot` when embedding.

## Scope

16. **Microservice mode needs direct access to service ports**, so it only works locally or inside
    a cluster. Use monolith mode (`--url` via the gateway) for remote or production targets.
16. **HTTP, WebSocket and GraphQL only.** No gRPC, database or MQTT, and no real-browser testing.
