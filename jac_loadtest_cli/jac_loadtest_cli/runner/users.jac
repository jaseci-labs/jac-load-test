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
import from ..core.engine { assertions_for, parse_assert_json, _check_json_assertions }
import from .context { get_context, next_vu_id, RunContext }
import from .auth_flow { acquire_token }
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

class HarUser(FastHttpUser) {
    wait_time = constant(0);

    def on_start(self: HarUser) -> None {
        self.ctx = get_context();
        self.vu_id = next_vu_id(self.ctx);
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
        for e in self.ctx.entries {
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
                self._send(e, table, pctx, False);
            }
            if cfg.think_time in ("real", "scaled") and e.think_time_ms > 0 {
                gevent.sleep(e.think_time_ms / 1000.0 * cfg.think_time_scale);
            }
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

    def _fail_fast(self: HarUser, e: HarEntry, reason: str) -> None {
        # A request that was never sent (unroutable, correlation miss) is still
        # a data point: report it as a zero-latency failure.
        self.environment.events.request.fire(
            request_type=e.method, name=self._name(e), response_time=0.0,
            response_length=0, exception=Exception(reason), context={},
        );
    }

    def _send(
        self: HarUser, e: HarEntry, table: CorrelationTable,
        pctx: ParamContext | None, retried: bool
    ) -> None {
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
                return;
            }
        }

        body = e.body;
        if ctx.rules {
            out = apply_correlations(ctx.rules, table, _path_of(e.url), request_url, body);
            if out.missing {
                self._fail_fast(e, "CORRELATION_MISS: " + ", ".join(out.missing));
                return;
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
            name=self._name(e), catch_response=True, allow_redirects=False,
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
                    self._fail_fast(e, f"AUTH_EXPIRED: re-authentication failed ({exc})");
                    return;
                }
                self._send(e, table, pctx, True);
                return;
            }
            # Capture before judging the response, as the old engine did: a body
            # check failure must not starve later requests of the ids it carried.
            content = r.content or b"";
            if ctx.rules and status != 0 {
                table.capture(ctx.rules, _path_of(e.url), content, r.headers);
            }
            if status == 0 {
                r.failure(str(r.error) if r.error else "CONNECTION_ERROR");
                return;
            }
            if status != e.expected_status {
                text = r.text[:200] if r.text else "";
                r.failure(f"HTTP {status} (expected {e.expected_status}): {text}");
                return;
            }
            if cfg.assert_json {
                scoped = assertions_for(
                    parse_assert_json(cfg.assert_json), _path_of(e.url)
                );
                if scoped {
                    why = _check_json_assertions(content, scoped);
                    if why {
                        r.failure(why);
                        return;
                    }
                }
            }
            if cfg.body_check {
                shape = ctx.baseline.get(_path_of(e.url));
                why = check_body(content, shape);
                if why is None and cfg.check_shape {
                    why = check_shape(content, shape);
                }
                if why {
                    r.failure(why);
                    return;
                }
            }
        }
    }
}
