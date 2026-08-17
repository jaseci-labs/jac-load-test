"""Unit tests for core/graphql_engine.jac — scenario parsing only, no network."""

import from jac_loadtest_cli.core.graphql_engine {
    GraphQLScenarioConfig,
    parse_graphql_scenarios,
    scenarios_from_har_entries,
}
import from jac_loadtest_cli.core.har_parser { HarEntry }


test "parse graphql scenarios returns empty list for none or empty string" {
    assert parse_graphql_scenarios(None) == [];
    assert parse_graphql_scenarios("") == [];
    assert parse_graphql_scenarios([]) == [];
}

test "parse graphql scenarios accepts a json string" {
    raw = '[{"url": "ws://host/graphql", "query": "subscription { x }"}]';
    scenarios = parse_graphql_scenarios(raw);
    assert len(scenarios) == 1;
    assert scenarios[0].url == "ws://host/graphql";
    assert scenarios[0].query == "subscription { x }";
}

test "parse graphql scenarios accepts a plain list of dicts" {
    raw = [{
        "url": "ws://host/graphql",
        "query": "subscription { x }",
        "variables": {"id": 1},
        "operation_name": "OnX",
        "vus": 4,
        "max_events": 3,
    }];
    scenarios = parse_graphql_scenarios(raw);
    s = scenarios[0];
    assert s.variables == {"id": 1};
    assert s.operation_name == "OnX";
    assert s.vus == 4;
    assert s.max_events == 3;
}

test "parse graphql scenarios applies defaults for optional fields" {
    scenarios = parse_graphql_scenarios([{"url": "ws://host/graphql", "query": "subscription { x }"}]);
    s = scenarios[0];
    assert s.variables is None;
    assert s.operation_name is None;
    assert s.vus == 1;
    assert s.iterations == 1;
    assert s.duration is None;
    assert s.timeout == "30s";
    assert s.name == "";
    assert s.max_events == 0;
    assert s.headers == {};
}

test "parse graphql scenarios rejects invalid json string" {
    raised = False;
    try {
        parse_graphql_scenarios("not json");
    } except ValueError as exc {
        raised = True;
        assert "JSON" in str(exc);
    }
    assert raised;
}

test "parse graphql scenarios rejects an entry missing query" {
    raised = False;
    try {
        parse_graphql_scenarios([{"url": "ws://host/graphql"}]);
    } except ValueError as exc {
        raised = True;
        assert "query" in str(exc);
    }
    assert raised;
}

test "parse graphql scenarios rejects an entry missing url" {
    raised = False;
    try {
        parse_graphql_scenarios([{"query": "subscription { x }"}]);
    } except ValueError {
        raised = True;
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# scenarios_from_har_entries()
# ---------------------------------------------------------------------------

def _graphql_ws_entry(
    url: str = "ws://host/graphql",
    query: str | None = "subscription { x }",
    variables: dict | None = None,
    operation_name: str | None = None,
) -> HarEntry {
    return HarEntry(
        method="GET", url=url, headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url=url,
        protocol="graphql_ws", graphql_query=query,
        graphql_variables=variables, graphql_operation_name=operation_name,
    );
}

def _http_entry(url: str = "http://host/api") -> HarEntry {
    return HarEntry(
        method="GET", url=url, headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url=url,
    );
}

test "scenarios from har entries builds one scenario per graphql_ws-tagged entry" {
    entries = [_http_entry(), _graphql_ws_entry(query="subscription { orders { id } }", variables={"a": 1}, operation_name="OnX")];
    scenarios = scenarios_from_har_entries(entries);
    assert len(scenarios) == 1;
    assert scenarios[0].url == "ws://host/graphql";
    assert scenarios[0].query == "subscription { orders { id } }";
    assert scenarios[0].variables == {"a": 1};
    assert scenarios[0].operation_name == "OnX";
}

test "scenarios from har entries ignores http and ws tagged entries" {
    ws_entry = HarEntry(
        method="GET", url="ws://host/raw", headers={}, body=None, body_mime=None,
        think_time_ms=0.0, is_login=False, original_url="ws://host/raw", protocol="ws",
    );
    entries = [_http_entry(), ws_entry];
    assert scenarios_from_har_entries(entries) == [];
}

test "scenarios from har entries skips a graphql_ws entry with no query captured" {
    entries = [_graphql_ws_entry(query=None)];
    assert scenarios_from_har_entries(entries) == [];
}

test "scenarios from har entries applies the given vus and iterations" {
    entries = [_graphql_ws_entry()];
    scenarios = scenarios_from_har_entries(entries, vus=20, iterations=None);
    assert scenarios[0].vus == 20;
    assert scenarios[0].iterations is None;
}

test "scenarios from har entries returns empty list for no graphql_ws entries" {
    assert scenarios_from_har_entries([_http_entry()]) == [];
    assert scenarios_from_har_entries([]) == [];
}
