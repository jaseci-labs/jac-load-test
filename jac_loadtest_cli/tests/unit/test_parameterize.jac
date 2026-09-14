"""Unit tests for core/parameterize.jac — tokens, --param rules, substitution."""

import os;
import tempfile;
import from jac_loadtest_cli.core.parameterize {
    ParamContext, ParamRule, apply_params, has_tokens, parse_param_rules,
    substitute_tokens
}


def _write(suffix: str, content: str) -> str {
    handle = tempfile.NamedTemporaryFile(
        "w", suffix=suffix, delete=False, encoding="utf-8"
    );
    handle.write(content);
    handle.close();
    return handle.name;
}

def _ctx(vu_id: int = 0, iteration: int = 0, account: dict | None = None) -> ParamContext {
    return ParamContext(vu_id=vu_id, iteration=iteration, account=account or {});
}


# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

test "vu_id and iter resolve from the request context" {
    got = substitute_tokens("vu{{vu_id}}-i{{iter}}", _ctx(vu_id=3, iteration=7));
    assert got == "vu3-i7";
}

test "uuid is different every time it is expanded" {
    ctx = _ctx();
    first = substitute_tokens("{{uuid}}", ctx);
    second = substitute_tokens("{{uuid}}", ctx);
    assert first != second;
    assert len(first) == 36;
}

test "randint stays within its bounds" {
    ctx = _ctx();
    for _i in range(40) {
        value = int(substitute_tokens("{{randint:5,9}}", ctx));
        assert 5 <= value <= 9;
    }
}

test "randint rejects malformed or reversed bounds" {
    ctx = _ctx();
    for bad in ["{{randint:5}}", "{{randint:a,b}}", "{{randint:9,5}}"] {
        raised = False;
        try {
            substitute_tokens(bad, ctx);
        } except ValueError {
            raised = True;
        }
        assert raised;
    }
}

test "now and its offsets produce epoch seconds" {
    import time;
    ctx = _ctx();
    now = int(substitute_tokens("{{now}}", ctx));
    assert abs(now - int(time.time())) <= 2;
    assert int(substitute_tokens("{{now+30s}}", ctx)) - now >= 29;
    assert int(substitute_tokens("{{now+2m}}", ctx)) - now >= 119;
    assert int(substitute_tokens("{{now-60s}}", ctx)) - now <= -59;
}

test "account columns resolve from the VU's own row" {
    ctx = _ctx(account={"region": "eu", "plan": "pro"});
    assert substitute_tokens("{{account.region}}/{{account.plan}}", ctx) == "eu/pro";
}

test "an unknown account column becomes empty rather than failing the run" {
    assert substitute_tokens("{{account.missing}}", _ctx(account={"region": "eu"})) == "";
}

test "env tokens read the environment" {
    os.environ["JAC_LOADTEST_TEST_TOKEN"] = "from-env";
    try {
        assert substitute_tokens("{{env.JAC_LOADTEST_TEST_TOKEN}}", _ctx()) == "from-env";
        assert substitute_tokens("{{env.DEFINITELY_NOT_SET_XYZ}}", _ctx()) == "";
    } finally {
        del os.environ["JAC_LOADTEST_TEST_TOKEN"];
    }
}

test "an unrecognised token is left exactly as written" {
    # Blanking it would be far harder to notice than a literal {{typo}} arriving
    # at the server.
    assert substitute_tokens("{{not_a_token}}", _ctx()) == "{{not_a_token}}";
    assert substitute_tokens("{{vu_idd}}", _ctx()) == "{{vu_idd}}";
}

test "text without tokens passes through untouched" {
    body = '{"js": "function(){ return {a:1}; }", "t": "plain"}';
    assert substitute_tokens(body, _ctx()) == body;
    assert substitute_tokens(None, _ctx()) is None;
    assert substitute_tokens("", _ctx()) == "";
}

test "several tokens in one value all expand" {
    got = substitute_tokens("{{vu_id}}-{{iter}}-{{vu_id}}", _ctx(vu_id=2, iteration=5));
    assert got == "2-5-2";
}

test "has_tokens only reports tokens that actually resolve" {
    assert has_tokens("a {{uuid}} b");
    assert has_tokens("{{account.region}}");
    assert not has_tokens("no tokens here");
    assert not has_tokens("{{unknown_thing}}");
    assert not has_tokens(None);
}


# ---------------------------------------------------------------------------
# parse_param_rules
# ---------------------------------------------------------------------------

test "parse_param_rules reads a one-value-per-line file" {
    path = _write(".csv", "Buy milk\nCall dentist\nFix the CI\n");
    try {
        rules = parse_param_rules([f"AddTodo.body.title={path}"]);
        assert len(rules) == 1;
        assert rules[0].endpoint == "AddTodo";
        assert rules[0].target == "body.title";
        assert rules[0].values == ["Buy milk", "Call dentist", "Fix the CI"];
    } finally {
        os.unlink(path);
    }
}

test "parse_param_rules can pick a named column" {
    path = _write(".csv", "id,title\n1,Alpha\n2,Beta\n");
    try {
        rules = parse_param_rules([f"AddTodo.body.title={path}:title"]);
        assert rules[0].values == ["Alpha", "Beta"];
    } finally {
        os.unlink(path);
    }
}

