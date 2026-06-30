"""Integration tests for output/reporter.jac — JSON schema, HTML structure, stdout/file routing."""

import json;
import tempfile;
import os;
import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.core.metrics { EndpointStats, StatsSnapshot }
import from jac_loadtest_cli.output.reporter { render_console, render_json, render_html }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(
    har_file: str = "test.har",
    url: str = "http://localhost:8000",
    mode: str = "monolith",
    vus: int = 10,
    workers: int = 1,
    ramp_up: str = "0s",
    timeout: str = "30s",
    report_format: str = "console",
    report_out: str | None = None,
    max_samples: int = 1_000_000,
) -> LoadTestConfig {
    return LoadTestConfig(
        har_file=har_file,
        url=url,
        mode=mode,
        vus=vus,
        workers=workers,
        ramp_up=ramp_up,
        timeout=timeout,
        report_format=report_format,
        report_out=report_out,
        max_samples=max_samples,
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
    assert set(doc.keys()) == {"meta", "latency_benchmarks", "endpoints", "summary", "timeseries"};
}

test "render json meta fields" {
    config = _make_config(vus=20, workers=2, ramp_up="10s");
    doc = json.loads(render_json([_make_stats()], config, actual_duration_s=62.1, total_rps=7.5));
    meta = doc["meta"];
    assert meta["har_file"] == "test.har";
    assert meta["mode"] == "monolith";
    assert meta["vus"] == 20;
    assert meta["workers"] == 2;
    assert meta["ramp_up"] == "10s";
    assert abs(meta["actual_duration_s"] - 62.1) < 0.01;
    assert abs(meta["total_rps"] - 7.5) < 0.01;
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
    assert "min_ms" in ep;
    assert "max_ms" in ep;
    assert "mean_ms" in ep;
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
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=[]));
    assert doc["timeseries"] == [];
}

test "render json timeseries populated" {
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=snaps));
    assert len(doc["timeseries"]) == 2;
    entry = doc["timeseries"][0];
    assert set(entry.keys()) == {"timestamp", "total_requests", "p50_ms", "p95_ms", "p99_ms", "rps", "error_rate_pct"};
    assert abs(entry["rps"] - 5.5) < 0.01;
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

test "render html embeds timeseries data" {
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)];
    html = render_html([_make_stats()], _make_config(), snapshots=snaps);
    assert "5.5" in html;
}

test "render html no data message when no snapshots" {
    html = render_html([_make_stats()], _make_config(), snapshots=[]);
    assert "No time-series data" in html;
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
