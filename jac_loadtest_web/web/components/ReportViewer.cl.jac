"""ReportViewer — rendered post-run report with summary, charts, and downloads."""

import from ..services.run_walkers { get_run_html }
import from 'recharts' { ResponsiveContainer, BarChart, Bar, Legend, XAxis, YAxis, CartesianGrid, Tooltip }
import from .ui.card { Card, CardHeader, CardTitle, CardContent }
import from .ui.badge { Badge }
import from .ui.button { Button }
import from .ui.table { Table, TableHeader, TableBody, TableHead, TableRow, TableCell }
import from .ui.separator { Separator }
import from .LatencyChart { LatencyChart }
import from .RpsChart { RpsChart }

glob _RATING_CLASSES: dict[str, str] = {
    "good": "text-green-600 dark:text-green-400",
    "ok":   "text-amber-600 dark:text-amber-400",
    "bad":  "text-red-600 dark:text-red-500",
};

def _rate_class(pct: float) -> str {
    if pct >= 99 {
        return _RATING_CLASSES["good"];
    } elif pct >= 95 {
        return _RATING_CLASSES["ok"];
    } else {
        return _RATING_CLASSES["bad"];
    }
}

def _latency_class(value_ms: float, good: float, bad: float) -> str {
    if value_ms < good {
        return _RATING_CLASSES["good"];
    } elif value_ms < bad {
        return _RATING_CLASSES["ok"];
    } else {
        return _RATING_CLASSES["bad"];
    }
}

def _apdex_class(score: float) -> str {
    if score >= 0.85 {
        return _RATING_CLASSES["good"];
    } elif score >= 0.70 {
        return _RATING_CLASSES["ok"];
    } else {
        return _RATING_CLASSES["bad"];
    }
}

