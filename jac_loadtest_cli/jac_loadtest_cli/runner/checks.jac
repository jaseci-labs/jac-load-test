"""Response checks shared by the Locust runner: --assert-json and --poll-until.

Pure functions over decoded response bodies; no Locust or network here, so they
are unit-testable on their own. Ported verbatim from the old core/engine.jac,
which they replace.
"""

import json;
import from ..core.correlation { endpoint_matches }

obj PollRule {
    has endpoint: str;
    has path: str;
    has success_values: list[str] = [];
    has error_values: list[str] = [];
}

def parse_poll_rules(
    poll_until: list[str] | None, poll_error_until: list[str] | None
) -> dict[str, PollRule] {
    # Both flags share one 'ENDPOINT:PATH=VALUE[,VALUE...]' syntax; --poll-until
    # values are the terminal SUCCESS states, --poll-error-until values are
    # terminal FAILURE states. Endpoint matching mirrors --assert-json /
    # --correlate: full path or walker short name (see endpoint_matches()).
    rules: dict[str, PollRule] = {};

    def _apply(raw: list[str] | None, is_error: bool) -> None {
        if not raw {
            return;
        }
        flag: str = "--poll-error-until" if is_error else "--poll-until";
        for expr in raw {
            if "=" not in expr {
                raise ValueError(
                    f"{flag} '{expr}' must be in 'ENDPOINT:PATH=VALUE[,VALUE...]' "
                    "form, e.g. '/job_control:status:data.state=running'"
                );
            }
            idx = expr.index("=");
            left = expr[:idx].strip();
            raw_values = expr[idx + 1:];
            if ":" not in left {
                raise ValueError(
                    f"{flag} '{expr}' must scope an endpoint before the path, "
                    "e.g. '/job_control:status:data.state=running'"
                );
            }
            (endpoint_part, _, path_part) = left.rpartition(":");
            endpoint = endpoint_part.strip();
            path = path_part.strip();
            if not endpoint or not path {
                raise ValueError(f"{flag} '{expr}' has an empty endpoint or path");
            }
            values = [v.strip() for v in raw_values.split(",") if v.strip()];
            if not values {
                raise ValueError(f"{flag} '{expr}' has no values after '='");
            }
            rule = rules.get(endpoint);
            if rule is None {
                rule = PollRule(endpoint=endpoint, path=path);
                rules[endpoint] = rule;
            } elif rule.path != path {
                raise ValueError(
                    f"{flag} '{expr}': endpoint '{endpoint}' already has a poll "
                    f"rule on a different path ('{rule.path}') — only one polled "
                    "field per endpoint is supported"
                );
            }
            if is_error {
                rule.error_values = rule.error_values + values;
            } else {
                rule.success_values = rule.success_values + values;
            }
        }
    }

    _apply(poll_until, False);
    _apply(poll_error_until, True);
    return rules;
}

def poll_rule_for(poll_rules: dict[str, PollRule] | None, path: str) -> PollRule | None {
    if not poll_rules {
        return None;
    }
    for rule in poll_rules.values() {
        if endpoint_matches(rule.endpoint, path) {
            return rule;
        }
    }
    return None;
}

def poll_body_match(body: bytes, rule: PollRule) -> str | None {
    # Returns "success"/"error" the moment the JSON field at rule.path matches
    # one of the configured terminal values, else None (not JSON, path
    # missing, or the value is still a non-terminal in-progress state — e.g.
    # "starting" — which is expected and not an error on its own). Resolution
    # is shared with --assert-json (resolve_json_path, defined further down
    # this file) — safe to call here even though it's defined later, since
    # this function only looks it up when actually invoked, not at def time.
    try {
        parsed = json.loads(body.decode("utf-8"));
    } except Exception {
        return None;
    }
    resolved = resolve_json_path(parsed, rule.path);
    if not resolved[0] {
        return None;
    }
    value = resolved[1];
    value_str = str(value).lower() if isinstance(value, bool) else str(value);
    for v in rule.error_values {
        if value_str == v or value_str.lower() == v.lower() {
            return "error";
        }
    }
    for v in rule.success_values {
        if value_str == v or value_str.lower() == v.lower() {
            return "success";
        }
    }
    return None;
}


