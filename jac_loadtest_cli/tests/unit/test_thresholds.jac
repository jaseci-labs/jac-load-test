"""Unit tests for output/thresholds.jac — pass/fail over a finished JSON report."""

import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.output.thresholds { evaluate }


def _result(total: int, errors: int, p95: float, p99: float) -> dict[str, any] {
    return {
        "summary": {"total_requests": total, "error_count": errors, "p95_ms": p95, "p99_ms": p99},
        "endpoints": [
            {"endpoint": "/a", "p95_ms": 900.0, "p99_ms": 950.0},
            {"endpoint": "/b", "p95_ms": 50.0, "p99_ms": 60.0},
        ],
    };
}

def _cfg(kw: dict[str, any] = {}) -> LoadTestConfig {
    return LoadTestConfig.from_dict(kw);
}

test "no thresholds configured never breaches" {
    assert evaluate(_cfg(), _result(100, 100, 9999.0, 9999.0)) == [];
}

test "error rate over the limit breaches" {
    got = evaluate(_cfg({"fail_on_error_rate": 5.0}), _result(100, 10, 1.0, 1.0));
    assert len(got) == 1;
    assert "error_rate 10.0%" in got[0];
}

test "error rate at or under the limit passes" {
    assert evaluate(_cfg({"fail_on_error_rate": 10.0}), _result(100, 10, 1.0, 1.0)) == [];
}

test "p95 and p99 are checked independently" {
    got = evaluate(_cfg({"fail_on_p95": 100.0, "fail_on_p99": 100.0}), _result(10, 0, 150.0, 90.0));
    assert len(got) == 1;
    assert got[0].startswith("p95");
}

test "scoped threshold applies to its own endpoint only" {
    got = evaluate(_cfg({"fail_on_p95_scoped": {"/a": 500.0, "/b": 500.0}}), _result(10, 0, 1.0, 1.0));
    assert len(got) == 1;
    assert got[0].startswith("/a");
}

test "an empty run cannot breach" {
    assert evaluate(_cfg({"fail_on_p95": 1.0}), _result(0, 0, 0.0, 0.0)) == [];
}
