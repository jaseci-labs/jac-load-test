"""Unit tests for core/correlation.jac — detection, parsing, capture, injection."""

import from jac_loadtest_cli.bridge.body_check { resolve_envelope_path }
import from jac_loadtest_cli.core.har_parser { HarEntry }
import from jac_loadtest_cli.core.correlation {
    CorrelationRule, CorrelationStats, CorrelationTable, apply_correlations, build_rules,
    correlation_report, describe_startup, describe_unresolved, detect_correlations, unresolved_rules, endpoint_matches, flatten_json, hydrate_explicit_rule,
    is_id_like, parse_correlate_rules
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

test "detect_correlations threads a value several responses carried from the first" {
    # create -> get -> list: the list query returns the id again, but the client
    # had already seen it from the create call.
    entries = [
        _e("http://h/walker/create_task", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/get_task", '{"task_id":"' + NODE + '"}', "{}"),
        _e("http://h/graphql", "{}", '{"tasks":[{"id":"' + NODE + '"}]}'),
    ];
    rules = detect_correlations(entries);
    assert len(rules) == 1;
    assert rules[0].producer == "/walker/create_task";
    assert rules[0].consumer == "/walker/get_task";
    assert rules[0].recorded_value == NODE;
}

test "detect_correlations records which producer it chose when a value is ambiguous" {
    entries = [
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/B", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/C", '{"nd":"' + NODE + '"}', "{}"),
    ];
    notes: list[dict[str, any]] = [];
    rules = detect_correlations(entries, notes);
    assert [(r.producer, r.consumer) for r in rules] == [("/walker/A", "/walker/C")];
    assert len(notes) == 1;
    assert notes[0]["kind"] == "ambiguous_value";
    assert notes[0]["chosen"] == "/walker/A:id";
    assert notes[0]["producers"] == ["/walker/A:id", "/walker/B:id"];
    assert notes[0]["consumers"] == ["/walker/C"];
    assert NODE not in str(notes[0]["value"]);
}

test "detect_correlations adds no note for a value with one producer" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', "{}"),
    ];
    notes: list[dict[str, any]] = [];
    detect_correlations(entries, notes);
    assert notes == [];
}

test "detect_correlations adds no note for an ambiguous value nothing consumes" {
    entries = [
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/B", "{}", '{"id":"' + NODE + '"}'),
    ];
    notes: list[dict[str, any]] = [];
    assert detect_correlations(entries, notes) == [];
    assert notes == [];
}

test "detect_correlations does not thread a value a request used before any response had it" {
    entries = [
        _e("http://h/walker/Use", '{"nd":"' + NODE + '"}', "{}"),
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/B", "{}", '{"id":"' + NODE + '"}'),
    ];
    assert detect_correlations(entries) == [];
}

test "detect_correlations marks its rules as detected" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', "{}"),
    ];
    assert detect_correlations(entries)[0].origin == "detected";
    assert parse_correlate_rules(["A.id -> B.body.x"])[0].origin == "explicit";
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
    for bad in ["no arrow here", "nodotsonleft -> B.body.x", "A.b -> "] {
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

test "parse_correlate_rules allows an omitted target path" {
    # Literal-substring mode (resolved later, from the HAR) doesn't need a
    # target path -- useful when you don't know or care which field carries it.
    rules = parse_correlate_rules(["ProjectOps.response.reports.0.project.id -> EnvOps"]);
    assert len(rules) == 1;
    assert rules[0].consumer == "EnvOps";
    assert rules[0].target_path == "";
    assert rules[0].recorded_value is None;
}


# ---------------------------------------------------------------------------
# hydrate_explicit_rule — the fix: give explicit rules a recorded_value too
# ---------------------------------------------------------------------------

test "hydrate_explicit_rule resolves an id-like value into literal-substring mode" {
    entries = [
        _e("http://h/walker/ProjectOps", "{}", '{"reports":[{"project":{"id":"' + NODE + '"}}]}'),
    ];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="reports.0.project.id", consumer="EnvOps",
        name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False);
    assert rule.recorded_value == NODE;
}

test "hydrate_explicit_rule leaves strict mode alone when nothing resolves" {
    entries = [_e("http://h/walker/ProjectOps", "{}", "{}")];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="reports.0.project.id", consumer="EnvOps",
        target_path="body.project_id", name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False);
    assert rule.recorded_value is None;
}

