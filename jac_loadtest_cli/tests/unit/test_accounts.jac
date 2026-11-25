"""Unit tests for the Phase 7b account pool — parsing and VU assignment."""

import os;
import tempfile;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.bridge.auth { Credential, parse_accounts }


def _write(suffix: str, content: str) -> str {
    handle = tempfile.NamedTemporaryFile(
        "w", suffix=suffix, delete=False, encoding="utf-8"
    );
    handle.write(content);
    handle.close();
    return handle.name;
}


# ---------------------------------------------------------------------------
# parse_accounts — the input forms
# ---------------------------------------------------------------------------

test "parse_accounts reads an inline JSON map" {
    creds = parse_accounts('{"alice":"pw1","bob":"pw2"}');
    assert [c.username for c in creds] == ["alice", "bob"];
    assert [c.password for c in creds] == ["pw1", "pw2"];
}

test "parse_accounts preserves order so VU assignment is reproducible" {
    creds = parse_accounts('{"z":"1","a":"2","m":"3"}');
    assert [c.username for c in creds] == ["z", "a", "m"];
}

test "parse_accounts reads an inline JSON array of objects" {
    creds = parse_accounts('[{"username":"alice","password":"pw1"}]');
    assert creds[0].username == "alice";
    assert creds[0].password == "pw1";
}

test "parse_accounts accepts an already-parsed dict or list" {
    # The headless entry point passes structured data rather than a string.
    assert parse_accounts({"alice": "pw1"})[0].username == "alice";
    assert parse_accounts([{"username": "bob", "password": "pw2"}])[0].username == "bob";
}

test "parse_accounts reads a CSV file with a header row" {
    path = _write(".csv", "username,password\nalice,pw1\nbob,pw2\n");
    try {
        creds = parse_accounts(path);
        assert [c.username for c in creds] == ["alice", "bob"];
    } finally {
        os.unlink(path);
    }
}

test "parse_accounts tolerates CSV header casing, spacing and extra columns" {
    path = _write(".csv", " Username , Password ,region\n alice , pw1 ,eu\n");
    try {
        creds = parse_accounts(path);
        assert creds[0].username == "alice";
        assert creds[0].password == "pw1";
    } finally {
        os.unlink(path);
    }
}

test "parse_accounts reads a JSON file" {
    path = _write(".json", '{"alice":"pw1","bob":"pw2"}');
    try {
        assert len(parse_accounts(path)) == 2;
    } finally {
        os.unlink(path);
    }
}

test "parse_accounts returns nothing for absent input" {
    assert parse_accounts(None) == [];
    assert parse_accounts("") == [];
}

test "parse_accounts rejects a CSV missing the required columns" {
    path = _write(".csv", "user,secret\nalice,pw1\n");
    try {
        raised = False;
        try {
            parse_accounts(path);
        } except ValueError as exc {
            raised = True;
            assert "username" in str(exc);
        }
        assert raised;
    } finally {
        os.unlink(path);
    }
}

test "parse_accounts rejects a string that is neither JSON nor a file" {
    raised = False;
    try {
        parse_accounts("alice:pw1");
    } except ValueError as exc {
        raised = True;
        assert "neither valid JSON nor an existing file" in str(exc);
    }
    assert raised;
}

test "parse_accounts rejects malformed inline JSON" {
    raised = False;
    try {
        parse_accounts('{"alice": }');
    } except ValueError as exc {
        raised = True;
        assert "not valid JSON" in str(exc);
    }
    assert raised;
}
