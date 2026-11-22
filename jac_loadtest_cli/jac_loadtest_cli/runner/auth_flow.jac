"""Per-user login with register-on-401, over a Locust HTTP client.

Same policy as the old bridge/auth.jac (log in; on 401 try register; log in
again), re-expressed synchronously for gevent. Differences learned from the real
jac-scale 0.39.2 contract:

  * errors come back as {"ok": false, "error": {"code": ...}}, so the code is
    read from `error.code` as well as a top-level `code`;
  * a duplicate register is 400 `IDENTITY_TAKEN` (older servers: `USER_EXISTS`);
  * register itself returns a token on 201, which saves a second login.

Auth requests show up in Locust's stats under "auth: login" / "auth: register".
The expected 401 that triggers registration is marked success so it does not
count as an error.
"""

import json;
import from ..bridge.auth { Credential, AuthenticationError }

def _any(x: any) -> any {
    return x;
}

def _identity_type(username: str) -> str {
    return "email" if "@" in username else "username";
}

def token_from(body: any) -> str | None {
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

def error_code(body: any) -> str {
    if not isinstance(body, dict) {
        return "";
    }
    err = body.get("error");
    if isinstance(err, dict) and err.get("code") {
        return str(err["code"]);
    }
    return str(body.get("code") or "");
}

def message_from(body: any, status: int) -> str {
    if isinstance(body, dict) {
        err = body.get("error");
        if isinstance(err, dict) and err.get("message") {
            return str(err["message"]);
        }
        for key in ("message", "error", "detail") {
            value = body.get(key);
            if value and not isinstance(value, dict) {
                return str(value);
            }
        }
    }
    return f"server returned {status}";
}

def _json(text: str) -> any {
    try {
        return json.loads(text);
    } except Exception {
        return None;
    }
}

def _login(client: any, cred: Credential, path: str) -> tuple[str | None, int, str] {
    payload = {
        "identity": {"type": _identity_type(cred.username), "value": cred.username},
        "credential": {"type": "password", "password": cred.password},
    };
    with _any(client.post(path, json=payload, name="auth: login", catch_response=True)) as r {
        body = _json(r.text);
        if r.status_code in (200, 201) {
            token = token_from(body);
            if token {
                return (token, r.status_code, "");
            }
            r.failure("login response had no token");
            return (None, r.status_code, "unexpected login response shape");
        }
        detail = message_from(body, r.status_code);
        if r.status_code == 401 {
            # Expected when the account does not exist yet; the caller decides.
            r.success();
        } else {
            r.failure(detail);
        }
        return (None, r.status_code, detail);
    }
}

def _register(client: any, cred: Credential, path: str) -> tuple[str, str | None] {
    # Returns ("created", token|None) | ("exists", None) | (failure text, None).
    payload = {
        "identities": [{"type": "username", "value": cred.username}],
        "credential": {"type": "password", "password": cred.password},
    };
    with _any(client.post(path, json=payload, name="auth: register", catch_response=True)) as r {
        body = _json(r.text);
        if r.status_code in (200, 201) {
            return ("created", token_from(body));
        }
        code = error_code(body);
        message = message_from(body, r.status_code);
        if code in ("IDENTITY_TAKEN", "USER_EXISTS") or "already exists" in message.lower() {
            # Not a load-test error: it tells us the 401 was a bad password.
            r.success();
            return ("exists", None);
        }
        r.failure(message);
        return (f"{r.status_code} {message}", None);
    }
}

def acquire_token(
    client: any,
    cred: Credential,
    vu_id: int,
    login_path: str,
    register_path: str,
    auto_register: bool,
) -> str {
    first = _login(client, cred, login_path);
    if first[0] is not None {
        return str(first[0]);
    }
    if first[1] != 401 or not auto_register {
        raise AuthenticationError(
            f"Login failed for VU {vu_id} ({cred.username!r}): {first[2]}"
            + ("" if auto_register else " (auto-registration disabled)")
        );
    }
    reg = _register(client, cred, register_path);
    if reg[0] == "exists" {
        raise AuthenticationError(
            f"Login failed for VU {vu_id} ({cred.username!r}): {first[2]}. "
            "The account exists, so this is a wrong password rather than a "
            "missing account -- fix the credential in --accounts."
        );
    }
    if reg[0] != "created" {
        raise AuthenticationError(
            f"Login failed for VU {vu_id} ({cred.username!r}): {first[2]}. "
            f"Registering the account also failed: {reg[0]}"
        );
    }
    if reg[1] {
        return str(reg[1]);
    }
    again = _login(client, cred, login_path);
    if again[0] is not None {
        return str(again[0]);
    }
    raise AuthenticationError(
        f"Registered {cred.username!r} for VU {vu_id}, but logging in "
        f"immediately afterwards failed: {again[2]}"
    );
}
