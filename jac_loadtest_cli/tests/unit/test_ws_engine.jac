"""Unit tests for core/ws_engine.jac — scenario parsing/naming only, no network."""

import from jac_loadtest_cli.core.ws_engine {
    WsScenarioConfig,
    parse_ws_scenarios,
    scenario_endpoint,
    scenarios_from_har_entries,
}
import from jac_loadtest_cli.core.har_parser { HarEntry }


# ---------------------------------------------------------------------------
# parse_ws_scenarios()
# ---------------------------------------------------------------------------

test "parse ws scenarios returns empty list for none or empty string" {
    assert parse_ws_scenarios(None) == [];
    assert parse_ws_scenarios("") == [];
    assert parse_ws_scenarios([]) == [];
}

test "parse ws scenarios accepts a json string" {
    raw = '[{"url": "ws://host/ws", "messages": ["ping"]}]';
    scenarios = parse_ws_scenarios(raw);
    assert len(scenarios) == 1;
    assert scenarios[0].url == "ws://host/ws";
    assert scenarios[0].messages == ["ping"];
}

test "parse ws scenarios accepts a plain list of dicts" {
    raw = [{"url": "ws://host/ws", "messages": ["a", "b"], "vus": 5}];
    scenarios = parse_ws_scenarios(raw);
    assert len(scenarios) == 1;
    assert scenarios[0].vus == 5;
    assert scenarios[0].messages == ["a", "b"];
}

test "parse ws scenarios applies defaults for optional fields" {
    scenarios = parse_ws_scenarios([{"url": "ws://host/ws"}]);
    s = scenarios[0];
    assert s.messages == [];
    assert s.vus == 1;
    assert s.iterations == 1;
    assert s.duration is None;
    assert s.timeout == "30s";
    assert s.name == "";
    assert s.think_time_ms == 0.0;
    assert s.headers == {};
}

test "parse ws scenarios rejects invalid json string" {
    raised = False;
    try {
        parse_ws_scenarios("not json");
    } except ValueError as exc {
        raised = True;
        assert "JSON" in str(exc);
    }
    assert raised;
}

test "parse ws scenarios rejects a non-array top level" {
    raised = False;
    try {
        parse_ws_scenarios('{"url": "ws://host/ws"}');
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse ws scenarios rejects an entry missing url" {
    raised = False;
    try {
        parse_ws_scenarios([{"messages": ["hi"]}]);
    } except ValueError as exc {
        raised = True;
        assert "url" in str(exc);
    }
    assert raised;
}

test "parse ws scenarios handles multiple scenarios" {
    scenarios = parse_ws_scenarios([
        {"url": "ws://a/ws", "vus": 2},
        {"url": "ws://b/ws", "vus": 3},
    ]);
    assert len(scenarios) == 2;
    assert scenarios[0].vus == 2;
    assert scenarios[1].vus == 3;
}


# ---------------------------------------------------------------------------
# scenario_endpoint()
# ---------------------------------------------------------------------------

test "scenario endpoint uses explicit name when given" {
    assert scenario_endpoint("ws://host/ws", "my-scenario", "WS") == "my-scenario";
}

test "scenario endpoint falls back to protocol label and url path" {
    assert scenario_endpoint("ws://host/ws/chat", "", "WS") == "WS /ws/chat";
}

test "scenario endpoint falls back to root path when url has none" {
    assert scenario_endpoint("ws://host", "", "GraphQL") == "GraphQL /";
}


# ---------------------------------------------------------------------------
# scenarios_from_har_entries()
# ---------------------------------------------------------------------------

def _ws_entry(url: str = "ws://host/ws", messages: list[str] | None = None) -> HarEntry {
    return HarEntry(
        method="GET", url=url, headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url=url,
        protocol="ws", ws_messages=messages if messages is not None else [],
    );
}

def _http_entry(url: str = "http://host/api") -> HarEntry {
    return HarEntry(
        method="GET", url=url, headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url=url,
    );
}

test "scenarios from har entries builds one scenario per ws-tagged entry" {
    entries = [_http_entry(), _ws_entry(messages=["ping"])];
    scenarios = scenarios_from_har_entries(entries);
    assert len(scenarios) == 1;
    assert scenarios[0].url == "ws://host/ws";
    assert scenarios[0].messages == ["ping"];
}

test "scenarios from har entries ignores http and graphql_ws tagged entries" {
    graphql_ws_entry = HarEntry(
        method="GET", url="ws://host/graphql", headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url="ws://host/graphql",
        protocol="graphql_ws", graphql_query="subscription { x }",
    );
    entries = [_http_entry(), graphql_ws_entry];
    assert scenarios_from_har_entries(entries) == [];
}

test "scenarios from har entries applies the given vus and iterations to every scenario" {
    entries = [_ws_entry(url="ws://a/ws"), _ws_entry(url="ws://b/ws")];
    scenarios = scenarios_from_har_entries(entries, vus=10, iterations=3);
    assert scenarios[0].vus == 10;
    assert scenarios[0].iterations == 3;
    assert scenarios[1].vus == 10;
    assert scenarios[1].iterations == 3;
}

test "scenarios from har entries returns empty list for no ws entries" {
    assert scenarios_from_har_entries([_http_entry()]) == [];
    assert scenarios_from_har_entries([]) == [];
}

test "scenarios from har entries carries an empty message list through when har had no frames" {
    scenarios = scenarios_from_har_entries([_ws_entry(messages=[])]);
    assert scenarios[0].messages == [];
}
