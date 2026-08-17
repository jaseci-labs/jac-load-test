"""Integration tests for output/reporter.jac — JSON schema, HTML structure, stdout/file routing."""

import json;
import tempfile;
import os;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.metrics { EndpointStats, StatsSnapshot, StepResult }
import from jac_loadtest_cli.output.reporter { render_console, render_json, render_html, parse_slo_map }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(
    har_file: str = "test.har",
    url: str = "http://localhost:8000",
    mode: str = "monolith",
    vus: int = 10,
    iterations: int = 1,
    workers: int = 1,
    ramp_up: str = "0s",
    timeout: str = "30s",
    report_format: str = "console",
    report_out: str | None = None,
    max_samples: int = 1_000_000,
    open_loop: bool = False,
) -> LoadTestConfig {
    return LoadTestConfig(
        har_file=har_file,
        url=url,
        mode=mode,
        vus=vus,
        iterations=iterations,
        workers=workers,
        ramp_up=ramp_up,
        timeout=timeout,
        report_format=report_format,
        report_out=report_out,
        max_samples=max_samples,
        open_loop=open_loop,
    );
}

def _make_stats(
    endpoint: str = "POST /walker/search",
    service: str = "monolith",
    total: int = 100,
    success: int = 98,
    p50: float = 45.0,
    p95: float = 120.0,
    p99: float = 250.0,
    ttfb_ms: float = 30.0,
    error_samples: dict[str, list[str]] | None = None,
    protocol: str = "http",
) -> EndpointStats {
    return EndpointStats(
        endpoint=endpoint,
        service=service,
        total_requests=total,
        success_count=success,
        error_count=total - success,
        success_rate_pct=round(success / total * 100, 1),
        min_ms=10.0,
        max_ms=500.0,
        mean_ms=p50,
        p50_ms=p50,
        p95_ms=p95,
        p99_ms=p99,
        latencies=[],
        error_breakdown={"500": total - success} if total > success else {},
        error_samples=error_samples if error_samples is not None else {},
        ttfb_ms=ttfb_ms,
        protocol=protocol,
    );
}

def _make_snapshot(t: float = 5.0) -> StatsSnapshot {
    return StatsSnapshot(
        timestamp=t,
        p50_ms=40.0,
        p95_ms=110.0,
        p99_ms=220.0,
        rps=5.5,
        error_rate_pct=1.0,
    );
}

def _make_steps() -> list[StepResult] {
    return [
        StepResult(step=1, vus=10, start_s=0.0, end_s=30.0, total_requests=300, error_rate_pct=0.0, p95_ms=80.0, p99_ms=120.0, breached=False),
        StepResult(step=2, vus=20, start_s=30.0, end_s=60.0, total_requests=600, error_rate_pct=45.0, p95_ms=900.0, p99_ms=1500.0, breached=True),
    ];
}


# ---------------------------------------------------------------------------
# render_json — schema
# ---------------------------------------------------------------------------

test "render json returns valid json" {
    stats = [_make_stats()];
    config = _make_config();
    result = render_json(stats, config, actual_duration_s=30.0, total_rps=3.3);
    doc = json.loads(result);
    assert isinstance(doc, dict);
}

test "render json top level keys" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0));
    assert set(doc.keys()) == {
        "meta", "latency_benchmarks", "endpoints", "summary",
        "cumulative_timeseries", "interval_timeseries", "step_load", "capacity_knee_vus",
    };
}

test "render json meta fields" {
    config = _make_config(vus=20, iterations=5, workers=2, ramp_up="10s");
    doc = json.loads(render_json([_make_stats()], config, actual_duration_s=62.1, total_rps=7.5));
    meta = doc["meta"];
    assert meta["har_file"] == "test.har";
    assert meta["mode"] == "monolith";
    assert meta["vus"] == 20;
    assert meta["iterations"] == 5;
    assert meta["workers"] == 2;
    assert meta["ramp_up"] == "10s";
    assert abs(meta["actual_duration_s"] - 62.1) < 0.01;
    assert abs(meta["total_rps"] - 7.5) < 0.01;
}


