"""jac-scale authentication — per-VU account pool, login, and register-on-demand.

Phase 7b. Before this, one login happened per run and the resulting token was
copied to every VU. On jac-scale every request executes against the
authenticated user's own root graph, so N VUs sharing one token all serialize on
one user's graph: that measures single-user contention under concurrency, not
the multi-user profile a real traffic mix exercises.

Now each VU gets its own identity from an account pool, logs in as that identity
on the controller before the replay loop, and replays with its own token.

Distinguishing "no such account" from "wrong password"
------------------------------------------------------
jac-scale's login returns the *same* 401 `UNAUTHORIZED / "Invalid credentials"`
in both cases -- `AuthHandler.login` calls `authenticate()` and fails identically
whether the row is missing or the hash does not match. So a 401 alone cannot tell
you whether to register.

The register endpoint can. On a 401 the pool attempts a register:

  * `201` -- the account did not exist, and now does. Log in again for the token.
  * `400 USER_EXISTS` -- the account did exist, so the original 401 really was a
    bad password. Fail with that as the reason, rather than looping.

That makes the fallback safe: it never masks a genuine credential error as a
missing account, and it never registers over an account that already exists.
"""

import csv;
import io;
import json;
import os;
import sys;
import aiohttp;
import from ..config { LoadTestConfig }

class AuthenticationError(Exception) { }

obj Credential {
    has username: str;
    has password: str;
    # Phase 7c — any columns beyond username/password from a CSV or JSON pool,
    # exposed to parameterization as {{account.<col>}}. Kept here rather than in
    # a parallel structure so a VU's identity and its data stay together: the
    # whole point is that VU 3's request body matches the account VU 3 logged in
    # as (region, plan tier, tenant id, and so on).
    has extra: dict[str, str] = {};
}

def _identity_type(username: str) -> str {
    # Preserved from the pre-7b behaviour. Note that jaclang's bundled server
    # (runtimelib/impl/server.impl.jac) rejects anything but "username" on both
    # /user/login and /user/register with a 400; deployments differ, so the
    # detected type is still sent on login rather than silently rewritten.
    return "email" if "@" in username else "username";
}

def parse_accounts(raw: object | None) -> list[Credential] {
    # Accepts, in order of how they are recognised:
    #   * an inline JSON object   '{"alice":"pw1","bob":"pw2"}'   (mirrors --services-map)
    #   * an inline JSON array    '[{"username":"alice","password":"pw1"}]'
    #   * a path to a .json file holding either of the above
    #   * a path to a .csv file with a header row including username,password
    #   * an already-parsed dict or list (the headless/web entry point)
    #
    # Order is preserved throughout, because VU-to-account assignment is
    # positional and a run that shuffled accounts between invocations would not
    # be reproducible.
    if raw is None {
        return [];
    }
    if isinstance(raw, dict) {
        return [Credential(username=str(k), password=str(v)) for (k, v) in raw.items()];
    }
    if isinstance(raw, list) {
        return _credentials_from_list(raw);
    }

    text = str(raw).strip();
    if not text {
        return [];
    }
    if text.startswith("{") or text.startswith("[") {
        try {
            parsed = json.loads(text);
        } except json.JSONDecodeError as exc {
            raise ValueError(f"--accounts is not valid JSON: {exc}") from exc;
        }
        return parse_accounts(parsed);
    }

    if not os.path.exists(text) {
        raise ValueError(
            f"--accounts: {text!r} is neither valid JSON nor an existing file. "
            'Pass an inline map like \'{"alice":"pw1","bob":"pw2"}\', or a path to '
            "a .json or .csv file."
        );
    }
    with open(text, "r", encoding="utf-8") as fh {
        content = fh.read();
    }
    if text.lower().endswith(".json") {
        try {
            return parse_accounts(json.loads(content));
        } except json.JSONDecodeError as exc {
            raise ValueError(f"--accounts file {text!r} is not valid JSON: {exc}") from exc;
        }
    }
    return _credentials_from_csv(content, text);
}

