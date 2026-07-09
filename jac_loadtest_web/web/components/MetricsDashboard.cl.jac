"""MetricsDashboard — SSE live metrics with latency and RPS charts.

stream_metrics is a raw streaming `def` (not a walker), so it can't go through
the sv-import RPC stub (stubs buffer the whole response) and EventSource can't
carry the Authorization header or a POST body it needs — this consumes the
SSE frames directly via fetch + a manual reader loop (see jac-sv-streaming).
"""

import from 'recharts' { ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip }
import from .LatencyChart { LatencyChart }
import from .RunControl { RunControl }

glob _NL: str = chr(10);

def:pub MetricsDashboard(
    run_id: str,
    on_stop: object = None,
    on_finished: object = None
) -> JsxElement {
    has snapshots: list = [],
        latest: dict = {},
        status: str = "running";

    can with entry {
        startStream();
    }

    async def startStream() {
        token = localStorage.getItem("token") or "";
        resp = await fetch("/function/stream_metrics", {
            "method": "POST",
            "headers": {
                "Content-Type": "application/json",
                "Authorization": "Bearer " + token
            },
            "body": JSON.stringify({"run_id": run_id})
        });
        reader = resp.body.getReader();
        decoder = new(TextDecoder);
        buf = "";
        feeding = True;
        # `snapshots` is reactive `has` state, and this loop awaits repeatedly
        # (reader.read()) — reading a reactive field back after an await gives
        # the render-time snapshot, not this loop's own last write (see
        # jac-cl-components: "long-running async code reads a STALE snapshot
        # of `has` state"). Accumulate into this local instead, and assign the
        # whole value to `snapshots` each tick so the chart keeps prior points.
        acc_snapshots: list = [];
        while feeding {
            part = await reader.read();
            if part.done {
                feeding = False;
                continue;
            }
            buf = buf + decoder.decode(part.value, {"stream": True});
            frames = buf.split(_NL + _NL);
            buf = frames.pop();
            for frame in frames {
                for line in frame.split(_NL) {
                    if line.startswith("data: ") {
                        payload = JSON.parse(line[6:]);
                        if payload.get("done") {
                            status = payload.get("status", "completed");
                            feeding = False;
                            if on_finished is not None {
                                await on_finished();
                            }
                        } elif payload.get("error") {
                            feeding = False;
                        } else {
                            acc_snapshots = acc_snapshots + [payload];
                            snapshots = acc_snapshots;
                            latest = payload;
                        }
                    }
                }
            }
        }
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
                status={status}
                elapsed_s={latest.get("elapsed_s", 0.0)}
                active_vus={latest.get("active_vus", 0)}
                rps={latest.get("rps", 0.0)}
                error_rate={latest.get("error_rate", 0.0)}
                on_stop={on_stop}
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