test "hydrate_explicit_rule requires a target path when it cannot resolve anything" {
    entries = [_e("http://h/walker/ProjectOps", "{}", "{}")];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="reports.0.project.id", consumer="EnvOps",
        name="r",
    );
    raised = False;
    try {
        hydrate_explicit_rule(entries, rule, announce=False);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "hydrate_explicit_rule falls back to strict mode for a non-id-like value" {
    entries = [_e("http://h/walker/A", "{}", '{"status":"confirmed"}')];
    rule = CorrelationRule(
        producer="A", source_path="status", consumer="B",
        target_path="body.status", name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False);
    assert rule.recorded_value is None;
}

test "hydrate_explicit_rule uses the first of several distinct values" {
    entries = [
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/A", "{}", '{"id":"' + OTHER + '"}'),
    ];
    rule = CorrelationRule(producer="A", source_path="id", consumer="B", name="r");
    hydrate_explicit_rule(entries, rule, announce=False);
    assert rule.recorded_value == NODE;
}

test "a hydrated explicit rule substitutes inside a larger string, unlike strict mode" {
    # e.g. {"return_to": "/project/{id}"} -- strict field-set could only
    # overwrite the whole field, destroying the surrounding text.
    entries = [
        _e("http://h/walker/ProjectOps", "{}", '{"reports":[{"project":{"id":"' + NODE + '"}}]}'),
    ];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="reports.0.project.id",
        consumer="PreviewAuthOps", name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False);

    table = CorrelationTable(values={});
    table.capture(
        [rule], "/walker/ProjectOps",
        b'{"reports":[{"project":{"id":"' + OTHER.encode() + b'"}}]}', {},
    );
    out = apply_correlations(
        [rule], table, "/walker/PreviewAuthOps", "http://h/walker/PreviewAuthOps",
        '{"return_to":"/project/' + NODE + '"}',
    );
    assert out.applied == ["r"];
    assert f'"return_to":"/project/{OTHER}"' in out.body;
}

test "a hydrated explicit rule does not flag an occurrence missing the field" {
    # env_ops's list_global body is just {"action":"env_list"} -- no project_id
    # field at all. Strict mode's unconditional missing-check would abort this
    # request even though there was never anything to fix.
    entries = [
        _e("http://h/walker/ProjectOps", "{}", '{"reports":[{"project":{"id":"' + NODE + '"}}]}'),
    ];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="reports.0.project.id",
        consumer="EnvOps", name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False);

    table = CorrelationTable(values={});
    table.capture(
        [rule], "/walker/ProjectOps",
        b'{"reports":[{"project":{"id":"' + OTHER.encode() + b'"}}]}', {},
    );
    out = apply_correlations(
        [rule], table, "/walker/EnvOps", "http://h/walker/EnvOps", '{"action":"env_list"}',
    );
    assert out.applied == [];
    assert out.missing == [];
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
    assert out.body is not None;
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

test "capture without a resolver matches the source path literally" {
    rule = CorrelationRule(
        producer="AddTodo", source_path="data.result.reports.0.id",
        consumer="Next", target_path="body.nd", name="r",
    );
    table = CorrelationTable(values={});
    table.capture([rule], "/walker/AddTodo", b'{"data":{"reports":[{"id":"' + OTHER.encode() + b'"}]}}', {});
    assert "r" not in table.values;
}

test "capture with the envelope resolver reads a 0.34 path from a 0.37+ response" {
    rule = CorrelationRule(
        producer="AddTodo", source_path="data.result.reports.0.id",
        consumer="Next", target_path="body.nd", name="r",
    );
    table = CorrelationTable(values={});
    table.capture(
        [rule], "/walker/AddTodo",
        b'{"data":{"result":{"name":"x"},"reports":[{"id":"' + OTHER.encode() + b'"}]}}', {},
        resolve_envelope_path
    );
    assert table.values["r"] == OTHER;
}

test "capture with the envelope resolver reads a 0.37+ path from a 0.34 response" {
    rule = CorrelationRule(
        producer="AddTodo", source_path="data.reports.0.id",
        consumer="Next", target_path="body.nd", name="r",
    );
    table = CorrelationTable(values={});
    table.capture(
        [rule], "/walker/AddTodo",
        b'{"data":{"result":{"reports":[{"id":"' + OTHER.encode() + b'"}]}}}', {},
        resolve_envelope_path
    );
    assert table.values["r"] == OTHER;
}

test "hydrate_explicit_rule resolves a 0.34 path against a 0.37+ recording" {
    entries = [
        _e("http://h/walker/ProjectOps", "{}", '{"data":{"reports":[{"project":{"id":"' + NODE + '"}}]}}'),
    ];
    rule = CorrelationRule(
        producer="ProjectOps", source_path="data.result.reports.0.project.id",
        consumer="EnvOps", name="r",
    );
    hydrate_explicit_rule(entries, rule, announce=False, resolve=resolve_envelope_path);
    assert rule.recorded_value == NODE;
}

