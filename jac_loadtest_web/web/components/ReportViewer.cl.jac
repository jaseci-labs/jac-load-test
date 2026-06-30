"""ReportViewer — rendered post-run report with summary, charts, and downloads."""

import from 'recharts' { ResponsiveContainer, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip }
import from .ui.card { Card, CardHeader, CardTitle, CardContent }
import from .ui.badge { Badge }
import from .ui.button { Button }
import from .ui.table { Table, TableHeader, TableBody, TableHead, TableRow, TableCell }
import from .ui.separator { Separator }
import from .LatencyChart { LatencyChart }

def:pub ReportViewer(
    results_json: str,
    passed_thresholds: any = None
) -> JsxElement {
    report_json = json.loads(results_json or "{}");

    def downloadJson() {
        blob = Blob([results_json], {"type": "application/json"});
        url = URL.createObjectURL(blob);
        a = document.createElement("a");
        a.href = url;
        a.download = "report.json";
        a.click();
        URL.revokeObjectURL(url);
    }

    summary = report_json.get("summary", {});
    endpoints = report_json.get("endpoints", []);
    snapshots = report_json.get("snapshots", []);

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
            "path": ep.get("path", "?")[-28:],
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
                                    Total requests
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(summary.get("total_requests", 0))}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Avg RPS
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("rps", 0.0), 1))}
                                </TableCell>
                            </TableRow>
                            <TableRow>
                                <TableHead className="font-normal text-muted-foreground">
                                    Error rate
                                </TableHead>
                                <TableCell className="text-right font-mono">
                                    {str(round(summary.get("error_rate", 0.0), 2)) + "%"}
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
        </div>;
}