# ---------------------------------------------------------------------------
# B3 — samples_evicted / window_limited surfaced in report metadata
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# H1 — load_mode surfaced in report metadata
# ---------------------------------------------------------------------------

test "render json meta reports closed load mode by default" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0));
    assert doc["meta"]["load_mode"] == "closed";
}

test "render json meta reports open load mode when configured" {
    config = _make_config(open_loop=True);
    doc = json.loads(render_json([_make_stats()], config, actual_duration_s=30.0));
    assert doc["meta"]["load_mode"] == "open";
}


# ---------------------------------------------------------------------------
# H3 — step_load results and capacity knee surfaced in report metadata
# ---------------------------------------------------------------------------

test "render json step_load empty by default" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0));
    assert doc["step_load"] == [];
    assert doc["capacity_knee_vus"] is None;
}

test "render json step_load reports each step and the capacity knee" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0, step_results=_make_steps()));
    steps = doc["step_load"];
    assert len(steps) == 2;
    assert steps[0]["vus"] == 10;
    assert steps[0]["breached"] is False;
    assert steps[1]["vus"] == 20;
    assert steps[1]["breached"] is True;
    assert doc["capacity_knee_vus"] == 10;
}

test "render json capacity_knee_vus is null when every step breached" {
    all_breached = [StepResult(step=1, vus=5, start_s=0.0, end_s=10.0, total_requests=50, error_rate_pct=90.0, p95_ms=5000.0, p99_ms=6000.0, breached=True)];
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0, step_results=all_breached));
    assert doc["capacity_knee_vus"] is None;
}

test "render json meta reports no eviction by default" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0));
    assert doc["meta"]["samples_evicted"] == 0;
    assert doc["meta"]["window_limited"] is False;
}

test "render json meta surfaces eviction count when the buffer was full" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0, samples_evicted=4200));
    assert doc["meta"]["samples_evicted"] == 4200;
    assert doc["meta"]["window_limited"] is True;
}

test "render json endpoint fields" {
    stats = [_make_stats(total=200, success=196, p50=50.0, p95=130.0, p99=260.0)];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    ep = doc["endpoints"][0];
    assert ep["endpoint"] == "POST /walker/search";
    assert ep["service"] == "monolith";
    assert ep["total_requests"] == 200;
    assert ep["success_count"] == 196;
    assert ep["error_count"] == 4;
    assert abs(ep["success_rate_pct"] - 98.0) < 0.1;
    assert abs(ep["p50_ms"] - 50.0) < 0.01;
    assert abs(ep["p95_ms"] - 130.0) < 0.01;
    assert abs(ep["p99_ms"] - 260.0) < 0.01;
    assert "error_breakdown" in ep;
    assert "error_samples" in ep;
    assert "min_ms" in ep;
    assert "max_ms" in ep;
    assert "mean_ms" in ep;
    assert "ttfb_ms" in ep;
}

test "render json ttfb_ms per endpoint and summary" {
    stats = [
        _make_stats(endpoint="POST /a", total=100, success=100, ttfb_ms=20.0),
        _make_stats(endpoint="POST /b", total=100, success=100, ttfb_ms=40.0),
    ];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    assert abs(doc["endpoints"][0]["ttfb_ms"] - 20.0) < 0.01;
    assert abs(doc["endpoints"][1]["ttfb_ms"] - 40.0) < 0.01;
    assert abs(doc["summary"]["ttfb_ms"] - 30.0) < 0.01;
}

test "render json summary aggregates multiple endpoints" {
    stats = [
        _make_stats(endpoint="POST /a", total=100, success=100),
        _make_stats(endpoint="POST /b", total=50,  success=48),
    ];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    summary = doc["summary"];
    assert summary["total_requests"] == 150;
    assert summary["success_count"] == 148;
    assert summary["error_count"] == 2;
}

test "render json timeseries empty when no snapshots" {
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=[], interval_snapshots=[]));
    assert doc["cumulative_timeseries"] == [];
    assert doc["interval_timeseries"] == [];
}

