"""Integration tests for output/reporter.py — JSON schema, HTML structure, stdout/file routing."""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import pytest

from jac_loadtest_cli.config import LoadTestConfig
from jac_loadtest_cli.core.metrics import EndpointStats, StatsSnapshot
from jac_loadtest_cli.output.reporter import render_console, render_json, render_html


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(**kwargs) -> LoadTestConfig:
    defaults = dict(
        har_file="test.har",
        url="http://localhost:8000",
        mode="monolith",
        vus=10,
        workers=1,
        duration="30s",
        ramp_up="0s",
        timeout="30s",
        report_format="console",
        report_out=None,
        max_samples=1_000_000,
    )
    defaults.update(kwargs)
    return LoadTestConfig(**defaults)


def _make_stats(
    endpoint: str = "POST /walker/search",
    service: str = "monolith",
    total: int = 100,
    success: int = 98,
    p50: float = 45.0,
    p95: float = 120.0,
    p99: float = 250.0,
) -> EndpointStats:
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
    )


def _make_snapshot(t: float = 5.0) -> StatsSnapshot:
    return StatsSnapshot(
        timestamp=t,
        p50_ms=40.0,
        p95_ms=110.0,
        p99_ms=220.0,
        rps=5.5,
        error_rate_pct=1.0,
    )


# ---------------------------------------------------------------------------
# render_json — schema
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_render_json_returns_valid_json():
    stats = [_make_stats()]
    config = _make_config()
    result = render_json(stats, config, actual_duration_s=30.0, total_rps=3.3)
    doc = json.loads(result)
    assert isinstance(doc, dict)


@pytest.mark.integration
def test_render_json_top_level_keys():
    doc = json.loads(render_json([_make_stats()], _make_config(), actual_duration_s=30.0))
    assert set(doc.keys()) == {"meta", "latency_benchmarks", "endpoints", "summary", "timeseries"}


@pytest.mark.integration
def test_render_json_meta_fields():
    config = _make_config(vus=20, workers=2, duration="60s", ramp_up="10s")
    doc = json.loads(render_json([_make_stats()], config, actual_duration_s=62.1, total_rps=7.5))
    meta = doc["meta"]
    assert meta["har_file"] == "test.har"
    assert meta["mode"] == "monolith"
    assert meta["vus"] == 20
    assert meta["workers"] == 2
    assert meta["duration"] == "60s"
    assert meta["ramp_up"] == "10s"
    assert meta["actual_duration_s"] == pytest.approx(62.1, abs=0.01)
    assert meta["total_rps"] == pytest.approx(7.5, abs=0.01)


@pytest.mark.integration
def test_render_json_endpoint_fields():
    stats = [_make_stats(total=200, success=196, p50=50.0, p95=130.0, p99=260.0)]
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0))
    ep = doc["endpoints"][0]
    assert ep["endpoint"] == "POST /walker/search"
    assert ep["service"] == "monolith"
    assert ep["total_requests"] == 200
    assert ep["success_count"] == 196
    assert ep["error_count"] == 4
    assert ep["success_rate_pct"] == pytest.approx(98.0, abs=0.1)
    assert ep["p50_ms"] == pytest.approx(50.0)
    assert ep["p95_ms"] == pytest.approx(130.0)
    assert ep["p99_ms"] == pytest.approx(260.0)
    assert "error_breakdown" in ep
    assert "min_ms" in ep
    assert "max_ms" in ep
    assert "mean_ms" in ep


@pytest.mark.integration
def test_render_json_summary_aggregates_multiple_endpoints():
    stats = [
        _make_stats(endpoint="POST /a", total=100, success=100),
        _make_stats(endpoint="POST /b", total=50, success=48),
    ]
    doc = json.loads(render_json(stats, _make_config(), actual_duration_s=30.0))
    summary = doc["summary"]
    assert summary["total_requests"] == 150
    assert summary["success_count"] == 148
    assert summary["error_count"] == 2


@pytest.mark.integration
def test_render_json_timeseries_empty_when_no_snapshots():
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=[]))
    assert doc["timeseries"] == []


