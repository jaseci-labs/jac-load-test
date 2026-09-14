"""Unit tests for core/correlation.jac — detection, parsing, capture, injection."""

import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.correlation {
    CorrelationRule, CorrelationTable, apply_correlations, build_rules,
    detect_correlations, endpoint_matches, flatten_json, is_id_like,
    parse_correlate_rules
}

glob NODE: str = "a3f7c2d1-9f4b-4e2a-b123-77aa0912ffde";
glob OTHER: str = "ff91b823-1c44-4d0e-9a77-2b6610ccffaa";

def _e(
    url: str, body: str | None = None, response: str | None = None,
    annotations: list[str] | None = None
) -> HarEntry {
    return HarEntry(
        method="POST", url=url, headers={}, body=body,
        body_mime="application/json", think_time_ms=0.0, is_login=False,
        original_url=url, recorded_response=response,
        correlate_annotations=annotations or [],
    );
}


# ---------------------------------------------------------------------------
# is_id_like — the false-positive guard
# ---------------------------------------------------------------------------

test "is_id_like accepts server-generated identifiers" {
    assert is_id_like(NODE);
    assert is_id_like("usr_01HQ8X4ZK9");
    assert is_id_like("session-9f4b4e2a");
    assert is_id_like(1234567);
}

test "is_id_like rejects values that merely repeat" {
    # Correlating one of these would silently send different data than the
    # recording did, which is worse than not correlating at all.
    for value in [True, False, None, 1, 42, 200, "ok", "true", "active", "todo"] {
        assert not is_id_like(value);
    }
    assert not is_id_like("Buy milk today");
    assert not is_id_like("undefined");
    assert not is_id_like("processing");
}

test "is_id_like treats booleans as booleans not integers" {
    # In Python bool is a subclass of int, so an unguarded numeric branch would
    # let True through as though it were a number.
    assert not is_id_like(True);
}


# ---------------------------------------------------------------------------
# flatten_json
# ---------------------------------------------------------------------------

test "flatten_json walks objects and arrays into dotted paths" {
    flat = dict(flatten_json('{"reports": [{"id": "x", "n": 2}], "ok": true}'));
    assert flat["reports.0.id"] == "x";
    assert flat["reports.0.n"] == 2;
    assert flat["ok"] is True;
}

test "flatten_json tolerates non-JSON and empty bodies" {
    assert flatten_json(None) == [];
    assert flatten_json("") == [];
    assert flatten_json("<html>not json</html>") == [];
}


# ---------------------------------------------------------------------------
# detect_correlations — the static HAR scan
# ---------------------------------------------------------------------------

test "detect_correlations finds a value a later request replays" {
    entries = [
        _e("http://h/walker/AddTodo", '{"title":"x"}', '{"reports":[{"id":"' + NODE + '"}]}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', '{"reports":[{"ok":true}]}'),
    ];
    rules = detect_correlations(entries);
    assert len(rules) == 1;
    assert rules[0].producer == "/walker/AddTodo";
    assert rules[0].consumer == "/walker/ToggleTodo";
    assert rules[0].source_path == "reports.0.id";
    assert rules[0].recorded_value == NODE;
}

test "detect_correlations finds the id in a URL path as well as a body" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"reports":[{"id":"' + NODE + '"}]}'),
        _e(f"http://h/todo/{NODE}/toggle", None, "{}"),
    ];
    rules = detect_correlations(entries);
    assert len(rules) == 1;
    assert rules[0].recorded_value == NODE;
}

test "detect_correlations ignores values that are not identifiers" {
    entries = [
        _e("http://h/walker/A", "{}", '{"ok":true,"count":3,"status":"active"}'),
        _e("http://h/walker/B", '{"ok":true,"count":3,"status":"active"}', "{}"),
    ];
    assert detect_correlations(entries) == [];
}

