"""The Locust user that replays a recorded HAR session.

One HarUser = one virtual user = one HTTP client (Locust gives every user its
own, which is why the old --proxy-pool / per-VU connector machinery is gone).

Per iteration the user walks the HAR entries in order, applying, per request:
  token -> topology routing -> correlation -> parameterization -> send ->
  status check -> assertions -> jac-scale body check -> correlation capture.

Failures are reported to Locust through catch_response, so Locust's own stats,
console table, HTML and CSV reports see exactly what we decided.

Patterns proven on jac 0.39.2 during stage 0: a direct FastHttpUser subclass,
`_any()` around catch_response context managers, and per-environment events.
"""

import time;
import from urllib.parse { urlparse }
import gevent;
import from locust { FastHttpUser, task, constant }
import from ..config { parse_duration }
import from ..core.har_parser { HarEntry }
import from ..core.correlation { CorrelationTable, apply_correlations }
import from ..core.parameterize { ParamContext, apply_params, has_tokens }
import from ..core.metrics { normalize_path, extract_trace_id }
import from ..bridge.auth { AuthenticationError }
import from ..bridge.body_check { check_body, check_shape }
import from .checks { assertions_for, parse_assert_json, check_json_assertions, poll_rule_for, poll_body_match, PollRule }
import from .context { get_context, next_vu_id, RunContext }
import from .auth_flow { acquire_token }
import from .live { POLL_PREFIX, HEALTH_PREFIX }
import from .infra { body_fingerprint, Suspect }
import from .ws_client { run_ws, run_graphql_ws, handshake_headers }

def _any(x: any) -> any {
    return x;
}

def _path_of(url: str) -> str {
    return urlparse(url).path;
}

def _entries_have_tokens(entries: list[HarEntry]) -> bool {
    for e in entries {
        if has_tokens(e.url) or has_tokens(e.body) {
            return True;
        }
        for v in e.headers.values() {
            if has_tokens(v) {
                return True;
            }
        }
    }
    return False;
}

obj Attempt {
    has error: str | None = None;
    has status: int = 0;
    has length: int = 0;
    # "success" / "error" when a --poll-until rule matched, else "".
    has poll: str = "";
    # True when the request was never made (no route), so nothing was recorded.
    has rejected: bool = False;
}

class HarUser(FastHttpUser) {
    wait_time = constant(0);

    def on_start(self: HarUser) -> None {
        self.ctx = get_context();
        local = next_vu_id(self.ctx);
        # Unique across workers: worker k of N owns ids k, k+N, k+2N, ... so two
        # workers never log in the same account.
        if self.ctx.worker_count > 1 {
            self.vu_id = local * self.ctx.worker_count + int(self.environment.runner.worker_index);
        } else {
            self.vu_id = local;
        }
        self.iteration = 0;
        self.token = "";
        self.account_extra = {};
        cfg = self.ctx.config;
        if self.ctx.accounts {
            cred = self.ctx.accounts[self.vu_id % len(self.ctx.accounts)];
            self.account_extra = dict(cred.extra);
            try {
                self.token = acquire_token(
                    self.client, cred, self.vu_id,
                    cfg.login_path, cfg.register_path, cfg.auto_register,
                );
            } except AuthenticationError as exc {
                self.ctx.auth_failures.append((cred.username, str(exc)));
                if not cfg.skip_failed_accounts {
                    self.environment.runner.quit();
                }
                self.stop();
            }
        }
    }

    @task
    def replay(self: HarUser) -> None {
        cfg = self.ctx.config;
        table = CorrelationTable(values={});
        pctx = None;
        if self.ctx.param_rules or _entries_have_tokens(self.ctx.entries) {
            pctx = ParamContext(
                vu_id=self.vu_id, iteration=self.iteration, account=self.account_extra
            );
        }
        entries = self.ctx.entries;
        i = 0;
        while i < len(entries) {
            e = entries[i];
            i += 1;
            if e.is_login and self.token {
                # Already authenticated up front; replaying the recorded login
                # would add auth traffic the run is not trying to measure.
                continue;
            }
            if e.protocol == "ws" {
                self._ws(e);
            } elif e.protocol == "graphql_ws" {
                self._graphql_ws(e);
            } else {
                rule = poll_rule_for(self.ctx.poll_rules, _path_of(e.url));
                if rule is not None and e.consecutive_run_size > 1 and e.consecutive_run_index == 1 {
                    # One wait-until loop replaces the whole recorded run of polls.
                    self._poll_block(e, rule, table, pctx);
                    i += e.consecutive_run_size - 1;
                } else {
                    self._attempt(e, table, pctx, False, self._name(e), None);
                }
            }
            if cfg.think_time == "real" and e.think_time_ms > 0 {
                gevent.sleep(e.think_time_ms / 1000.0);
            }
        }
        if cfg.health_check {
            self._health_check();
        }
        self.iteration += 1;
        if cfg.iterations is not None and self.iteration >= cfg.iterations {
            self.stop();
        }
    }

