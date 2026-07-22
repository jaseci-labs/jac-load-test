"""RpsChart — recharts line chart for cumulative RPS over time."""

import from 'recharts' { ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip }

def:pub RpsChart(
    snapshots: list,
    title: str = "Requests per second"
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
            "rps": round(s.get("rps", 0), 1)
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
                    <YAxis tick={{"fontSize": 11}} width={40} />
                    <Tooltip />
                    <Line
                        type="monotone"
                        dataKey="rps"
                        name="RPS"
                        stroke="var(--color-primary)"
                        dot={False}
                        strokeWidth={2}
                    />
                </LineChart>
            </ResponsiveContainer>
        </div>;
}
