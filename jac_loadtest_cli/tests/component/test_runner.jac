"""Component tests: a real Locust run (in a child process) against a mock jac-scale server.

The point is ground truth. The mock counts every request it receives, and each test
checks what the load tool *reports* against what the server *saw*, then injects a
known fault and checks the report names it. The test process itself never imports
Locust: runs go through runner/subproc.jac.
"""

import json;
import os;
import tempfile;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.runner.subproc { run_in_subprocess }
import from tests.support.mock_server { start_mock, stop_mock, MockServer }


def _entry(base: str, path: str, body: dict[str, any], reply: dict[str, any]) -> dict[str, any] {
    return {
        "startedDateTime": "2026-01-01T00:00:00.000Z", "time": 5,
        "request": {
            "method": "POST", "url": base + path,
            "headers": [{"name": "Content-Type", "value": "application/json"}],
            "postData": {"mimeType": "application/json", "text": json.dumps(body)},
        },
        "response": {"status": 200, "content": {"mimeType": "application/json", "text": json.dumps(reply)}},
    };
}

def _ws_entry(base: str, path: str, frames: list[str]) -> dict[str, any] {
    return {
        "startedDateTime": "2026-01-01T00:00:01.000Z", "time": 5,
        "request": {"method": "GET", "url": base.replace("http://", "ws://") + path, "headers": []},
        "response": {"status": 101, "content": {"mimeType": "x-unknown", "text": ""}},
        "_resourceType": "websocket",
        "_webSocketMessages": [{"type": "send", "time": 1.0, "opcode": 1, "data": f} for f in frames],
    };
}

def _write_har(mock: MockServer, with_ws: bool) -> str {
    tid = "11111111-2222-3333-4444-555555555555";
    entries = [
        _entry(mock.url(), "/walker/create_task", {}, {"data": {"result": {"reports": [{"success": True, "task_id": tid}]}}}),
        _entry(mock.url(), "/walker/get_task", {"task_id": tid}, {"data": {"result": {"reports": [{"success": True}]}}}),
        _entry(mock.url(), "/walker/ok", {}, {"data": {"result": {"reports": [{"success": True}]}}}),
    ];
    if with_ws {
        entries.append(_ws_entry(mock.url(), "/ws", ['{"id": 1}', '{"id": 2}']));
    }
    path = os.path.join(tempfile.mkdtemp(prefix="jlt-har-"), "run.har");
    with open(path, "w") as f {
        json.dump({"log": {"version": "1.2", "creator": {"name": "t", "version": "1"}, "entries": entries}}, f);
    }
    return path;
}

def _run(mock: MockServer, vus: int, iterations: int, extra: dict[str, any], with_ws: bool = False) -> dict[str, any] {
    prefix = "u" + str(mock.count("/user/register")) + "_";
    cfg = LoadTestConfig.from_dict({
        "har_file": _write_har(mock, with_ws), "url": mock.url(),
        "vus": vus, "iterations": iterations, "workers": 1,
        "accounts": [{"username": prefix + str(i), "password": "x"} for i in range(vus)],
        **extra,
    });
    return run_in_subprocess(cfg);
}

def _rows(data: dict[str, any]) -> dict[str, dict[str, any]] {
    return {ep["endpoint"]: ep for ep in data["report"]["endpoints"]};
}

test "report counts equal what the server received" {
    mock = start_mock();
    data = _run(mock, 3, 2, {});
    rows = _rows(data);
    for path in ("/walker/create_task", "/walker/get_task", "/walker/ok") {
        assert mock.count(path) == 6;
        assert rows[path]["total_requests"] == 6;
        assert rows[path]["error_count"] == 0;
    }
    assert data["report"]["summary"]["total_requests"] == 18;
    stop_mock(mock);
}

test "correlation threads each user's own id into the next request" {
    mock = start_mock();
    data = _run(mock, 4, 2, {});
    assert mock.count("get_task_miss") == 0;
    assert _rows(data)["/walker/get_task"]["error_count"] == 0;
    stop_mock(mock);
}

test "unknown accounts are registered once, then logged in" {
    mock = start_mock();
    _run(mock, 3, 1, {});
    assert mock.count("/user/register") == 3;
    assert len(mock.users) == 3;
    stop_mock(mock);
}

test "a failure inside an HTTP 200 is reported with its type" {
    mock = start_mock();
    mock.set_fault("inside200", True);
    data = _run(mock, 2, 3, {});
    row = _rows(data)["/walker/ok"];
    assert row["total_requests"] == 6;
    assert row["error_count"] == 6;
    assert row["error_breakdown"] == {"APP_ERROR_IN_200": 6};
    stop_mock(mock);
}

test "identical deny pages across endpoints are infra blocks, not app errors" {
    mock = start_mock();
    mock.set_fault("waf", True);
    data = _run(mock, 2, 2, {"infra_block_threshold": 2});
    summary = data["report"]["summary"];
    assert summary["infra_block_count"] >= 4;
    rows = _rows(data);
    assert rows["/walker/create_task"]["infra_block_count"] == 4;
    assert rows["/walker/create_task"]["error_count"] == 0;
    stop_mock(mock);
}

test "websocket replay reports a connect row and one row per frame" {
    mock = start_mock();
    data = _run(mock, 3, 2, {}, True);
    rows = _rows(data);
    assert mock.count("ws_connect") == 6;
    assert mock.count("ws_frame") == 12;
    assert rows["WS /ws [connect]"]["total_requests"] == 6;
    assert rows["WS /ws"]["total_requests"] == 12;
    assert rows["WS /ws"]["error_count"] == 0;
    stop_mock(mock);
}

test "a breached threshold is returned with the report" {
    mock = start_mock();
    # Locust buckets response times to whole milliseconds, so a fast mock on a quick
    # machine reports p95 = 0. A negative limit is breached whatever the speed.
    data = _run(mock, 2, 1, {"fail_on_p95": -1.0});
    assert len(data["breaches"]) >= 1;
    assert data["breaches"][0].startswith("p95");
    stop_mock(mock);
}

test "two workers split the users and still match the server" {
    mock = start_mock();
    data = _run(mock, 4, 2, {"workers": 2});
    assert mock.count("/walker/create_task") == 8;
    assert _rows(data)["/walker/create_task"]["total_requests"] == 8;
    assert mock.count("/user/register") == 4;
    stop_mock(mock);
}