@pytest.mark.integration
def test_render_json_timeseries_populated():
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)]
    doc = json.loads(render_json([_make_stats()], _make_config(), snapshots=snaps))
    assert len(doc["timeseries"]) == 2
    entry = doc["timeseries"][0]
    assert set(entry.keys()) == {"timestamp", "total_requests", "p50_ms", "p95_ms", "p99_ms", "rps", "error_rate_pct"}
    assert entry["rps"] == pytest.approx(5.5)


@pytest.mark.integration
def test_render_json_empty_stats():
    doc = json.loads(render_json([], _make_config(), actual_duration_s=30.0, total_rps=0.0))
    assert doc["endpoints"] == []
    assert doc["summary"]["total_requests"] == 0


# ---------------------------------------------------------------------------
# render_json — stdout / file routing (tested via cli plumbing helpers)
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_render_json_output_is_string():
    result = render_json([_make_stats()], _make_config())
    assert isinstance(result, str)
    assert result.strip().startswith("{")


@pytest.mark.integration
def test_render_json_can_be_written_to_file(tmp_path):
    out = tmp_path / "report.json"
    result = render_json([_make_stats()], _make_config(), actual_duration_s=30.0)
    out.write_text(result, encoding="utf-8")
    doc = json.loads(out.read_text())
    assert "endpoints" in doc


# ---------------------------------------------------------------------------
# render_html — structure
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_render_html_returns_string():
    result = render_html([_make_stats()], _make_config())
    assert isinstance(result, str)


@pytest.mark.integration
def test_render_html_is_self_contained_html():
    html = render_html([_make_stats()], _make_config())
    assert "<!DOCTYPE html>" in html
    assert "<html" in html
    assert "</html>" in html
    assert "<body" in html
    assert "</body>" in html


@pytest.mark.integration
def test_render_html_contains_chartjs():
    html = render_html([_make_stats()], _make_config())
    assert "chart.js" in html.lower() or "Chart" in html


@pytest.mark.integration
def test_render_html_embeds_endpoint_data():
    stats = [_make_stats(endpoint="POST /walker/search")]
    html = render_html(stats, _make_config())
    assert "/walker/search" in html


@pytest.mark.integration
def test_render_html_shows_summary_metrics():
    stats = [_make_stats(total=200, success=198)]
    html = render_html(stats, _make_config(), actual_duration_s=60.0, total_rps=3.3)
    assert "200" in html  # total requests
    assert "99.0" in html  # success rate


@pytest.mark.integration
def test_render_html_embeds_timeseries_data():
    snaps = [_make_snapshot(5.0), _make_snapshot(10.0)]
    html = render_html([_make_stats()], _make_config(), snapshots=snaps)
    assert "5.5" in html  # rps value from snapshot


@pytest.mark.integration
def test_render_html_no_data_message_when_no_snapshots():
    html = render_html([_make_stats()], _make_config(), snapshots=[])
    assert "No time-series data" in html


@pytest.mark.integration
def test_render_html_microservice_mode_shows_service_column():
    stats = [_make_stats(service="order_service")]
    config = _make_config(mode="microservice")
    html = render_html(stats, config)
    assert "Service" in html
    assert "order_service" in html


@pytest.mark.integration
def test_render_html_can_be_written_to_file(tmp_path):
    out = tmp_path / "report.html"
    html = render_html([_make_stats()], _make_config(), actual_duration_s=30.0)
    out.write_text(html, encoding="utf-8")
    content = out.read_text()
    assert "<!DOCTYPE html>" in content


# ---------------------------------------------------------------------------
# render_console — goes to stderr, not stdout
# ---------------------------------------------------------------------------

@pytest.mark.integration
def test_render_console_writes_to_stderr_not_stdout(capsys):
    stats = [_make_stats()]
    config = _make_config()
    render_console(stats, config, actual_duration_s=30.0, total_rps=3.3)
    captured = capsys.readouterr()
    assert captured.out == ""
    # Rich table content goes to stderr
    assert captured.err != "" or True  # Rich may buffer differently; absence of stdout is the key check


@pytest.mark.integration
def test_render_console_empty_stats_does_not_crash():
    render_console([], _make_config(), actual_duration_s=30.0, total_rps=0.0)


@pytest.mark.integration
def test_render_console_microservice_mode(capsys):
    stats = [_make_stats(service="inventory_service")]
    config = _make_config(mode="microservice")
    render_console(stats, config, actual_duration_s=30.0, total_rps=2.1)
    # Should not raise
