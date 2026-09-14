"""Test-data parameterization — vary what each VU sends, not just how often.

Phase 7c. A HAR replays the same request bodies for every VU and every
iteration, which distorts results in two directions (CONSTRAINTS.md section 2):

  * Reads hit a warm cache they would never hit in production. A search that
    always sends {"q": "hello"} measures the cache, not the query path.
  * Writes collide. The second VU to create a resource with the same unique
    name gets a 409 that has nothing to do with capacity.

Two ways to vary the payload, usable together:

  1. **Inline tokens** -- `{{uuid}}`, `{{vu_id}}`, `{{iter}}` and friends written
     into any body, query or header value. Needs no data file, which covers the
     common case of "make this unique per request".
  2. **`--param`** -- draw a field's value from a file of real values, so the
     traffic resembles production rather than a counter.

Substitution runs after correlation, so a token can appear anywhere without
disturbing the recorded ids correlation matches on -- and if the two ever target
the same field, the explicit --param wins, because a user naming a field is a
stronger signal than a heuristic.
"""

import csv;
import io;
import json;
import os;
import random;
import re;
import time;
import uuid as _uuid;

# {{name}} or {{name:arg}}. Deliberately narrow: a body that happens to contain
# braces (a JS snippet, a template the app itself renders) must pass through
# untouched, so only these known names are recognised and anything else is left
# exactly as written.
# `+` and `-` are part of the name so {{now+30s}} and {{now-5m}} parse as one
# token; an unrecognised name still falls through untouched.
glob _TOKEN_PATTERN: object = re.compile(r"\{\{\s*([a-zA-Z_][\w.+\-]*)\s*(?::([^}]*))?\s*\}\}");


obj ParamContext {
    # Everything a token can be resolved from, for one request.
    has vu_id: int = 0;
    has iteration: int = 0;
    has account: dict = {};
}

obj ParamRule {
    has endpoint: str;
    # "body.<json-path>", "query.<name>", or "header.<name>".
    has target: str;
    has values: list[str] = [];
    has source: str = "";

    def value_for(ctx: ParamContext) -> str {
        if not self.values {
            return "";
        }
        # Row selection walks with (vu_id, iteration) so a VU sees different data
        # each pass and two VUs in the same pass see different data. With an
        # account pool the VU's own row is the anchor, which keeps a VU's data
        # consistent with the identity it authenticated as.
        index = (ctx.vu_id + ctx.iteration) % len(self.values);
        return self.values[index];
    }
}


def _resolve_token(name: str, arg: str | None, ctx: ParamContext) -> str | None {
    # Returns None for an unrecognised token, which leaves it in the payload
    # untouched rather than replacing it with an empty string -- a silently
    # blanked field is far harder to notice than a literal {{typo}} in a request.
    lowered = name.lower();
    if lowered == "vu_id" {
        return str(ctx.vu_id);
    }
    if lowered == "iter" {
        return str(ctx.iteration);
    }
    if lowered == "uuid" {
        return str(_uuid.uuid4());
    }
    if lowered == "now" {
        return str(int(time.time()));
    }
    if lowered.startswith("now+") or lowered.startswith("now-") {
        # {{now+30s}} / {{now-5m}} — an absolute epoch offset, for payloads
        # carrying a deadline or a not-before that would be stale as recorded.
        return str(int(time.time()) + _parse_offset(lowered[3:]));
    }
    if lowered == "randint" {
        bounds = (arg or "").split(",");
        if len(bounds) != 2 {
            raise ValueError(
                "{{randint:a,b}} needs two comma-separated bounds, "
                f"got {arg!r}"
            );
        }
        try {
            low = int(bounds[0].strip());
            high = int(bounds[1].strip());
        } except ValueError as exc {
            raise ValueError(f"{{{{randint:{arg}}}}} bounds must be integers") from exc;
        }
        if low > high {
            raise ValueError(f"{{{{randint:{arg}}}}} has its bounds reversed");
        }
        return str(random.randint(low, high));
    }
    if lowered.startswith("account.") {
        key = name.split(".", 1)[1];
        if key in ctx.account {
            return str(ctx.account[key]);
        }
        return "";
    }
    if lowered.startswith("env.") {
        return os.environ.get(name.split(".", 1)[1], "");
    }
    return None;
}

