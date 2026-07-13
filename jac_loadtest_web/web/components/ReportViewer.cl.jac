"""ReportViewer — rendered post-run report with summary, charts, and downloads."""

import from ..services.run_walkers { get_run_html }
import from 'recharts' { ResponsiveContainer, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip }
import from .ui.card { Card, CardHeader, CardTitle, CardContent }
import from .ui.badge { Badge }
import from .ui.button { Button }
import from .ui.table { Table, TableHeader, TableBody, TableHead, TableRow, TableCell }
import from .ui.separator { Separator }
import from .LatencyChart { LatencyChart }

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
    # render_json calls this "timeseries" with a "timestamp" field; the live
    # SSE schema (which LatencyChart is shared with) calls it "elapsed_s" —
    # adapt post-run data to the same shape rather than forking the chart.
    snapshots = [
        {**t, "elapsed_s": t.get("timestamp", 0)}
        for t in report_json.get("timeseries", [])
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
            "p95": round(ep.get("p95_ms", 0), 1)
        }
        for ep in endpoints[:12]
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
                        </TableBody>
                    </Table>
                </CardContent>
            </Card>

            {<LatencyChart snapshots={snapshots} title="Latency over time" /> if len(snapshots) > 0 else None}

            {
                <Card>
                    <CardHeader>
                        <CardTitle className="text-sm">Per-endpoint p95 latency</CardTitle>
                    </CardHeader>
                    <CardContent>
                        <ResponsiveContainer width="100%" height={240}>
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
                                <Bar dataKey="p95" name="p95 ms" fill="var(--color-primary)" />
                            </BarChart>
                        </ResponsiveContainer>
                    </CardContent>
                </Card>
                if len(endpoints) > 0 else None
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