def _credentials_from_list(rows: list) -> list[Credential] {
    out: list[Credential] = [];
    for row in rows {
        if isinstance(row, dict) {
            username = row.get("username") or row.get("user") or row.get("email");
            password = row.get("password") or row.get("pass");
            if not username or not password {
                raise ValueError(
                    "--accounts entries need a username and a password; "
                    f"got {row!r}"
                );
            }
            reserved = {"username", "user", "email", "password", "pass"};
            extra = {
                str(k): str(v) for (k, v) in row.items()
                if str(k).lower() not in reserved and v is not None
            };
            out.append(Credential(
                username=str(username), password=str(password), extra=extra
            ));
        } elif isinstance(row, (list, tuple)) and len(row) >= 2 {
            out.append(Credential(username=str(row[0]), password=str(row[1])));
        } else {
            raise ValueError(f"--accounts entry is not a username/password pair: {row!r}");
        }
    }
    return out;
}

def _credentials_from_csv(content: str, source: str) -> list[Credential] {
    reader = csv.DictReader(io.StringIO(content));
    if not reader.fieldnames {
        raise ValueError(f"--accounts file {source!r} is empty");
    }
    names = [str(n).strip().lower() for n in reader.fieldnames];
    if "username" not in names or "password" not in names {
        raise ValueError(
            f"--accounts file {source!r} needs a header row with 'username' and "
            f"'password' columns; found {reader.fieldnames!r}"
        );
    }
    out: list[Credential] = [];
    for row in reader {
        normalized = {str(k).strip().lower(): v for (k, v) in row.items() if k};
        username = normalized.get("username");
        password = normalized.get("password");
        if not username or not password {
            continue;
        }
        extra = {
            k: str(v).strip() for (k, v) in normalized.items()
            if k not in ("username", "password") and v is not None
        };
        out.append(Credential(
            username=str(username).strip(), password=str(password).strip(), extra=extra
        ));
    }
    if not out {
        raise ValueError(f"--accounts file {source!r} has a header but no rows");
    }
    return out;
}

obj AuthOutcome {
    # What the pre-run authentication burst produced.
    has tokens: dict = {};
    # (username, reason) for each account that could not be authenticated.
    has failures: list = [];
    has active_accounts: int = 0;
    has total_accounts: int = 0;

    def failed_count() -> int {
        return len(self.failures);
    }
}

