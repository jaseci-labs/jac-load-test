"""Unit tests for --poll-until / --poll-error-until support in core/engine.jac
(jaseci-labs/jacBuilder#1882: a status-polling endpoint that always answers
200/"success":true while a background launch is still in progress cannot be
caught by status-code scoring alone, no matter how many times it is
replayed -- the response body has to be read and compared against a
caller-supplied terminal state).

Covers the pure, synchronous pieces: rule parsing/validation
(parse_poll_rules), endpoint lookup (_poll_rule_for), and the JSON-path
terminal-state matcher (_poll_body_match). The async wait-until loop itself
(_run_poll_block) is exercised only through these building blocks, in
keeping with this test tree's existing convention of not spinning up a real
network server (see tests/unit/test_process_runner.jac's module docstring);
its behavior is a direct, small composition of _send_request (already
covered elsewhere) and the matcher tested here.
"""

import from jac_loadtest_cli.core.engine { PollRule, parse_poll_rules, _poll_rule_for, _poll_body_match }


# ---------------------------------------------------------------------------
# parse_poll_rules — syntax and validation
# ---------------------------------------------------------------------------

test "parse_poll_rules with nothing given returns an empty dict" {
    rules = parse_poll_rules(None, None);
    assert rules == {};
}

test "parse_poll_rules reads a single success rule" {
    rules = parse_poll_rules(["/preview_control:status:data.state=running"], None);
    assert list(rules.keys()) == ["/preview_control:status"];
    rule = rules["/preview_control:status"];
    assert rule.path == "data.state";
    assert rule.success_values == ["running"];
    assert rule.error_values == [];
}

test "parse_poll_rules reads a comma-separated list of terminal values" {
    rules = parse_poll_rules(["/status:state=running,ready,done"], None);
    assert rules["/status"].success_values == ["running", "ready", "done"];
}

test "parse_poll_rules merges --poll-until and --poll-error-until on the same endpoint" {
    rules = parse_poll_rules(
        ["/preview_control:status:data.state=running"],
        ["/preview_control:status:data.state=error,failed"],
    );
    assert len(rules) == 1;
    rule = rules["/preview_control:status"];
    assert rule.success_values == ["running"];
    assert rule.error_values == ["error", "failed"];
}

test "parse_poll_rules handles a path containing a colon (walker-style endpoint)" {
    # rpartition on the LAST ':' before '=' -- the endpoint itself may contain
    # colons (e.g. jac-scale's "/preview_control:status" walker naming).
    rules = parse_poll_rules(["/preview_control:status:data.state=running"], None);
    assert "/preview_control:status" in rules;
}

test "parse_poll_rules rejects an expression with no '='" {
    raised = False;
    try {
        parse_poll_rules(["/status:data.state"], None);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_poll_rules rejects an expression with no endpoint scope" {
    raised = False;
    try {
        parse_poll_rules(["state=running"], None);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_poll_rules rejects empty values after '='" {
    raised = False;
    try {
        parse_poll_rules(["/status:state="], None);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_poll_rules rejects two different paths on the same endpoint" {
    raised = False;
    try {
        parse_poll_rules(["/status:a=1", "/status:b=2"], None);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_poll_rules --poll-error-until alone works without --poll-until" {
    rules = parse_poll_rules(None, ["/status:state=error"]);
    assert rules["/status"].success_values == [];
    assert rules["/status"].error_values == ["error"];
}


# ---------------------------------------------------------------------------
# _poll_rule_for — endpoint lookup (mirrors --assert-json / --correlate:
# full path or walker short name)
# ---------------------------------------------------------------------------

test "_poll_rule_for finds a rule by exact path" {
    rules = parse_poll_rules(["/walker/Launch:data.state=running"], None);
    found = _poll_rule_for(rules, "/walker/Launch");
    assert found is not None;
    assert found.path == "data.state";
}

test "_poll_rule_for finds a rule by short walker name" {
    rules = parse_poll_rules(["Launch:data.state=running"], None);
    found = _poll_rule_for(rules, "/walker/Launch");
    assert found is not None;
}

test "_poll_rule_for returns None for an unrelated path" {
    rules = parse_poll_rules(["/walker/Launch:data.state=running"], None);
    assert _poll_rule_for(rules, "/walker/Other") is None;
}

test "_poll_rule_for returns None when no rules are configured" {
    assert _poll_rule_for(None, "/walker/Launch") is None;
    assert _poll_rule_for({}, "/walker/Launch") is None;
}


# ---------------------------------------------------------------------------
# _poll_body_match — the terminal-state predicate
# ---------------------------------------------------------------------------

test "_poll_body_match returns success when the field matches a success value" {
    rule = PollRule(endpoint="/status", path="data.state", success_values=["running"], error_values=["error"]);
    body = b'{"data": {"state": "running"}}';
    assert _poll_body_match(body, rule) == "success";
}

test "_poll_body_match returns error when the field matches an error value" {
    rule = PollRule(endpoint="/status", path="data.state", success_values=["running"], error_values=["error"]);
    body = b'{"data": {"state": "error"}}';
    assert _poll_body_match(body, rule) == "error";
}

test "_poll_body_match returns None for a non-terminal in-progress state" {
    # This is the whole point: a poll still "starting" must NOT be treated as
    # a failure just because it isn't the configured success value yet.
    rule = PollRule(endpoint="/status", path="data.state", success_values=["running"], error_values=["error"]);
    body = b'{"data": {"state": "starting"}}';
    assert _poll_body_match(body, rule) is None;
}

test "_poll_body_match returns None when the path is missing from the body" {
    rule = PollRule(endpoint="/status", path="data.state", success_values=["running"]);
    body = b'{"data": {}}';
    assert _poll_body_match(body, rule) is None;
}

test "_poll_body_match returns None for a non-JSON body" {
    rule = PollRule(endpoint="/status", path="data.state", success_values=["running"]);
    assert _poll_body_match(b"not json", rule) is None;
}

test "_poll_body_match compares case-insensitively" {
    rule = PollRule(endpoint="/status", path="data.state", success_values=["Running"]);
    body = b'{"data": {"state": "running"}}';
    assert _poll_body_match(body, rule) == "success";
}

test "_poll_body_match works on a boolean terminal field" {
    rule = PollRule(endpoint="/status", path="ready", success_values=["true"]);
    body = b'{"ready": true}';
    assert _poll_body_match(body, rule) == "success";
}

test "_poll_body_match checks error values before success values" {
    # Guards against the two lists ever being allowed to overlap silently --
    # if a value is (misconfigured to be) in both, error wins rather than the
    # outcome depending on dict/list ordering.
    rule = PollRule(endpoint="/status", path="state", success_values=["done"], error_values=["done"]);
    body = b'{"state": "done"}';
    assert _poll_body_match(body, rule) == "error";
}