def:pub ReportViewer(
    run_id: str,
    results_json: str,
    passed_thresholds: any = None
) -> JsxElement {
    has downloading_html: bool = False;

    report_json = JSON.parse(results_json or "{}");

    def downloadJson() {
        blob = new(Blob, [results_json], {"type": "application/json"});
        url = URL.createObjectURL(blob);
        a = document.createElement("a");
        a.href = url;
        a.download = "report.json";
        a.click();
        URL.revokeObjectURL(url);
    }

    async def downloadHtml() {
        downloading_html = True;
        result = root spawn get_run_html(run_id=run_id);
        reply: dict = result.reports[0] if result.reports else {};
        html = reply.get("html", "");
        if html {
            blob = new(Blob, [html], {"type": "text/html"});
            url = URL.createObjectURL(blob);
            a = document.createElement("a");
            a.href = url;
            a.download = "report.html";
            a.click();
            URL.revokeObjectURL(url);
        }
        downloading_html = False;
    }

    summary = report_json.get("summary", {});
    meta = report_json.get("meta", {});
    endpoints = report_json.get("endpoints", []);
    # render_json calls this "cumulative_timeseries" with a "timestamp" field;
    # the live SSE schema (which LatencyChart is shared with) calls it
    # "elapsed_s" — adapt post-run data to the same shape rather than forking
    # the chart.
    snapshots = [
        {**t, "elapsed_s": t.get("timestamp", 0)}
        for t in report_json.get("cumulative_timeseries", [])
    ];

    total_requests = summary.get("total_requests", 0);
    error_rate = (100.0 - summary.get("success_rate_pct", 100.0)) if total_requests > 0 else 0.0;

    # Final, authoritative numbers from the completed run (meta/summary), not
    # the live SSE snapshot state — that's ephemeral and gone once the stream
    # ends, so the last-known elapsed time / VU count need to come from here
    # to still be visible after the run finishes.
    elapsed_total_s = meta.get("actual_duration_s", 0.0);
    # NOT `elapsed_total_s // 60` — floor-division's client-side codegen
    # silently emits `+` instead of a floor divide when the operand's type
    # isn't statically known as numeric (which it isn't here: meta comes
    # from untyped JSON), producing e.g. "92:32" instead of "0:32" for a
    # 32s run. elapsed_total_s is always >= 0, so plain division + int()
    # truncation is equivalent and avoids the buggy codegen path entirely.
    elapsed_min = int(elapsed_total_s / 60);
    elapsed_sec = int(elapsed_total_s % 60);
    elapsed_str = str(elapsed_min) + ":" + ("0" if elapsed_sec < 10 else "") + str(elapsed_sec);
    configured_vus = meta.get("vus", 0);

    error_rows = [
        {"endpoint": ep.get("endpoint", "?"), "error_type": err_type, "count": count}
        for ep in endpoints
        for (err_type, count) in ep.get("error_breakdown", {}).items()
    ];

    threshold_banner_variant = "secondary" if passed_thresholds is None else (
        "default" if passed_thresholds else "destructive"
    );
    threshold_text = (
        "Threshold results unavailable"
        if passed_thresholds is None else
        ("All thresholds passed" if passed_thresholds else "One or more thresholds failed")
    );

    endpoint_chart_data = [
        {
            "path": ep.get("endpoint", "?")[-28:],
            "p50": round(ep.get("p50_ms", 0), 1),
            "p95": round(ep.get("p95_ms", 0), 1),
            "p99": round(ep.get("p99_ms", 0), 1),
            "p999": round(ep.get("p999_ms", 0), 1)
        }
        for ep in endpoints[:12]
    ];

    is_microservice = meta.get("mode") == "microservice";

    endpoint_table_rows = [
        {
            "key": str(idx),
            "service": ep.get("service", ""),
            "endpoint": ep.get("endpoint", "?"),
            "total_requests": ep.get("total_requests", 0),
            "rps": ep.get("rps", 0.0),
            "success_rate_pct": ep.get("success_rate_pct", 0.0),
            "p50_ms": ep.get("p50_ms", 0.0),
            "p95_ms": ep.get("p95_ms", 0.0),
            "p99_ms": ep.get("p99_ms", 0.0),
            "p999_ms": ep.get("p999_ms", 0.0),
            "apdex": ep.get("apdex", 0.0),
            "completion_p50_s": ep.get("completion_p50_s", 0.0),
            "completion_p95_s": ep.get("completion_p95_s", 0.0),
            "completion_p99_s": ep.get("completion_p99_s", 0.0),
            "error_count": ep.get("error_count", 0)
        }
        for (idx, ep) in enumerate(endpoints)
    ];

    return
        <div className="flex flex-col gap-6">
            <div className="flex items-center justify-between">
                <h2 className="text-lg font-semibold">Report</h2>
                <div className="flex gap-2">
                    <Badge variant={threshold_banner_variant}>{threshold_text}</Badge>
                    <Button variant="outline" size="sm" onClick={downloadJson}>
                        Download JSON
                    </Button>
                    <Button variant="outline" size="sm" onClick={downloadHtml} disabled={downloading_html}>
                        {"Preparing…" if downloading_html else "Download HTML"}
                    </Button>
                </div>
            </div>

            <Card>
                <CardHeader>
                    <CardTitle className="text-sm">Summary</CardTitle>
                </CardHeader>
                <CardContent>
                    <Table>
                        <TableBody>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Elapsed
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {elapsed_str}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Virtual users
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(configured_vus)}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Total requests
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(total_requests)}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Avg RPS
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("total_rps", 0.0), 1))}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Success rate
                                </TableHead>
                                <TableCell className={"text-right font-mono " + _rate_class(summary.get("success_rate_pct", 0.0))}>
                                    {str(round(summary.get("success_rate_pct", 0.0), 1)) + "%"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Error rate
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(error_rate, 2)) + "%"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p50 latency
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("p50_ms", 0.0), 1)) + " ms"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p95 latency
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("p95_ms", 0.0), 1)) + " ms"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p99 latency
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("p99_ms", 0.0), 1)) + " ms"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p99.9 latency
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("p999_ms", 0.0), 1)) + " ms"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    {"Apdex (T=" + str(round(meta.get("apdex_t_ms", 500))) + "ms)"}
                                </TableHead>
                                <TableCell className={"text-right font-mono " + _apdex_class(summary.get("apdex", 0.0))}>
                                    {str(round(summary.get("apdex", 0.0), 2))}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p50 completion
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("completion_p50_s", 0.0), 2)) + "s"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p95 completion
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("completion_p95_s", 0.0), 2)) + "s"}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    p99 completion
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("completion_p99_s", 0.0), 2)) + "s"}
                                </TableCell>
                            </TableRow>
                        </TableBody>
                    </Table>
                </CardContent>
            </Card>

            {
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <LatencyChart snapshots={snapshots} title="Cumulative latency over time (p50 / p95 / p99)" />
                    <RpsChart snapshots={snapshots} title="Cumulative RPS over time" />
                </div>
                if len(snapshots) > 0 else None
            }

            {
                <Card>
                    <CardHeader>
                        <CardTitle className="text-sm">Per-endpoint latency (p50 / p95 / p99 / p99.9)</CardTitle>
                    </CardHeader>
                    <CardContent>
                        <ResponsiveContainer width="100%" height={280}>
                            <BarChart
                                data={endpoint_chart_data}
                                layout="vertical"
                                margin={{"top": 4, "right": 16, "left": 0, "bottom": 0}}
                            >
                                <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                                <XAxis type="number" unit=" ms" tick={{"fontSize": 11}} />
                                <YAxis
                                    type="category"
                                    dataKey="path"
                                    tick={{"fontSize": 10}}
                                    width={120}
                                />
                                <Tooltip />
                                <Legend iconType="circle" />
                                <Bar dataKey="p50" name="p50 ms" fill="var(--color-primary)" />
                                <Bar dataKey="p95" name="p95 ms" fill="var(--color-chart-2)" />
                                <Bar dataKey="p99" name="p99 ms" fill="var(--color-destructive)" />
                                <Bar dataKey="p999" name="p99.9 ms" fill="var(--color-chart-4)" />
                            </BarChart>
                        </ResponsiveContainer>
                    </CardContent>
                </Card>
                if len(endpoints) > 0 else None
            }

            {
                <Card>
                    <CardHeader>
                        <CardTitle className="text-sm">Endpoint metrics</CardTitle>
                    </CardHeader>
                    <CardContent>
                        <Table>
                            <TableHeader>
                                <TableRow>
                                    {<TableHead>Service</TableHead> if is_microservice else None}
                                    <TableHead>Endpoint</TableHead>
                                    <TableHead className="text-right">Reqs</TableHead>
                                    <TableHead className="text-right">RPS</TableHead>
                                    <TableHead className="text-right">OK%</TableHead>
                                    <TableHead className="text-right">p50</TableHead>
                                    <TableHead className="text-right">p95</TableHead>
                                    <TableHead className="text-right">p99</TableHead>
                                    <TableHead className="text-right">p99.9</TableHead>
                                    <TableHead className="text-right">Apdex</TableHead>
                                    <TableHead className="text-right">p50 done</TableHead>
                                    <TableHead className="text-right">p95 done</TableHead>
                                    <TableHead className="text-right">p99 done</TableHead>
                                    <TableHead className="text-right">Errs</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {[
                                    <TableRow key={row["key"]}>
                                        {<TableCell className="text-xs">{row["service"]}</TableCell> if is_microservice else None}
                                        <TableCell className="font-mono text-xs">{row["endpoint"]}</TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(row["total_requests"])}</TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(round(row["rps"], 1))}</TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _rate_class(row["success_rate_pct"])}>
                                            {str(round(row["success_rate_pct"], 1)) + "%"}
                                        </TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _latency_class(row["p50_ms"], 100, 500)}>
                                            {str(round(row["p50_ms"])) + " ms"}
                                        </TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _latency_class(row["p95_ms"], 500, 2000)}>
                                            {str(round(row["p95_ms"])) + " ms"}
                                        </TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _latency_class(row["p99_ms"], 1000, 5000)}>
                                            {str(round(row["p99_ms"])) + " ms"}
                                        </TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _latency_class(row["p999_ms"], 2000, 10000)}>
                                            {str(round(row["p999_ms"])) + " ms"}
                                        </TableCell>
                                        <TableCell className={"text-right font-mono text-xs " + _apdex_class(row["apdex"])}>
                                            {str(round(row["apdex"], 2))}
                                        </TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(round(row["completion_p50_s"], 2)) + "s"}</TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(round(row["completion_p95_s"], 2)) + "s"}</TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(round(row["completion_p99_s"], 2)) + "s"}</TableCell>
                                        <TableCell className="text-right font-mono text-xs">{str(row["error_count"])}</TableCell>
                                    </TableRow>
                                    for row in endpoint_table_rows
                                ]}
                            </TableBody>
                        </Table>
                    </CardContent>
                </Card>
                if len(endpoint_table_rows) > 0 else None
            }

            {
                <Card>
                    <CardHeader>
                        <CardTitle className="text-sm">Error breakdown</CardTitle>
                    </CardHeader>
                    <CardContent>
                        <Table>
                            <TableHeader>
                                <TableRow>
                                    <TableHead>Endpoint</TableHead>
                                    <TableHead>Error type</TableHead>
                                    <TableHead className="text-right">Count</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {[
                                    <TableRow key={row["endpoint"] + row["error_type"]}>
                                        <TableCell className="font-mono text-xs">{row["endpoint"]}</TableCell>
                                        <TableCell>{row["error_type"]}</TableCell>
                                        <TableCell className="text-right font-mono">{str(row["count"])}</TableCell>
                                    </TableRow>
                                    for row in error_rows
                                ]}
                            </TableBody>
                        </Table>
                    </CardContent>
                </Card>
                if len(error_rows) > 0 else None
            }
        </div>;
}