test "parse_param_rules reads a JSON list" {
    path = _write(".json", '["one","two"]');
    try {
        assert parse_param_rules([f"E.body.f={path}"])[0].values == ["one", "two"];
    } finally {
        os.unlink(path);
    }
}

test "parse_param_rules rejects malformed rules" {
    path = _write(".csv", "a\n");
    try {
        for bad in [
            "no equals sign",
            f"noDotTarget={path}",
            f"E.badtarget.x={path}",
        ] {
            raised = False;
            try {
                parse_param_rules([bad]);
            } except ValueError as exc {
                raised = True;
                assert "--param" in str(exc);
            }
            assert raised;
        }
    } finally {
        os.unlink(path);
    }
}

test "parse_param_rules reports a missing file and an unknown column" {
    raised = False;
    try {
        parse_param_rules(["E.body.f=/definitely/not/here.csv"]);
    } except ValueError as exc {
        raised = True;
        assert "not found" in str(exc);
    }
    assert raised;

    path = _write(".csv", "id,name\n1,x\n");
    try {
        raised = False;
        try {
            parse_param_rules([f"E.body.f={path}:missing"]);
        } except ValueError as exc {
            raised = True;
            assert "no column" in str(exc);
        }
        assert raised;
    } finally {
        os.unlink(path);
    }
}

test "parse_param_rules accepts nothing" {
    assert parse_param_rules(None) == [];
    assert parse_param_rules([]) == [];
}


# ---------------------------------------------------------------------------
# Row selection
# ---------------------------------------------------------------------------

test "rows advance with vu_id and iteration and wrap" {
    rule = ParamRule(endpoint="E", target="body.f", values=["a", "b", "c"]);
    assert rule.value_for(_ctx(vu_id=0, iteration=0)) == "a";
    assert rule.value_for(_ctx(vu_id=1, iteration=0)) == "b";
    assert rule.value_for(_ctx(vu_id=0, iteration=1)) == "b";
    # Two VUs in the same pass differ; one VU differs between passes.
    assert rule.value_for(_ctx(vu_id=3, iteration=0)) == "a";
}


# ---------------------------------------------------------------------------
# apply_params
# ---------------------------------------------------------------------------

test "a param rule replaces a body field" {
    rule = ParamRule(endpoint="AddTodo", target="body.title", values=["Alpha"]);
    out = apply_params(
        [rule], _ctx(), "/walker/AddTodo", "http://h/walker/AddTodo",
        '{"title":"recorded","other":1}', {},
    );
    import json;
    assert json.loads(out.body)["title"] == "Alpha";
    assert json.loads(out.body)["other"] == 1;
}

test "a param rule for a field the body lacks changes nothing" {
    # Inventing the field would turn a misspelled --param into a confusing 400
    # rather than an obvious no-op.
    rule = ParamRule(endpoint="AddTodo", target="body.nope", values=["x"]);
    body = '{"title":"recorded"}';
    out = apply_params([rule], _ctx(), "/walker/AddTodo", "u", body, {});
    assert out.body == body;
    assert out.applied == [];
}

test "a param rule sets a query parameter and a header" {
    rules = [
        ParamRule(endpoint="E", target="query.q", values=["searched"]),
        ParamRule(endpoint="E", target="header.X-Tier", values=["gold"]),
    ];
    out = apply_params([rules[0], rules[1]], _ctx(), "/E", "http://h/E?q=old&keep=1", None, {});
    assert "q=searched" in out.url;
    assert "keep=1" in out.url;
    assert out.headers["X-Tier"] == "gold";
}

test "params only touch the endpoint they name" {
    rule = ParamRule(endpoint="AddTodo", target="body.title", values=["Alpha"]);
    body = '{"title":"recorded"}';
    out = apply_params([rule], _ctx(), "/walker/Other", "u", body, {});
    assert out.body == body;
}

test "tokens expand in the body, the url and headers" {
    out = apply_params(
        [], _ctx(vu_id=4, iteration=2), "/E",
        "http://h/E?tag={{vu_id}}", '{"who":"vu{{vu_id}}-i{{iter}}"}',
        {"X-Run": "{{vu_id}}"},
    );
    assert "tag=4" in out.url;
    assert '"vu4-i2"' in out.body;
    assert out.headers["X-Run"] == "4";
}

test "a value drawn from a file can itself carry a token" {
    # --param is applied before token expansion precisely so this works: a list
    # of names plus a {{uuid}} suffix to keep them unique.
    rule = ParamRule(endpoint="E", target="body.name", values=["base-{{vu_id}}"]);
    out = apply_params([rule], _ctx(vu_id=9), "/E", "u", '{"name":"x"}', {});
    import json;
    assert json.loads(out.body)["name"] == "base-9";
}

test "apply_params with nothing to do leaves the request alone" {
    body = '{"a":1}';
    out = apply_params([], _ctx(), "/E", "http://h/E", body, {"H": "v"});
    assert out.body == body;
    assert out.url == "http://h/E";
    assert out.headers == {"H": "v"};
    assert out.applied == [];
}