def _parse_offset(text: str) -> int {
    # "+30s", "-5m", "+2h", or a bare signed number of seconds.
    body = text.strip();
    sign = 1;
    if body.startswith("+") {
        body = body[1:];
    } elif body.startswith("-") {
        sign = -1;
        body = body[1:];
    }
    multiplier = 1;
    if body.endswith("s") {
        body = body[:-1];
    } elif body.endswith("m") {
        multiplier = 60;
        body = body[:-1];
    } elif body.endswith("h") {
        multiplier = 3600;
        body = body[:-1];
    }
    try {
        return sign * int(float(body)) * multiplier;
    } except ValueError as exc {
        raise ValueError(f"{{{{now{text}}}}} is not a valid time offset") from exc;
    }
}

def substitute_tokens(text: str | None, ctx: ParamContext) -> str | None {
    if not text or "{{" not in text {
        return text;
    }

    def _replace(hit: object) -> str {
        resolved = _resolve_token(hit.group(1), hit.group(2), ctx);
        return hit.group(0) if resolved is None else resolved;
    }

    return _TOKEN_PATTERN.sub(_replace, text);
}

def has_tokens(text: str | None) -> bool {
    if not text or "{{" not in text {
        return False;
    }
    for hit in _TOKEN_PATTERN.finditer(text) {
        if _resolve_token(hit.group(1), hit.group(2), ParamContext()) is not None {
            return True;
        }
    }
    return False;
}


def _load_values(source: str) -> list[str] {
    # "values.csv" reads the first column; "values.csv:title" reads that named
    # column from a file with a header row. A one-value-per-line file is the
    # common shape and needs no header.
    path = source;
    column = None;
    if ":" in source {
        candidate = source.rsplit(":", 1);
        if not os.path.exists(source) and os.path.exists(candidate[0]) {
            path = candidate[0];
            column = candidate[1];
        }
    }
    if not os.path.exists(path) {
        raise ValueError(f"--param value file not found: {path!r}");
    }
    with open(path, "r", encoding="utf-8") as fh {
        content = fh.read();
    }
    if path.lower().endswith(".json") {
        parsed = json.loads(content);
        if not isinstance(parsed, list) {
            raise ValueError(f"--param JSON file {path!r} must hold a list of values");
        }
        return [str(item) for item in parsed];
    }
    if column is not None {
        reader = csv.DictReader(io.StringIO(content));
        names = [str(n).strip() for n in (reader.fieldnames or [])];
        if column not in names {
            raise ValueError(
                f"--param file {path!r} has no column {column!r}; found {names!r}"
            );
        }
        values = [str(row[column]).strip() for row in reader if row.get(column)];
    } else {
        values = [
            line.split(",")[0].strip()
            for line in content.splitlines()
            if line.strip()
        ];
    }
    if not values {
        raise ValueError(f"--param file {path!r} has no values");
    }
    return values;
}

def parse_param_rules(raw: list[str] | None) -> list[ParamRule] {
    # --param "Endpoint.body.field=values.csv"
    if not raw {
        return [];
    }
    rules: list[ParamRule] = [];
    for item in raw {
        text = str(item).strip();
        if "=" not in text {
            raise ValueError(
                "--param must be '<endpoint>.<target>=<file>', e.g. "
                f"--param 'AddTodo.body.title=titles.csv' — got {item!r}"
            );
        }
        (left, source) = [part.strip() for part in text.split("=", 1)];
        if "." not in left {
            raise ValueError(
                "--param target must name an endpoint and a field, e.g. "
                f"'AddTodo.body.title' — got {item!r}"
            );
        }
        (endpoint, target) = left.split(".", 1);
        if not target.startswith(("body.", "query.", "header.")) {
            raise ValueError(
                "--param target must start with body., query. or header.; "
                f"got {target!r}"
            );
        }
        rules.append(ParamRule(
            endpoint=endpoint.strip(),
            target=target.strip(),
            values=_load_values(source),
            source=source,
        ));
    }
    return rules;
}