test "detect_correlations skips a value produced by more than one endpoint" {
    # Two producers means no single source to attribute it to; guessing would be
    # worse than leaving it to an explicit --correlate rule.
    entries = [
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/B", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/C", '{"nd":"' + NODE + '"}', "{}"),
    ];
    assert detect_correlations(entries) == [];
}

test "detect_correlations only looks forward" {
    entries = [
        _e("http://h/walker/Use", '{"nd":"' + NODE + '"}', "{}"),
        _e("http://h/walker/Make", "{}", '{"id":"' + NODE + '"}'),
    ];
    assert detect_correlations(entries) == [];
}

test "detect_correlations chains through a multi-step workflow" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"reports":[{"id":"' + NODE + '"}]}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', '{"reports":[{"tag":"' + OTHER + '"}]}'),
        _e("http://h/walker/DeleteTag", '{"tag":"' + OTHER + '"}', "{}"),
    ];
    rules = detect_correlations(entries);
    pairs = {(r.producer, r.consumer) for r in rules};
    assert ("/walker/AddTodo", "/walker/ToggleTodo") in pairs;
    assert ("/walker/ToggleTodo", "/walker/DeleteTag") in pairs;
}

test "detect_correlations returns nothing when responses were not recorded" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", None),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', None),
    ];
    assert detect_correlations(entries) == [];
}


# ---------------------------------------------------------------------------
# parse_correlate_rules
# ---------------------------------------------------------------------------

test "parse_correlate_rules reads the documented flag form" {
    rules = parse_correlate_rules(
        ["AddTodo.response.reports.0.id -> ToggleTodo.body.nd"]
    );
    assert len(rules) == 1;
    assert rules[0].producer == "AddTodo";
    assert rules[0].source_path == "reports.0.id";
    assert rules[0].consumer == "ToggleTodo";
    assert rules[0].target_path == "body.nd";
    assert rules[0].recorded_value is None;
}

test "parse_correlate_rules rejects malformed rules with a usable message" {
    for bad in ["no arrow here", "A.b -> nodotsonright", "-> B.body.x"] {
        raised = False;
        try {
            parse_correlate_rules([bad]);
        } except ValueError as exc {
            raised = True;
            assert "--correlate" in str(exc);
        }
        assert raised;
    }
}

test "parse_correlate_rules accepts an empty or missing list" {
    assert parse_correlate_rules(None) == [];
    assert parse_correlate_rules([]) == [];
}


# ---------------------------------------------------------------------------
# endpoint_matches
# ---------------------------------------------------------------------------

test "endpoint_matches accepts a walker name or a full path" {
    assert endpoint_matches("/walker/AddTodo", "/walker/AddTodo");
    assert endpoint_matches("AddTodo", "/walker/AddTodo");
    assert not endpoint_matches("AddTodo", "/walker/DeleteTodo");
    assert not endpoint_matches("", "/walker/AddTodo");
}


# ---------------------------------------------------------------------------
# capture + apply
# ---------------------------------------------------------------------------

test "a detected rule swaps the recorded value for the captured one" {
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="reports.0.id",
        consumer="/walker/ToggleTodo", recorded_value=NODE, name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/AddTodo", b'{"reports":[{"id":"' + OTHER.encode() + b'"}]}', {});

    out = apply_correlations(
        [rule], table, "/walker/ToggleTodo",
        "http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}',
    );
    assert out.applied == ["r"];
    assert OTHER in out.body;
    assert NODE not in out.body;
}

test "a detected rule rewrites the URL when the id lives in the path" {
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="id",
        consumer="/todo", recorded_value=NODE, name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/AddTodo", b'{"id":"' + OTHER.encode() + b'"}', {});

    out = apply_correlations([rule], table, "/todo", f"http://h/todo/{NODE}/toggle", None);
    assert out.applied == ["r"];
    assert out.url == f"http://h/todo/{OTHER}/toggle";
}