test "render json timeseries populated" {
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=snaps));
    assert len(doc["cumulative_timeseries"]) == 2;
    entry = doc["cumulative_timeseries"][0];
    assert set(entry.keys()) == {"timestamp", "total_requests", "p50_ms", "p95_ms", "p99_ms", "rps", "error_rate_pct"};
    assert abs(entry["rps"] - 5.5) < 0.01;
}

test "render json interval timeseries populated with its own field shape" {
    interval_snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    doc = json.loads(render_json([_make_stats()], _make_config(), interval_snapshots=interval_snaps));
    assert len(doc["interval_timeseries"]) == 2;
    entry = doc["interval_timeseries"][0];
    assert set(entry.keys()) == {"timestamp", "requests", "p50_ms", "p95_ms", "p99_ms", "rps", "error_rate_pct"};
    assert abs(entry["rps"] - 5.5) < 0.01;
}

test "render json cumulative and interval timeseries are independent" {
    cumulative = [_make_snapshot(5.0)];
    interval = [_make_snapshot(5.0), _make_snapshot(10.0)];
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=cumulative, interval_snapshots=interval));
    assert len(doc["cumulative_timeseries"]) == 1;
    assert len(doc["interval_timeseries"]) == 2;
}

test "render json surfaces error trace samples" {
    stats = [_make_stats(total=100, success=98, error_samples={"500": ["abc123", "def456"]})];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    ep = doc["endpoints"][0];
    assert ep["error_samples"] == {"500": ["abc123", "def456"]};
}

test "render json empty stats" {
    doc = json.loads(render_json([], _make_config(), actual_duration_s=30.0, total_rps=0.0));
    assert doc["endpoints"] == [];
    assert doc["summary"]["total_requests"] == 0;
}

test "render json output is string" {
    result = render_json([_make_stats()], _make_config());
    assert isinstance(result, str);
    assert result.strip().startswith("{");
}

test "render json can be written to file" {
    result = render_json([_make_stats()], _make_config(), actual_duration_s=30.0);
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False);
    tmp.write(result);
    tmp.close();
    with open(tmp.name) as f {
        doc = json.load(f);
    }
    assert "endpoints" in doc;
}


# ---------------------------------------------------------------------------
# Phase 9 — protocol surfaced for mixed-protocol runs
# ---------------------------------------------------------------------------

test "render json endpoint defaults to http protocol" {
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0));
    assert doc["endpoints"][0]["protocol"] == "http";
}

test "render json endpoint reports non-http protocol" {
    stats = [_make_stats(endpoint="WS /chat", protocol="ws")];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    assert doc["endpoints"][0]["protocol"] == "ws";
}

test "render json mixed protocol endpoints each keep their own protocol field" {
    stats = [
        _make_stats(endpoint="POST /walker/search", protocol="http"),
        _make_stats(endpoint="GraphQL /subscribe", protocol="graphql"),
    ];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    by_endpoint = {ep["endpoint"]: ep["protocol"] for ep in doc["endpoints"]};
    assert by_endpoint["POST /walker/search"] == "http";
    assert by_endpoint["GraphQL /subscribe"] == "graphql";
}

test "render console omits protocol column for an http-only run" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(), actual_duration_s=30.0, total_rps=2.1);
    }
    assert "Proto" not in err.getvalue();
}

test "render console shows protocol column for a mixed-protocol run" {
    import io;
    import contextlib;
    stats = [
        _make_stats(endpoint="POST /walker/search", protocol="http"),
        _make_stats(endpoint="WS /chat", protocol="ws"),
    ];
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console(stats, _make_config(), actual_duration_s=30.0, total_rps=2.1);
    }
    output = err.getvalue();
    assert "Proto" in output;
    assert "WS" in output;
}

test "render html omits protocol column for an http-only run" {
    html = render_html([_make_stats()], _make_config());
    assert "<th>Protocol</th>" not in html;
}

test "render html shows protocol column and value for a mixed-protocol run" {
    stats = [
        _make_stats(endpoint="POST /walker/search", protocol="http"),
        _make_stats(endpoint="GraphQL /subscribe", protocol="graphql"),
    ];
    html = render_html(stats, _make_config());
    assert "<th>Protocol</th>" in html;
    assert "GRAPHQL" in html;
}


