"""Unit tests for output/json_report.jac, fed through a real Locust Environment.

Requests are injected with events.request.fire, so no network is involved and the
numbers come from the same stats objects a real run populates.
"""

import from locust.env { Environment }
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.output.json_report { build_report, error_type_of }


def _fire(env: Environment, method: str, name: str, ms: float, exc: str | None) -> None {
    env.events.request.fire(
        request_type=method, name=name, response_time=ms, response_length=10,
        exception=Exception(exc) if exc else None, context={},
    );
}

def _env() -> Environment {
    env = Environment();
    _fire(env, "POST", "auth: login", 5.0, None);
    _fire(env, "POST", "/a", 10.0, None);
    _fire(env, "POST", "/a", 20.0, "APP_ERROR_IN_200: reports[].success is false (nope)");
    _fire(env, "POST", "/b", 30.0, "HTTP 500 (expected 200): boom");
    return env;
}

test "error_type_of keeps the leading code" {
    assert error_type_of("APP_ERROR_IN_200: reports[] failed") == "APP_ERROR_IN_200";
    assert error_type_of("HTTP 404 (expected 200): gone") == "HTTP 404";
    assert error_type_of("CORRELATION_MISS: a, b") == "CORRELATION_MISS";
    assert error_type_of("Exception('TIMEOUT')") == "TIMEOUT";
    assert error_type_of("") == "ERROR";
}

test "summary excludes auth traffic and counts the rest" {
    got = build_report(_env(), LoadTestConfig.from_dict({}), 2.0, [], []);
    assert got["summary"]["total_requests"] == 3;
    assert got["summary"]["error_count"] == 2;
    assert got["summary"]["success_rate_pct"] == 33.3;
    assert got["summary"]["total_rps"] == 1.5;
}

test "auth rows are reported separately from endpoints" {
    got = build_report(_env(), LoadTestConfig.from_dict({}), 2.0, [], [("u1", "bad password")]);
    assert [ep["endpoint"] for ep in got["endpoints"]] == ["/a", "/b"];
    assert got["auth"]["requests"]["login"]["requests"] == 1;
    assert got["auth"]["failed_accounts"] == [{"account": "u1", "reason": "bad password"}];
}

test "error breakdown groups by error type per endpoint" {
    got = build_report(_env(), LoadTestConfig.from_dict({}), 2.0, [], []);
    by = {ep["endpoint"]: ep for ep in got["endpoints"]};
    assert by["/a"]["error_breakdown"] == {"APP_ERROR_IN_200": 1};
    assert by["/b"]["error_breakdown"] == {"HTTP 500": 1};
    assert by["/a"]["total_requests"] == 2;
}

test "report carries the keys the web app reads" {
    got = build_report(_env(), LoadTestConfig.from_dict({}), 2.0, [], []);
    for key in ("meta", "summary", "endpoints", "cumulative_timeseries") {
        assert key in got;
    }
    for key in ("p50_ms", "p95_ms", "p99_ms", "p999_ms", "success_rate_pct", "total_rps", "total_requests") {
        assert key in got["summary"];
    }
    for key in ("endpoint", "p50_ms", "p95_ms", "p99_ms", "p999_ms", "rps", "error_count", "success_rate_pct", "error_breakdown", "total_requests") {
        assert key in got["endpoints"][0];
    }
    assert got["meta"]["actual_duration_s"] == 2.0;
}
