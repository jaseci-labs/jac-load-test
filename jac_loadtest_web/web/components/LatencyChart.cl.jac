"""LatencyChart — recharts line chart for p50/p95/p99 latency over time."""

import from 'recharts' { ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend }

def:pub LatencyChart(
    snapshots: list,
    title: str = "Latency over time"
) -> JsxElement {
    if len(snapshots) == 0 {
        return
            <div className="flex items-center justify-center h-48 text-muted-foreground text-sm">
                Waiting for data…
            </div>;
    }

    chart_data = [
        {
            "t": str(round(s.get("elapsed_s", 0))) + "s",
            "p50": round(s.get("p50_ms", 0), 1),
            "p95": round(s.get("p95_ms", 0), 1),
            "p99": round(s.get("p99_ms", 0), 1)
        }
        for s in snapshots
    ];

    return
        <div className="flex flex-col gap-2">
            <p className="text-sm font-medium text-muted-foreground">{title}</p>
            <ResponsiveContainer width="100%" height={220}>
                <LineChart data={chart_data} margin={{"top": 4, "right": 8, "left": 0, "bottom": 0}}>
                    <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                    <XAxis dataKey="t" tick={{"fontSize": 11}} />
                    <YAxis unit=" ms" tick={{"fontSize": 11}} width={56} />
                    <Tooltip />
                    <Legend iconType="circle" />
                    <Line
                        type="monotone"
                        dataKey="p50"
                        name="p50"
                        stroke="var(--color-primary)"
                        dot={False}
                        strokeWidth={2}
                    />
                    <Line
                        type="monotone"
                        dataKey="p95"
                        name="p95"
                        stroke="var(--color-chart-2)"
                        dot={False}
                        strokeWidth={2}
                    />
                    <Line
                        type="monotone"
                        dataKey="p99"
                        name="p99"
                        stroke="var(--color-destructive)"
                        dot={False}
                        strokeWidth={2}
                    />
                </LineChart>
            </ResponsiveContainer>
        </div>;
}