test "build_rules passes the resolver to explicit rule hydration" {
    entries = [
        _e("http://h/walker/ProjectOps", "{}", '{"data":{"reports":[{"project":{"id":"' + NODE + '"}}]}}'),
        _e("http://h/walker/EnvOps", '{"project":"' + NODE + '"}', None),
    ];
    rules = build_rules(
        entries, ["ProjectOps.data.result.reports.0.project.id -> EnvOps"], False,
        announce=False, resolve=resolve_envelope_path,
    );
    assert len(rules) == 1;
    assert rules[0].recorded_value == NODE;
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

test "build_rules hydrates an explicit rule from the HAR" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"reports":[{"id":"' + NODE + '"}]}'),
        _e("http://h/walker/ToggleTodo", "{}", "{}"),
    ];
    rules = build_rules(
        entries, ["AddTodo.reports.0.id -> ToggleTodo"], False, announce=False,
    );
    assert len(rules) == 1;
    assert rules[0].recorded_value == NODE;
}

test "build_rules raises when an explicit rule cannot resolve and has no fallback path" {
    entries = [_e("http://h/walker/AddTodo", "{}", "{}")];
    raised = False;
    try {
        build_rules(entries, ["AddTodo.id -> ToggleTodo"], False, announce=False);
    } except ValueError {
        raised = True;
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# CorrelationStats — what each rule did during the run
# ---------------------------------------------------------------------------

def _stat_rule() -> CorrelationRule {
    return CorrelationRule(
        producer="AddTodo", source_path="reports.0.id", consumer="ToggleTodo",
        target_path="body.nd", name="r",
    );
}

test "capture counts a producer run and a capture" {
    stats = CorrelationStats();
    table = CorrelationTable(values={});
    table.capture([_stat_rule()], "/walker/AddTodo", b'{"reports":[{"id":"' + OTHER.encode() + b'"}]}', {}, None, stats);
    assert stats.counts["r"] == {"producer_runs": 1, "captured": 1, "applied": 0, "missed": 0};
}

test "capture counts a producer run that yielded nothing" {
    stats = CorrelationStats();
    table = CorrelationTable(values={});
    table.capture([_stat_rule()], "/walker/AddTodo", b'{"data":{}}', {}, None, stats);
    assert stats.counts["r"] == {"producer_runs": 1, "captured": 0, "applied": 0, "missed": 0};
}

test "capture ignores endpoints that are not the rule's producer" {
    stats = CorrelationStats();
    table = CorrelationTable(values={});
    table.capture([_stat_rule()], "/walker/Other", b"{}", {}, None, stats);
    assert stats.counts == {};
}

test "apply_correlations counts applied and missed" {
    stats = CorrelationStats();
    rule = _stat_rule();
    table = CorrelationTable(values={"r": OTHER});
    apply_correlations([rule], table, "/walker/ToggleTodo", "http://h/walker/ToggleTodo", '{"nd":"stale"}', stats);
    apply_correlations([rule], CorrelationTable(values={}), "/walker/ToggleTodo", "http://h/walker/ToggleTodo", '{"nd":"stale"}', stats);
    assert stats.counts["r"]["applied"] == 1;
    assert stats.counts["r"]["missed"] == 1;
}

test "stats are optional so existing callers are unaffected" {
    table = CorrelationTable(values={});
    table.capture([_stat_rule()], "/walker/AddTodo", b"{}", {});
    out = apply_correlations([_stat_rule()], table, "/walker/ToggleTodo", "u", "{}");
    assert out.missing == ["r"];
}

test "absorb adds another process's counts" {
    mine = CorrelationStats();
    mine.bump("r", "captured");
    mine.absorb({"r": {"producer_runs": 4, "captured": 2, "applied": 1, "missed": 0}, "s": {"producer_runs": 1}});
    assert mine.counts["r"] == {"producer_runs": 4, "captured": 3, "applied": 1, "missed": 0};
    assert mine.counts["s"]["producer_runs"] == 1;
    assert mine.counts["s"]["captured"] == 0;
}

test "unresolved_rules flags a rule whose producer ran but never captured" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 5, "captured": 0, "applied": 0, "missed": 5}});
    assert unresolved_rules([_stat_rule()], stats) == ["r"];
}

test "unresolved_rules ignores a rule whose producer never ran" {
    # Aborted run, unroutable producer: the misses say nothing about the rule.
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 0, "captured": 0, "applied": 0, "missed": 3}});
    assert unresolved_rules([_stat_rule()], stats) == [];
}