# ---------------------------------------------------------------------------
# render_html — structure
# ---------------------------------------------------------------------------

test "render html returns string" {
    result = render_html([_make_stats()], _make_config());
    assert isinstance(result, str);
}

test "render html is self contained html" {
    html = render_html([_make_stats()], _make_config());
    assert "<!DOCTYPE html>" in html;
    assert "<html" in html;
    assert "</html>" in html;
    assert "<body" in html;
    assert "</body>" in html;
}

test "render html contains chartjs" {
    html = render_html([_make_stats()], _make_config());
    assert "chart.js" in html.lower() or "Chart" in html;
}

test "render html embeds endpoint data" {
    stats = [_make_stats(endpoint="POST /walker/search")];
    html = render_html(stats, _make_config());
    assert "/walker/search" in html;
}

test "render html shows summary metrics" {
    stats = [_make_stats(total=200, success=198)];
    html = render_html(stats, _make_config(), actual_duration_s=60.0, total_rps=3.3);
    assert "200" in html;
    assert "99.0" in html;
}

test "render html shows ttfb summary card" {
    stats = [_make_stats(total=100, success=100, ttfb_ms=42.0)];
    html = render_html(stats, _make_config());
    assert "Avg TTFB" in html;
    assert "42" in html;
}

test "render html embeds timeseries data" {
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    html = render_html([_make_stats()], _make_config(), snapshots=snaps);
    assert "5.5" in html;
}

test "render html embeds interval timeseries data" {
    interval_snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    html = render_html([_make_stats()], _make_config(), interval_snapshots=interval_snaps);
    assert "TS_INTERVAL_RPS" in html;
    assert "RPS (interval)" in html;
}

test "render html shows trace id next to error breakdown entry" {
    stats = [_make_stats(total=100, success=98, error_samples={"500": ["abc123"]})];
    html = render_html(stats, _make_config());
    assert "err-trace" in html;
    assert "abc123" in html;
}

test "render html omits trace hint when no trace ids recorded" {
    stats = [_make_stats(total=100, success=98)];
    html = render_html(stats, _make_config());
    assert "<span class='err-trace'>" not in html;
}

test "render html shows closed-loop mode by default" {
    html = render_html([_make_stats()], _make_config());
    assert "Load mode: closed-loop" in html;
}

test "render html shows open-loop mode when configured" {
    html = render_html([_make_stats()], _make_config(open_loop=True));
    assert "Load mode: open-loop" in html;
}

test "render html omits step load section by default" {
    html = render_html([_make_stats()], _make_config());
    assert "Step Load" not in html;
}

test "render html shows step load table and capacity knee when steps recorded" {
    html = render_html([_make_stats()], _make_config(), step_results=_make_steps());
    assert "Step Load" in html;
    assert "BREACHED" in html;
    assert "Capacity knee: last passing step was 10 VUs (step 1)." in html;
}

test "render html omits window warning by default" {
    html = render_html([_make_stats()], _make_config());
    assert "<div class='window-warning'>" not in html;
}

test "render html shows window warning banner when samples were evicted" {
    html = render_html([_make_stats()], _make_config(), samples_evicted=250);
    assert "window-warning" in html;
    assert "250" in html;
}

test "render html no data message when no snapshots" {
    html = render_html([_make_stats()], _make_config(), snapshots=[]);
    assert "No time-series data" in html;
}

test "render html shows iterations in meta" {
    config = _make_config(iterations=7);
    html = render_html([_make_stats()], config);
    assert "Iterations: 7" in html;
}

test "render html microservice mode shows service column" {
    stats = [_make_stats(service="order_service")];
    config = _make_config(mode="microservice");
    html = render_html(stats, config);
    assert "Service" in html;
    assert "order_service" in html;
}

test "render html can be written to file" {
    html = render_html([_make_stats()], _make_config(), actual_duration_s=30.0);
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".html", delete=False);
    tmp.write(html);
    tmp.close();
    with open(tmp.name) as f {
        content = f.read();
    }
    assert "<!DOCTYPE html>" in content;
}