    def _fire_proto(
        self: HarUser, request_type: str, name: str, ms: float, length: int, err: str | None
    ) -> None {
        self.environment.events.request.fire(
            request_type=request_type, name=name, response_time=ms,
            response_length=length, exception=Exception(err) if err else None, context={},
        );
    }

    def _ws(self: HarUser, e: HarEntry) -> None {
        cfg = self.ctx.config;
        run_ws(
            self._fire_proto, e.url, handshake_headers(e.headers, self.token),
            list(e.ws_messages), parse_duration(cfg.timeout), e.think_time_ms,
        );
    }

    def _graphql_ws(self: HarUser, e: HarEntry) -> None {
        cfg = self.ctx.config;
        run_graphql_ws(
            self._fire_proto, e.url, handshake_headers(e.headers, self.token),
            e.graphql_query or "", e.graphql_variables, e.graphql_operation_name,
            parse_duration(cfg.timeout), 0,
        );
    }

    def _name(self: HarUser, e: HarEntry) -> str {
        name = normalize_path(e.url);
        if e.total_occurrences > 1 {
            name = f"{name} (call #{e.occurrence} of {e.total_occurrences})";
        }
        return name;
    }

    def _fail_fast(self: HarUser, e: HarEntry, label: str, reason: str) -> None {
        # A request that was never sent (unroutable, correlation miss) is still
        # a data point: report it as a zero-latency failure.
        self.environment.events.request.fire(
            request_type=e.method, name=label, response_time=0.0,
            response_length=0, exception=Exception(reason), context={},
        );
    }

    def _health_check(self: HarUser) -> None {
        cfg = self.ctx.config;
        url = (cfg.url or "").rstrip("/") + (cfg.health_check or "");
        probe = HarEntry(
            method="GET", url=url, headers={}, body=None, body_mime=None,
            think_time_ms=0.0, is_login=False, original_url=url, expected_status=200,
        );
        # Unauthenticated, no correlation or params, and named so reports can keep
        # it out of the totals: it is a side-channel probe, not recorded traffic.
        saved = self.token;
        self.token = "";
        self._attempt(probe, CorrelationTable(values={}), None, True, HEALTH_PREFIX + (cfg.health_check or ""), None);
        self.token = saved;
    }

    def _poll_block(
        self: HarUser, e: HarEntry, rule: PollRule, table: CorrelationTable,
        pctx: ParamContext | None
    ) -> None {
        cfg = self.ctx.config;
        timeout_s = parse_duration(cfg.poll_timeout);
        interval_s = (
            parse_duration(cfg.poll_interval) if cfg.poll_interval
            else (e.think_time_ms / 1000.0 if e.think_time_ms > 0 else 1.0)
        );
        label = POLL_PREFIX + normalize_path(e.url);
        t0 = time.perf_counter();
        deadline = t0 + timeout_s;
        attempts = 0;
        last = Attempt();
        while True {
            attempts += 1;
            last = self._attempt(e, table, pctx, False, label, rule);
            if last.rejected or last.poll in ("success", "error") {
                break;
            }
            # A transport/status failure mid-poll is a real failure, not "still
            # launching": stop instead of burning the rest of the timeout.
            if last.error is not None or time.perf_counter() >= deadline {
                break;
            }
            gevent.sleep(min(interval_s, max(0.0, deadline - time.perf_counter())));
        }
        if last.rejected {
            return;
        }
        error: str | None = None;
        if last.poll == "success" {
            error = None;
        } elif last.poll == "error" {
            error = (
                f"POLL_TERMINAL_ERROR: '{rule.path}' reached a configured "
                f"error state after {attempts} poll(s)"
            );
        } elif last.error is not None {
            error = last.error;
        } else {
            error = f"POLL_TIMEOUT: no terminal state after {attempts} poll(s) / {timeout_s:.0f}s";
        }
        # The block is scored once, under the endpoint's own name, with the whole
        # wait as its latency; the individual polls live under the poll prefix.
        self.environment.events.request.fire(
            request_type=e.method, name=normalize_path(e.url),
            response_time=(time.perf_counter() - t0) * 1000.0, response_length=last.length,
            exception=Exception(error) if error else None, context={},
        );
    }