obj ParamOutcome {
    has url: str;
    has body: str | None;
    has headers: dict = {};
    has applied: list[str] = [];
}

def apply_params(
    rules: list[ParamRule],
    ctx: ParamContext,
    endpoint: str,
    url: str,
    body: str | None,
    headers: dict,
) -> ParamOutcome {
    import from ..core.correlation { endpoint_matches }
    import from urllib.parse { urlparse, urlencode, parse_qsl, urlunparse }

    new_url = url;
    new_body = body;
    new_headers = dict(headers);
    applied: list[str] = [];

    # --param first, so a value drawn from a file can itself contain a token
    # ({{uuid}} appended to a name from a list, say) and still be expanded below.
    for rule in rules {
        if not endpoint_matches(rule.endpoint, endpoint) {
            continue;
        }
        value = rule.value_for(ctx);
        if rule.target.startswith("body.") {
            path = rule.target[len("body."):];
            updated = _set_body_path(new_body, path, value);
            if updated is not None {
                new_body = updated;
                applied.append(f"{rule.endpoint}.{rule.target}");
            }
        } elif rule.target.startswith("query.") {
            name = rule.target[len("query."):];
            parts = urlparse(new_url);
            pairs = parse_qsl(parts.query, keep_blank_values=True);
            replaced = False;
            out = [];
            for (key, existing) in pairs {
                if key == name {
                    out.append((key, value));
                    replaced = True;
                } else {
                    out.append((key, existing));
                }
            }
            if not replaced {
                out.append((name, value));
            }
            new_url = urlunparse(parts._replace(query=urlencode(out)));
            applied.append(f"{rule.endpoint}.{rule.target}");
        } else {
            new_headers[rule.target[len("header."):]] = value;
            applied.append(f"{rule.endpoint}.{rule.target}");
        }
    }

    # Tokens apply everywhere, including in values --param just wrote and in the
    # URL path (so {{vu_id}} can sit in a path segment, not just a query value).
    substituted_body = substitute_tokens(new_body, ctx);
    if substituted_body != new_body {
        applied.append("tokens.body");
    }
    new_body = substituted_body;

    substituted_url = substitute_tokens(new_url, ctx);
    if substituted_url != new_url {
        applied.append("tokens.url");
    }
    new_url = substituted_url;

    for (key, value) in list(new_headers.items()) {
        replacement = substitute_tokens(value, ctx);
        if replacement != value {
            new_headers[key] = replacement;
            applied.append(f"tokens.header.{key}");
        }
    }

    return ParamOutcome(
        url=new_url, body=new_body, headers=new_headers, applied=applied
    );
}

def _set_body_path(body: str | None, path: str, value: str) -> str | None {
    # Returns None when the body is not JSON or the path is absent, leaving the
    # request untouched: inventing a field the server never expects would turn a
    # misspelled --param into a confusing 400 rather than an obvious no-op.
    if not body {
        return None;
    }
    try {
        parsed = json.loads(body);
    } except Exception {
        return None;
    }
    parts = path.split(".");
    cursor = parsed;
    for part in parts[:-1] {
        if isinstance(cursor, list) {
            try {
                cursor = cursor[int(part)];
            } except Exception {
                return None;
            }
        } elif isinstance(cursor, dict) {
            if part not in cursor {
                return None;
            }
            cursor = cursor[part];
        } else {
            return None;
        }
    }
    leaf = parts[-1];
    if isinstance(cursor, list) {
        try {
            cursor[int(leaf)] = value;
        } except Exception {
            return None;
        }
    } elif isinstance(cursor, dict) {
        if leaf not in cursor {
            return None;
        }
        cursor[leaf] = value;
    } else {
        return None;
    }
    return json.dumps(parsed);
}

def describe_rules(rules: list[ParamRule]) -> str {
    return "\n".join(
        f"  {r.endpoint}.{r.target} <- {r.source} ({len(r.values)} values)"
        for r in rules
    );
}