test "an explicit rule injects by JSON path" {
    rule = CorrelationRule(
        producer="AddTodo", source_path="reports.0.id",
        consumer="ToggleTodo", target_path="body.nd", name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/AddTodo", b'{"reports":[{"id":"' + OTHER.encode() + b'"}]}', {});

    out = apply_correlations(
        [rule], table, "/walker/ToggleTodo", "http://h/walker/ToggleTodo", '{"nd":"stale"}'
    );
    assert out.applied == ["r"];
    import json;
    assert json.loads(out.body)["nd"] == OTHER;
}

test "capture can read a response header" {
    rule = CorrelationRule(
        producer="Login", source_path="header.X-Session",
        consumer="Next", target_path="body.session", name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/Login", b"{}", {"X-Session": OTHER});
    assert table.values["r"] == OTHER;
}

test "a missing source value is reported rather than sent stale" {
    # The producer never ran (or failed), so the value was never captured.
    # Sending the recording's id would read as a puzzling 404 blamed on the app.
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="reports.0.id",
        consumer="/walker/ToggleTodo", recorded_value=NODE, name="r",
    );
    out = apply_correlations(
        [rule], CorrelationTable(values={}), "/walker/ToggleTodo",
        "http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}',
    );
    assert out.missing == ["r"];
    assert out.applied == [];
}

test "correlation is a no-op for endpoints no rule names" {
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="id",
        consumer="/walker/ToggleTodo", recorded_value=NODE, name="r",
    );
    body = '{"nd":"' + NODE + '"}';
    out = apply_correlations([rule], CorrelationTable(values={}), "/walker/Unrelated", "http://h/x", body);
    assert out.applied == [];
    assert out.missing == [];
    assert out.body == body;
}

test "each table is independent so VUs never cross ids" {
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="id",
        consumer="/walker/ToggleTodo", recorded_value=NODE, name="r",
    );
    vu0 = CorrelationTable(values={});
    vu1 = CorrelationTable(values={});
    vu0.capture([rule], "/walker/AddTodo", b'{"id":"aaaa-1111-bbbb"}', {});
    vu1.capture([rule], "/walker/AddTodo", b'{"id":"cccc-2222-dddd"}', {});

    body = '{"nd":"' + NODE + '"}';
    assert "aaaa-1111-bbbb" in apply_correlations([rule], vu0, "/walker/ToggleTodo", "u", body).body;
    assert "cccc-2222-dddd" in apply_correlations([rule], vu1, "/walker/ToggleTodo", "u", body).body;
}

test "reset clears the table between iterations" {
    rule = CorrelationRule(
        producer="/walker/AddTodo", source_path="id",
        consumer="/walker/ToggleTodo", recorded_value=NODE, name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/AddTodo", b'{"id":"' + OTHER.encode() + b'"}', {});
    assert table.values;
    table.reset();
    assert table.values == {};
}


# ---------------------------------------------------------------------------
# build_rules — precedence
# ---------------------------------------------------------------------------

test "build_rules lets an explicit rule suppress a detected one" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"reports":[{"id":"' + NODE + '"}]}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', "{}"),
    ];
    rules = build_rules(
        entries, ["/walker/AddTodo.response.reports.0.id -> /walker/ToggleTodo.body.nd"],
        True, announce=False,
    );
    assert len(rules) == 1;
    assert rules[0].target_path == "body.nd";
}

test "build_rules honours an x-jac-correlate annotation" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", "{}",
           annotations=["AddTodo.response.reports.0.id -> ToggleTodo.body.nd"]),
        _e("http://h/walker/ToggleTodo", "{}", "{}"),
    ];
    rules = build_rules(entries, None, False, announce=False);
    assert len(rules) == 1;
    assert rules[0].consumer == "ToggleTodo";
}

test "build_rules detects nothing when auto-detection is off" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"reports":[{"id":"' + NODE + '"}]}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', "{}"),
    ];
    assert build_rules(entries, None, False, announce=False) == [];
    assert len(build_rules(entries, None, True, announce=False)) == 1;
}