    def _attempt(
        self: HarUser, e: HarEntry, table: CorrelationTable,
        pctx: ParamContext | None, retried: bool, label: str, rule: PollRule | None
    ) -> Attempt {
        ctx = self.ctx;
        cfg = ctx.config;
        headers = {k: v for (k, v) in e.headers.items() if k.lower() != "authorization"};
        if self.token {
            headers["Authorization"] = f"Bearer {self.token}";
        }

        request_url = e.url;
        if ctx.topology is not None {
            try {
                request_url = ctx.topology.resolve(e.url)[0];
            } except ValueError {
                path = _path_of(e.url);
                if path not in ctx.warned_unrouted {
                    ctx.warned_unrouted.append(path);
                    print(
                        f"Warning: no route for '{path}' -- skipping. Add a matching "
                        "prefix to --services-map or set --url as fallback."
                    );
                }
                return Attempt(rejected=True);
            }
        }

        body = e.body;
        if ctx.rules {
            out = apply_correlations(ctx.rules, table, _path_of(e.url), request_url, body);
            if out.missing {
                reason = "CORRELATION_MISS: " + ", ".join(out.missing);
                self._fail_fast(e, label, reason);
                return Attempt(error=reason);
            }
            request_url = out.url;
            body = out.body;
        }
        if pctx is not None {
            po = apply_params(ctx.param_rules, pctx, _path_of(e.url), request_url, body, headers);
            request_url = po.url;
            body = po.body;
            headers = po.headers;
        }

        with _any(self.client.request(
            e.method, request_url, data=body, headers=headers,
            name=label, catch_response=True, allow_redirects=False,
        )) as r {
            status = r.status_code;
            if (
                status == 401 and e.expected_status != 401 and self.token
                and ctx.accounts and not retried
            ) {
                # Token likely expired mid-run: re-authenticate once and replay.
                r.success();
                cred = ctx.accounts[self.vu_id % len(ctx.accounts)];
                try {
                    self.token = acquire_token(
                        self.client, cred, self.vu_id,
                        cfg.login_path, cfg.register_path, cfg.auto_register,
                    );
                } except AuthenticationError as exc {
                    reason = f"AUTH_EXPIRED: re-authentication failed ({exc})";
                    self._fail_fast(e, label, reason);
                    return Attempt(error=reason);
                }
                return self._attempt(e, table, pctx, True, label, rule);
            }
            # Capture before judging the response, as the old engine did: a body
            # check failure must not starve later requests of the ids it carried.
            content = r.content or b"";
            if ctx.rules and status != 0 {
                table.capture(ctx.rules, _path_of(e.url), content, r.headers);
            }
            res = Attempt(status=status, length=len(content));
            if rule is not None {
                res.poll = poll_body_match(content, rule) or "";
            }
            if status == 0 {
                res.error = str(r.error) if r.error else "CONNECTION_ERROR";
            } elif status != e.expected_status {
                text = r.text[:200] if r.text else "";
                res.error = f"HTTP {status} (expected {e.expected_status}): {text}";
            } else {
                if cfg.assert_json {
                    scoped = assertions_for(
                        parse_assert_json(cfg.assert_json), _path_of(e.url)
                    );
                    if scoped {
                        res.error = check_json_assertions(content, scoped);
                    }
                }
                if res.error is None and cfg.body_check {
                    shape = ctx.baseline.get(_path_of(e.url));
                    res.error = check_body(content, shape);
                    if res.error is None and cfg.check_shape {
                        res.error = check_shape(content, shape);
                    }
                }
            }
            if res.error {
                fp = body_fingerprint(content);
                if fp is not None {
                    ctx.suspects.append(Suspect(timestamp=time.time(), endpoint=label, fingerprint=fp));
                }
                r.failure(res.error);
            }
            return res;
        }
    }
}
