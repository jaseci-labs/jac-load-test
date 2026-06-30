"""MetricsDashboard — SSE live metrics with latency and RPS charts."""

import from 'recharts' { ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip }
import from .LatencyChart { LatencyChart }
import from .RunControl { RunControl }

def:pub MetricsDashboard(
    run_id: str,
    stream_url: str
) -> JsxElement {
    has snapshots: list = [],
        latest: dict = {},
        es: object = None;

    can with entry {
        startStream();
    }

    async def startStream() {
        source = EventSource(stream_url);
        es = source;
        source.onmessage = lambda event: any {
            snap = JSON.parse(event.data);
            snapshots = snapshots + [snap];
            latest = snap;
        };
        source.onerror = lambda _: any {
            source.close();
        };
    }

    rps_data = [
        {
            "t": str(round(s.get("elapsed_s", 0))) + "s",
            "rps": round(s.get("rps", 0), 1)
        }
        for s in snapshots
    ];

    return
        <div className="flex flex-col gap-6">
            <RunControl
                run_id={run_id}
                status="running"
                elapsed_s={latest.get("elapsed_s", 0.0)}
                active_vus={latest.get("active_vus", 0)}
                rps={latest.get("rps", 0.0)}
                error_rate={latest.get("error_rate", 0.0)}
            />

            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <LatencyChart snapshots={snapshots} title="Latency (p50 / p95 / p99)" />

                <div className="flex flex-col gap-2">
                    <p className="text-sm font-medium text-muted-foreground">
                        Requests per second
                    </p>
                    <ResponsiveContainer width="100%" height={220}>
                        <LineChart
                            data={rps_data}
                            margin={{"top": 4, "right": 8, "left": 0, "bottom": 0}}
                        >
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
                </div>
            </div>
        </div>;
}
