"""Unit tests for bridge/body_check.jac — a 200 is not the same as a success."""

import from jac_loadtest_cli.bridge.body_check {
    ResponseShape, baseline_shapes, check_body, check_shape, shape_of
}
import from jac_loadtest_cli.core.har_parser { HarEntry }


def _entry(url: str, recorded: str | None) -> HarEntry {
    return HarEntry(
        method="POST", url=url, headers={}, body="{}", body_mime="application/json",
        think_time_ms=0.0, is_login=False, original_url=url,
        recorded_response=recorded,
    );
}

glob HAD_RESULTS: ResponseShape = ResponseShape(
    keys=["reports"], reports_non_empty=True, parsed=True
);


# ---------------------------------------------------------------------------
# check_body — the three failure markers
# ---------------------------------------------------------------------------

test "an error key in a 200 is flagged" {
    got = check_body(b'{"reports":[],"error":"node not found"}', None);
    assert got is not None;
    assert got.startswith("APP_ERROR_IN_200");
    assert "'error'" in got;
}

test "an errors key is flagged too" {
    assert check_body(b'{"errors":["boom"]}', None) is not None;
}

test "an inner status of 400 or more is flagged" {
    got = check_body(b'{"status":500}', None);
    assert got is not None;
    assert "inner status 500" in got;
    assert check_body(b'{"status":404}', None) is not None;
    # Below 400 is a normal response.
    assert check_body(b'{"status":200}', None) is None;
}

test "an empty reports array is only flagged when the recording had results" {
    empty = b'{"reports":[]}';
    # No baseline: an endpoint that always returns nothing is not a failure.
    assert check_body(empty, None) is None;
    assert check_body(empty, ResponseShape(keys=["reports"], parsed=True)) is None;
    # Baseline had results, so coming back empty is the walker failing quietly.
    got = check_body(empty, HAD_RESULTS);
    assert got is not None;
    assert "empty 'reports'" in got;
}

test "a healthy jac-scale response passes" {
    assert check_body(b'{"reports":[{"id":"x"}],"status":200}', HAD_RESULTS) is None;
}

test "a falsy error key is not a failure" {
    # {"error": null} and {"errors": []} are how a success is often spelled.
    assert check_body(b'{"error":null,"reports":[{"a":1}]}', None) is None;
    assert check_body(b'{"errors":[],"reports":[{"a":1}]}', None) is None;
}

test "a non-JSON or non-object body is left alone" {
    # Could be an infrastructure deny page — classifying that needs a view across
    # endpoints, which is 8a's job, not something to guess from one response.
    assert check_body(b"<html>403 Forbidden</html>", HAD_RESULTS) is None;
    assert check_body(b"[1,2,3]", HAD_RESULTS) is None;
    assert check_body(b"", HAD_RESULTS) is None;
}

test "a boolean status is not read as a status code" {
    assert check_body(b'{"status":true,"reports":[{"a":1}]}', None) is None;
}


# ---------------------------------------------------------------------------
# check_body — jac-scale's real envelope: {"ok", "type", "data": {"result": {...}}}
# ---------------------------------------------------------------------------

test "reports[].success false inside the jac-scale envelope is flagged" {
    # The shape a duplicate-name or quota-gate rejection actually takes: HTTP
    # 200, transport-level "ok": true, but the walker declined inside `reports`
    # nested two levels down. This used to be invisible.
    body = (
        b'{"ok":true,"type":"response","data":{"result":'
        b'{"reports":[{"success":false,"error":"PROJECT_LIMIT_REACHED"}]},'
        b'"reports":[{"success":false,"error":"PROJECT_LIMIT_REACHED"}]}}'
    );
    got = check_body(body, None);
    assert got is not None;
    assert got.startswith("APP_ERROR_IN_200");
    assert "PROJECT_LIMIT_REACHED" in got;
}

test "a healthy jac-scale envelope passes" {
    body = (
        b'{"ok":true,"type":"response","data":{"result":'
        b'{"reports":[{"success":true,"project":{"id":"prj_1"}}]},'
        b'"reports":[{"success":true,"project":{"id":"prj_1"}}]}}'
    );
    assert check_body(body, None) is None;
}

test "jac-scale's real ok:false + error shape is still flagged, via the error key" {
    # {"ok": false} alone is out of scope (see below) -- but jac-scale's actual
    # auth/transport error shape always carries an `error` object alongside
    # the flag, and that is what the existing 'error' key check catches.
    body = b'{"ok":false,"type":"error","data":null,"error":{"code":"UNAUTHORIZED","message":"Unauthorized"}}';
    got = check_body(body, None);
    assert got is not None;
    assert "'error'" in got;
}

test "a bare ok:false with no error/reports is left alone -- that's assert_json's job" {
    # H8: an app-specific 'ok' convention with nothing else is not something
    # this jac-scale-specific module should guess at.
    assert check_body(b'{"ok":false}', None) is None;
}

test "an empty reports array nested in the envelope is flagged against baseline" {
    nested_baseline = ResponseShape(keys=["data", "ok", "type"], reports_non_empty=True, parsed=True);
    empty = b'{"ok":true,"type":"response","data":{"result":{"reports":[]},"reports":[]}}';
    got = check_body(empty, nested_baseline);
    assert got is not None;
    assert "empty 'reports'" in got;
}

test "shape_of finds reports_non_empty inside the jac-scale envelope" {
    shape = shape_of('{"ok":true,"data":{"result":{"reports":[{"id":1}]},"reports":[{"id":1}]}}');
    assert shape.reports_non_empty;
    empty_shape = shape_of('{"ok":true,"data":{"result":{"reports":[]},"reports":[]}}');
    assert not empty_shape.reports_non_empty;
}


# ---------------------------------------------------------------------------
# shape_of / baseline_shapes / check_shape
# ---------------------------------------------------------------------------

test "shape_of records top-level keys and whether reports had results" {
    shape = shape_of('{"reports":[{"id":1}],"ok":true}');
    assert shape.parsed;
    assert shape.keys == ["ok", "reports"];
    assert shape.reports_non_empty;
    assert not shape_of('{"reports":[]}').reports_non_empty;
}

test "shape_of tolerates absent or unparseable bodies" {
    assert not shape_of(None).parsed;
    assert not shape_of("not json").parsed;
}

test "baseline_shapes indexes the recording by endpoint path" {
    shapes = baseline_shapes([
        _entry("http://h/walker/A", '{"reports":[{"id":1}]}'),
        _entry("http://h/walker/B", '{"reports":[]}'),
        _entry("http://h/walker/C", None),
    ]);
    assert sorted(shapes.keys()) == ["/walker/A", "/walker/B"];
    assert shapes["/walker/A"].reports_non_empty;
    assert not shapes["/walker/B"].reports_non_empty;
    # An endpoint recorded without a body has no baseline and is never compared.
    assert "/walker/C" not in shapes;
}

test "check_shape flags a response missing keys the recording had" {
    got = check_shape(b'{"other":1}', HAD_RESULTS);
    assert got is not None;
    assert got.startswith("SHAPE_DRIFT");
    assert "reports" in got;
}

test "check_shape ignores extra keys" {
    # An app gaining a field is not a regression worth failing a load test over.
    assert check_shape(b'{"reports":[{"a":1}],"new_field":2}', HAD_RESULTS) is None;
}

test "check_shape is a no-op without a usable baseline or body" {
    assert check_shape(b'{"other":1}', None) is None;
    assert check_shape(b'{"other":1}', ResponseShape()) is None;
    assert check_shape(b"not json", HAD_RESULTS) is None;
}