def parse_assert_json(raw: list[str] | None) -> list[tuple[str, object, str]] {
    # Phase 8b — an assertion may be scoped to one endpoint by prefixing it with
    # that endpoint and a colon, mirroring --slo:
    #
    #   --assert-json 'ok=true'                              every response
    #   --assert-json '/walker/AddTodo:reports.0.id=*'       just that endpoint
    #
    # Returns (path, value, endpoint) triples; endpoint is "" for the global
    # form, which keeps working unchanged. `*` as the value asserts presence
    # rather than equality, which is what you usually want for an id.
    if not raw {
        return [];
    }
    assertions: list[tuple[str, object, str]] = [];
    for expr in raw {
        if "=" not in expr {
            raise ValueError(
                f"--assert-json '{expr}' must be in PATH=VALUE form, e.g. 'ok=true'"
            );
        }
        idx = expr.index("=");
        path = expr[:idx];
        raw_value = expr[idx + 1:];
        endpoint = "";
        if ":" in path {
            # Split on the last colon so a path may not contain one, but an
            # endpoint like "/walker/X" is unambiguous.
            (candidate, rest) = path.rsplit(":", 1);
            if candidate and rest {
                endpoint = candidate.strip();
                path = rest.strip();
            }
        }
        if not path {
            raise ValueError(f"--assert-json '{expr}' has an empty path before '='");
        }
        try {
            value = json.loads(raw_value);
        } except json.JSONDecodeError {
            # Not valid JSON on its own (e.g. `status=ok`) — compare as a
            # literal string so simple values don't need shell-quoted JSON.
            value = raw_value;
        }
        assertions.append((path, value, endpoint));
    }
    return assertions;
}

def assertions_for(
    assertions: list[tuple[str, object, str]], endpoint: str
) -> list[tuple[str, object, str]] {
    # The global ones plus any scoped to this endpoint.
        return [
        item for item in assertions
        if not item[2] or endpoint_matches(item[2], endpoint)
    ];
}

def resolve_json_path(body: object, path: str) -> tuple[bool, object] {
    cursor = body;
    for segment in path.split(".") {
        if isinstance(cursor, dict) {
            if segment not in cursor {
                return (False, None);
            }
            cursor = cursor[segment];
        } elif isinstance(cursor, list) {
            try {
                idx = int(segment);
            } except ValueError {
                return (False, None);
            }
            if idx < 0 or idx >= len(cursor) {
                return (False, None);
            }
            cursor = cursor[idx];
        } else {
            return (False, None);
        }
    }
    return (True, cursor);
}

def check_json_assertions(body: bytes, assertions: list[tuple[str, object, str]]) -> str | None {
    # Returns None when every assertion passes, else a short label for
    # error_type. The label never embeds the per-request actual value —
    # only the configured path/expected, which is constant for the whole
    # run — so every request that fails the SAME assertion collapses into
    # one error_breakdown bucket instead of one bucket per distinct body.
    try {
        parsed = json.loads(body.decode("utf-8"));
    } except Exception {
        return "ASSERTION_FAILED: response body is not valid JSON";
    }
    for assertion in assertions {
        path = assertion[0];
        expected = assertion[1];
        resolved = resolve_json_path(parsed, path);
        if not resolved[0] {
            return f"ASSERTION_FAILED: '{path}' missing from response";
        }
        if expected == "*" {
            # Presence-only: the path resolved above, which is the whole check.
            # Ids and tokens are the usual case -- you care that one came back,
            # not what it was.
            continue;
        }
        if resolved[1] != expected {
            return f"ASSERTION_FAILED: '{path}' expected {expected!r}";
        }
    }
    return None;
}