obj AuthProvider {
    has _accounts: list[Credential];
    has _login_path: str = "/user/login";
    has _register_path: str = "/user/register";
    has _auto_register: bool = True;
    has _warned_wrap: bool = False;
    # Phase 7b re-auth. One lock per account index, created lazily because an
    # asyncio.Lock binds to the running loop and this object is built before the
    # loop exists (and is pickled to worker processes, where the loop differs).
    has _refresh_locks: dict = {};
    # Monotonic counter per account, bumped on every successful refresh. A VU
    # that 401s records the generation it was holding; if another VU has already
    # refreshed past it, that VU just takes the new token instead of logging in
    # again. Without this, one expiry turns into one login per VU.
    has _token_generation: dict = {};
    # Indices of accounts that actually authenticated. Empty until the pre-run
    # burst has run, and every account is assumed usable until then. VU-to-account
    # assignment reads this so a dropped account stops being handed out -- both
    # for tokens and for {{account.<col>}}, which must not drift apart.
    has _active_indices: list = [];

    class def from_config(config: LoadTestConfig) -> AuthProvider | None {
        accounts = parse_accounts(config.accounts);
        if not accounts and config.username and config.password {
            accounts = [Credential(username=config.username, password=config.password)];
        }
        if not accounts {
            return None;
        }
        return AuthProvider(
            _accounts=accounts,
            _login_path=config.login_path,
            _register_path=config.register_path,
            _auto_register=config.auto_register,
        );
    }

    def account_count() -> int {
        return len(self._accounts);
    }

    def _usable_indices() -> list {
        return self._active_indices if self._active_indices else list(range(len(self._accounts)));
    }

    def credential_for(vu_id: int) -> Credential {
        # Round-robin when there are more VUs than accounts. Warned once, because
        # VUs sharing an account share a root graph and so reintroduce exactly
        # the contention the pool exists to avoid -- just at a smaller scale.
        pool = self._usable_indices();
        return self._accounts[pool[vu_id % len(pool)]];
    }

    async def authenticate(vu_id: int, session: aiohttp.ClientSession, base_url: str) -> str {
        return await self._acquire(self.credential_for(vu_id), vu_id, session, base_url);
    }

    async def authenticate_all(
        vu_ids: list[int],
        session: aiohttp.ClientSession,
        base_url: str,
        tolerate_failures: bool = False,
    ) -> AuthOutcome {
        # One login per distinct account, not per VU: with 500 VUs over 10
        # accounts this is 10 login calls, not 500, which keeps the auth endpoint
        # from being the first thing the test overloads.
        if len(vu_ids) > len(self._accounts) and not self._warned_wrap {
            print(
                f"\n\033[33mWarning: {len(vu_ids)} VUs across {len(self._accounts)} "
                "account(s) — accounts are reused round-robin, so VUs sharing one "
                "account also share a root graph.\033[0m",
                file=sys.stderr,
            );
            self._warned_wrap = True;
        }
        # Authenticate each distinct account once, then hand its token to every VU
        # assigned to it. A failure here is not one dead VU: with 10 accounts, one
        # bad row takes out a tenth of the run, which is why failures are counted
        # by account and reported that way.
        token_by_account: dict[int, str] = {};
        failures: list = [];
        for index in range(len(self._accounts)) {
            cred = self._accounts[index];
            try {
                token_by_account[index] = await self._acquire(
                    cred, index, session, base_url
                );
                # Seed the generation map so a later refresh can tell whether the
                # token a 401ing VU held is still the current one.
                self._token_generation[index] = token_by_account[index];
            } except AuthenticationError as exc {
                if not tolerate_failures {
                    raise;
                }
                failures.append((cred.username, str(exc)));
            }
        }

        if not token_by_account {
            # Nothing authenticated. Continuing would measure nothing but 401s,
            # so this aborts even in tolerant mode -- it is a misconfiguration
            # (wrong --url, wrong --login-path, server down), not a bad row.
            detail = failures[0][1] if failures else "no accounts configured";
            raise AuthenticationError(
                f"No account could be authenticated ({len(self._accounts)} tried). {detail}"
            );
        }

        # Re-spread every requested VU over the accounts that survived, rather
        # than dropping the VUs whose account failed. Concurrency is what the run
        # was asked to measure; identity diversity is what degrades, and the
        # report says so. Silently running fewer VUs than requested would leave
        # every throughput number wrong with nothing pointing at why.
        self._active_indices = sorted(token_by_account.keys());
        out: dict[int, str] = {};
        for vu_id in vu_ids {
            index = self._active_indices[vu_id % len(self._active_indices)];
            out[vu_id] = token_by_account[index];
        }
        return AuthOutcome(
            tokens=out,
            failures=failures,
            active_accounts=len(self._active_indices),
            total_accounts=len(self._accounts),
        );
    }

    async def refresh_for(
        vu_id: int, session: aiohttp.ClientSession, base_url: str, stale_token: str | None
    ) -> str {
        # Mid-run re-authentication after a 401. Called by the engine, never
        # during the pre-run burst.
        #
        # The contention this guards against is real: a JWT expires at a wall
        # time, so every VU holding it 401s within the same second or two. With
        # 500 VUs that is 500 simultaneous logins against an endpoint that is
        # already the least-provisioned part of most deployments. Per-account
        # locking collapses that to one login per account, and the generation
        # check means VUs queued behind the lock return immediately with the
        # token the first one fetched rather than re-logging in themselves.
        import asyncio;
        index = vu_id % len(self._accounts);
        if index not in self._refresh_locks {
            self._refresh_locks[index] = asyncio.Lock();
        }
        async with self._refresh_locks[index] {
            current = self._token_generation.get(index);
            if current is not None and current != stale_token {
                # Someone else already refreshed this account while we queued.
                return current;
            }
            token = await self._acquire(
                self._accounts[index], vu_id, session, base_url
            );
            self._token_generation[index] = token;
            return token;
        }
    }

    async def _acquire(
        cred: Credential, vu_id: int, session: aiohttp.ClientSession, base_url: str
    ) -> str {
        outcome = await self._login(cred, session, base_url);
        if outcome[0] is not None {
            return outcome[0];
        }
        status = outcome[1];
        detail = outcome[2];

        if status != 401 or not self._auto_register {
            raise AuthenticationError(
                f"Login failed for VU {vu_id} ({cred.username!r}): {detail}"
                + ("" if self._auto_register else " (auto-registration disabled)")
            );
        }

        # A 401 is ambiguous on jac-scale — missing account and wrong password
        # look identical. Ask the register endpoint, which can tell them apart.
        registered = await self._register(cred, session, base_url);
        if registered == "exists" {
            raise AuthenticationError(
                f"Login failed for VU {vu_id} ({cred.username!r}): {detail}. "
                "The account exists, so this is a wrong password rather than a "
                "missing account — fix the credential in --accounts."
            );
        }
        if registered != "created" {
            raise AuthenticationError(
                f"Login failed for VU {vu_id} ({cred.username!r}): {detail}. "
                f"Registering the account also failed: {registered}"
            );
        }

        retry = await self._login(cred, session, base_url);
        if retry[0] is not None {
            return retry[0];
        }
        raise AuthenticationError(
            f"Registered {cred.username!r} for VU {vu_id}, but logging in "
            f"immediately afterwards failed: {retry[2]}"
        );
    }

    async def _login(
        cred: Credential, session: aiohttp.ClientSession, base_url: str
    ) -> tuple {
        # Returns (token, status, detail): token is None when the login did not
        # produce one, and detail is a human-readable reason for the message.
        payload = {
            "identity": {"type": _identity_type(cred.username), "value": cred.username},
            "credential": {"type": "password", "password": cred.password},
        };
        url = base_url.rstrip("/") + self._login_path;
        try {
            async with session.post(url, json=payload) as resp {
                status = resp.status;
                body = await self._read_json(resp);
                if status == 200 or status == 201 {
                    token = self._token_from(body);
                    if token {
                        return (token, status, "");
                    }
                    return (None, status, f"unexpected login response shape: {body!r}");
                }
                return (None, status, self._message_from(body, status));
            }
        } except aiohttp.ClientConnectorError as exc {
            raise AuthenticationError(f"Cannot reach login endpoint {url!r}: {exc}") from exc;
        }
    }

    async def _register(
        cred: Credential, session: aiohttp.ClientSession, base_url: str
    ) -> str {
        # Returns "created", "exists", or a failure description.
        #
        # `identities` is a list here, unlike login's singular `identity`, and the
        # server requires an entry of type "username" — see jaclang
        # runtimelib/auth_models.jac (RegisterRequest) and server.impl.jac.
        payload = {
            "identities": [{"type": "username", "value": cred.username}],
            "credential": {"type": "password", "password": cred.password},
        };
        url = base_url.rstrip("/") + self._register_path;
        try {
            async with session.post(url, json=payload) as resp {
                status = resp.status;
                body = await self._read_json(resp);
                if status in (200, 201) {
                    return "created";
                }
                message = self._message_from(body, status);
                code = "";
                if isinstance(body, dict) {
                    code = str(body.get("code") or "");
                }
                if code == "USER_EXISTS" or "already exists" in message.lower() {
                    return "exists";
                }
                return f"{status} {message}";
            }
        } except aiohttp.ClientConnectorError as exc {
            raise AuthenticationError(
                f"Cannot reach register endpoint {url!r}: {exc}"
            ) from exc;
        }
    }

    async def _read_json(resp: object) -> object {
        try {
            return await resp.json(content_type=None);
        } except Exception {
            try {
                return (await resp.text())[:300];
            } except Exception {
                return None;
            }
        }
    }

    def _token_from(body: object) -> str | None {
        # jac-scale wraps success as {"success": true, "data": {...}}; the token
        # lives in data. A few deployments return it at the top level, so both are
        # accepted rather than failing on a shape difference.
        if not isinstance(body, dict) {
            return None;
        }
        data = body.get("data");
        if isinstance(data, dict) {
            for key in ("token", "access_token") {
                if data.get(key) {
                    return str(data[key]);
                }
            }
        }
        for key in ("token", "access_token") {
            if body.get(key) {
                return str(body[key]);
            }
        }
        return None;
    }

    def _message_from(body: object, status: int) -> str {
        if isinstance(body, dict) {
            for key in ("message", "error", "detail") {
                value = body.get(key);
                if value {
                    return str(value);
                }
            }
        }
        if isinstance(body, str) and body.strip() {
            return body.strip();
        }
        return f"server returned {status}";
    }
}