# ---------------------------------------------------------------------------
# render_console — does not raise and produces no stdout
# ---------------------------------------------------------------------------

test "render console empty stats does not crash" {
    render_console([], _make_config(), actual_duration_s=30.0, total_rps=0.0);
}

test "render console microservice mode" {
    stats = [_make_stats(service="inventory_service")];
    config = _make_config(mode="microservice");
    render_console(stats, config, actual_duration_s=30.0, total_rps=2.1);
}

test "render console shows iterations in summary line" {
    import io;
    import contextlib;
    config = _make_config(iterations=9);
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], config, actual_duration_s=30.0, total_rps=2.1);
    }
    assert "Iterations: 9" in err.getvalue();
}

test "render console shows trace ids in error breakdown" {
    import io;
    import contextlib;
    stats = [_make_stats(total=100, success=98, error_samples={"500": ["abc123", "def456"]})];
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console(stats, _make_config(), actual_duration_s=30.0, total_rps=2.1);
    }
    output = err.getvalue();
    assert "trace: abc123, def456" in output;
}

test "render console shows load mode in summary line" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(open_loop=True), actual_duration_s=30.0, total_rps=2.1);
    }
    assert "Load mode: open-loop" in err.getvalue();
}

test "render console omits step load table by default" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(), actual_duration_s=30.0, total_rps=2.1);
    }
    assert "Step Load" not in err.getvalue();
}

test "render console shows step load table and capacity knee when steps recorded" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(), actual_duration_s=30.0, total_rps=2.1, step_results=_make_steps());
    }
    output = err.getvalue();
    assert "Step Load" in output;
    assert "Capacity knee" in output;
    assert "10 VUs" in output;
}

test "render console shows no eviction warning by default" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(), actual_duration_s=30.0, total_rps=2.1);
    }
    assert "evicted" not in err.getvalue();
}

test "render console shows eviction warning when samples were evicted" {
    import io;
    import contextlib;
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console([_make_stats()], _make_config(), actual_duration_s=30.0, total_rps=2.1, samples_evicted=99);
    }
    output = err.getvalue();
    assert "99" in output;
    assert "evicted" in output;
}


# ---------------------------------------------------------------------------
# render_json / render_html — importable without CLI context
# ---------------------------------------------------------------------------

test "render json and render html produce no console output" {
    import io;
    import contextlib;
    stats = [_make_stats()];
    config = _make_config();
    out = io.StringIO();
    err = io.StringIO();
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err) {
        render_json(stats, config, actual_duration_s=30.0);
        render_html(stats, config);
    }
    assert out.getvalue() == "";
    assert err.getvalue() == "";
}

test "render json and render html do not read or mutate sys.argv" {
    import sys;
    original_argv = list(sys.argv);
    sys.argv = ["gunicorn", "myapp:app"];
    try {
        render_json([_make_stats()], _make_config(), actual_duration_s=30.0);
        render_html([_make_stats()], _make_config());
        assert sys.argv == ["gunicorn", "myapp:app"];
    } finally {
        sys.argv = original_argv;
    }
}


# ---------------------------------------------------------------------------
# H9 — per-endpoint SLO overrides (parse_slo_map validation)
# ---------------------------------------------------------------------------

test "parse_slo_map returns empty dict for none or empty string" {
    assert parse_slo_map(None) == {};
    assert parse_slo_map("") == {};
}

test "parse_slo_map parses a valid override" {
    result = parse_slo_map('{"/walker/chat": {"p95": {"good": 2000, "bad": 8000}}}');
    assert result == {"/walker/chat": {"p95": {"good": 2000, "bad": 8000}}};
}

test "parse_slo_map rejects invalid json" {
    raised = False;
    try {
        parse_slo_map("not json");
    } except ValueError as exc {
        raised = True;
        assert "JSON" in str(exc);
    }
    assert raised;
}

