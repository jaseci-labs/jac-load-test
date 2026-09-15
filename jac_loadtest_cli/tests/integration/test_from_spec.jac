"""Integration tests for cli.jac:run_from_spec — the 'jac x loadtest from-spec'
subcommand. Exercises the CLI entry point end to end (argv -> written HAR file)
without going through a subprocess."""

import io;
import json;
import sys;
import tempfile;
import from jac_loadtest_cli.cli { run_from_spec }
import from jac_loadtest_cli.core.har_parser { parse_har }

glob _SPEC: dict = {
    "openapi": "3.0.3",
    "info": {"title": "Mini", "version": "1.0"},
    "servers": [{"url": "http://localhost:8000"}],
    "paths": {
        "/ping": {
            "get": {"operationId": "Ping", "responses": {"200": {"description": "ok"}}},
        },
    },
};


def _write_spec(spec: dict) -> str {
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False);
    json.dump(spec, tmp);
    tmp.close();
    return tmp.name;
}


test "from-spec writes a HAR file parse_har can read" {
    spec_path = _write_spec(_SPEC);
    out_path = tempfile.NamedTemporaryFile(suffix=".har", delete=False).name;

    old_stdout = sys.stdout;
    buf = io.StringIO();
    sys.stdout = buf;
    try {
        run_from_spec([spec_path, "--out", out_path]);
    } finally {
        sys.stdout = old_stdout;
    }
    output = buf.getvalue();

    assert "Wrote 1 entries" in output;
    entries = parse_har(out_path, target_url="http://target:9000");
    assert len(entries) == 1;
    assert entries[0].method == "GET";
    assert entries[0].url == "http://target:9000/ping";
}

test "from-spec on a missing source exits 2" {
    out_path = tempfile.NamedTemporaryFile(suffix=".har", delete=False).name;
    exit_code = None;
    try {
        run_from_spec(["/no/such/spec.json", "--out", out_path]);
    } except SystemExit as exc {
        exit_code = exc.code;
    }
    assert exit_code == 2;
}
