"""Unit tests for core/graphql_engine.jac — scenario parsing only, no network."""

import from jac_loadtest_cli.core.graphql_engine {
    GraphQLScenarioConfig,
    parse_graphql_scenarios,
}


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
