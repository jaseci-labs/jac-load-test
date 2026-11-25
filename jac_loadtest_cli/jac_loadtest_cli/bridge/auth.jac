"""Account pool for per-user authentication.

Parses the --accounts pool (inline JSON map or array, a .json file, or a .csv
file with username,password and optional extra columns) into Credential rows.
The login / register-on-401 / re-auth flow itself lives in runner/auth_flow.jac,
where it runs over the Locust HTTP client.

Each virtual user is assigned one account (round-robin) so N users exercise N
root graphs on jac-scale instead of contending on one. Extra columns are exposed
to parameterization as {{account.<col>}}.
"""

import csv;
import io;
import json;
import os;
import sys;

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

def _credentials_from_list(rows: list[any]) -> list[Credential] {
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