test "unresolved_rules ignores a rule that captured and injected at least once" {
    # Misses on iterations where the producer failed are normal under load.
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 5, "captured": 4, "applied": 3, "missed": 1}});
    assert unresolved_rules([_stat_rule()], stats) == [];
}

test "unresolved_rules flags a rule that captured but never injected" {
    # The source matched, the target path is not in the consumer request.
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 5, "captured": 5, "applied": 0, "missed": 5}});
    assert unresolved_rules([_stat_rule()], stats) == ["r"];
}

test "unresolved_rules does not flag a captured rule whose consumer never ran" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 5, "captured": 5, "applied": 0, "missed": 0}});
    assert unresolved_rules([_stat_rule()], stats) == [];
}

test "unresolved_rules ignores a rule that captured but never injected when the producer never ran" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 0, "captured": 0, "applied": 0, "missed": 2}});
    assert unresolved_rules([_stat_rule()], stats) == [];
}

test "correlation_report lists every rule, including idle ones" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 2, "captured": 0, "applied": 0, "missed": 2}});
    idle = CorrelationRule(producer="P", source_path="id", consumer="C", recorded_value=NODE, name="idle");
    corr = correlation_report([_stat_rule(), idle], stats);
    assert [row["rule"] for row in corr["rules"]] == ["r", "idle"];
    assert corr["rules"][0]["mode"] == "explicit-path";
    assert corr["rules"][1]["mode"] == "literal";
    assert corr["rules"][1]["producer_runs"] == 0;
    assert corr["unresolved"] == ["r"];
}

test "describe_unresolved names the rule and what it cost" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 7, "captured": 0, "applied": 0, "missed": 6}});
    lines = describe_unresolved(correlation_report([_stat_rule()], stats));
    assert len(lines) == 1;
    assert "'r'" in lines[0];
    assert "7 time(s)" in lines[0];
    assert "6 request(s)" in lines[0];
    assert describe_unresolved({}) == [];
}

test "describe_unresolved tells a target-path miss from a source miss" {
    stats = CorrelationStats();
    stats.absorb({"r": {"producer_runs": 4, "captured": 4, "applied": 0, "missed": 4}});
    lines = describe_unresolved(correlation_report([_stat_rule()], stats));
    assert len(lines) == 1;
    assert "never injected" in lines[0];
    assert "target path" in lines[0];
    assert "never captured" not in lines[0];
}


# ---------------------------------------------------------------------------
# Build-time notes and the startup summary
# ---------------------------------------------------------------------------

test "build_rules passes notes through to detection" {
    entries = [
        _e("http://h/walker/A", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/B", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/C", '{"nd":"' + NODE + '"}', "{}"),
    ];
    notes: list[dict[str, any]] = [];
    rules = build_rules(entries, None, True, announce=False, notes=notes);
    assert len(rules) == 1;
    assert len(notes) == 1;
}

test "correlation_report carries the build notes" {
    note = {"kind": "ambiguous_value", "value": "x", "producers": [], "chosen": "a", "consumers": []};
    assert correlation_report([], CorrelationStats(), [note])["notes"] == [note];
    assert correlation_report([], CorrelationStats())["notes"] == [];
}

test "describe_startup is empty when there is nothing to say" {
    assert describe_startup([], []) == [];
}

test "describe_startup lists the rules and says how many were detected" {
    entries = [
        _e("http://h/walker/AddTodo", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/ToggleTodo", '{"nd":"' + NODE + '"}', "{}"),
    ];
    notes: list[dict[str, any]] = [];
    rules = build_rules(entries, None, True, announce=False, notes=notes);
    text = "\n".join(describe_startup(rules, notes));
    assert "1 rule(s)" in text;
    assert "1 detected, 0 explicit" in text;
    assert "AddTodo.response.id -> ToggleTodo" in text;
}

test "describe_startup names the chosen producer for an ambiguous value" {
    entries = [
        _e("http://h/walker/create_task", "{}", '{"id":"' + NODE + '"}'),
        _e("http://h/walker/get_task", '{"task_id":"' + NODE + '"}', "{}"),
        _e("http://h/graphql", "{}", '{"tasks":[{"id":"' + NODE + '"}]}'),
    ];
    notes: list[dict[str, any]] = [];
    rules = build_rules(entries, None, True, announce=False, notes=notes);
    text = "\n".join(describe_startup(rules, notes));
    assert "appears in 2 recorded responses" in text;
    assert "threaded from /walker/create_task:id" in text;
    assert "into get_task" in text;
    assert "--correlate" in text;
}