test "parse_slo_map rejects non-object top level" {
    raised = False;
    try {
        parse_slo_map("[1, 2, 3]");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_slo_map rejects non-object endpoint value" {
    raised = False;
    try {
        parse_slo_map('{"/api": 42}');
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_slo_map rejects unknown metric name" {
    raised = False;
    try {
        parse_slo_map('{"/api": {"p97": {"good": 1, "bad": 2}}}');
    } except ValueError as exc {
        raised = True;
        assert "p97" in str(exc);
    }
    assert raised;
}

test "parse_slo_map rejects a bound missing good or bad" {
    raised = False;
    try {
        parse_slo_map('{"/api": {"p95": {"good": 100}}}');
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_slo_map rejects non-numeric bounds" {
    raised = False;
    try {
        parse_slo_map('{"/api": {"p95": {"good": "fast", "bad": "slow"}}}');
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "parse_slo_map rejects good greater than or equal to bad" {
    raised = False;
    try {
        parse_slo_map('{"/api": {"p95": {"good": 500, "bad": 500}}}');
    } except ValueError {
        raised = True;
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# H9 — per-endpoint SLO overrides change ratings in the actual reports
# ---------------------------------------------------------------------------

test "render json rates an endpoint bad against the global default with no override" {
    stats = [_make_stats(endpoint="/walker/slow", p95=3000.0)];
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0));
    ep = doc["endpoints"][0];
    assert ep["p95_rating"] == "bad";
    assert ep["thresholds"]["p95"] == {"good_ms": 500, "bad_ms": 2000};
}

test "render json applies a per-endpoint slo override to rating and thresholds" {
    stats = [_make_stats(endpoint="/walker/slow", p95=3000.0)];
    overrides = {"/walker/slow": {"p95": {"good": 5000, "bad": 10000}}};
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0, slo_overrides=overrides));
    ep = doc["endpoints"][0];
    assert ep["p95_rating"] == "good";
    assert ep["thresholds"]["p95"] == {"good_ms": 5000, "bad_ms": 10000};
}

test "render json slo override on one endpoint does not affect a different endpoint" {
    stats = [
        _make_stats(endpoint="/walker/slow", p95=3000.0),
        _make_stats(endpoint="/walker/other", p95=3000.0),
    ];
    overrides = {"/walker/slow": {"p95": {"good": 5000, "bad": 10000}}};
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0, slo_overrides=overrides));
    by_endpoint = {ep["endpoint"]: ep for ep in doc["endpoints"]};
    assert by_endpoint["/walker/slow"]["p95_rating"] == "good";
    assert by_endpoint["/walker/other"]["p95_rating"] == "bad";
    assert by_endpoint["/walker/other"]["thresholds"]["p95"] == {"good_ms": 500, "bad_ms": 2000};
}

test "render html shows bad rating badge for endpoint with no override" {
    stats = [_make_stats(endpoint="/walker/slow", p95=3000.0)];
    html = render_html(stats, _make_config());
    # Match the specific p95 cell's badge text, not just "lat-bad"/"Bad" —
    # those also appear in the always-present legend header and (unrelated
    # to this endpoint's p95 rating) the apdex column's own rating class.
    assert "3000 <span class='lat-badge-sm'>Bad</span>" in html;
}

test "render html shows good rating badge once slo override applied" {
    stats = [_make_stats(endpoint="/walker/slow", p95=3000.0)];
    overrides = {"/walker/slow": {"p95": {"good": 5000, "bad": 10000}}};
    html = render_html(stats, _make_config(), slo_overrides=overrides);
    assert "3000 <span class='lat-badge-sm'>Good</span>" in html;
    assert "3000 <span class='lat-badge-sm'>Bad</span>" not in html;
}

test "render console accepts slo_overrides without crashing" {
    import io;
    import contextlib;
    stats = [_make_stats(endpoint="/walker/slow", p95=3000.0)];
    overrides = {"/walker/slow": {"p95": {"good": 5000, "bad": 10000}}};
    err = io.StringIO();
    with contextlib.redirect_stderr(err) {
        render_console(stats, _make_config(), actual_duration_s=30.0, total_rps=2.1, slo_overrides=overrides);
    }
    # Table cell values can be truncated by Rich's column auto-width, so this
    # only checks the call succeeds and produces output — not exact cell text.
    assert "/walker/slow" in err.getvalue();
}
