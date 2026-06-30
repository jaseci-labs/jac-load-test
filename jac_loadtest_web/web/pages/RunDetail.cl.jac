"""Run detail page (/workspaces/:id/runs/:run_id) — live metrics and final report."""

import from 'react-router-dom' { useParams, useNavigate }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.spinner { Spinner }
import from ..components.ui.separator { Separator }
import from ..components.RunControl { RunControl }
import from ..components.MetricsDashboard { MetricsDashboard }
import from ..components.ReportViewer { ReportViewer }

def:pub RunDetail() -> JsxElement {
    has run: dict = {},
        loading: bool = True,
        stream_url: str = "";

    params = useParams();
    navigate = useNavigate();
    ws_id = params["id"];
    run_id = params["run_id"];

    can with entry {
        loadRun();
    }

    async def loadRun() {
        resp = await fetch("/api/run/get_run/" + run_id, {
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
        });
        if resp.ok {
            run = await resp.json();
            stream_url = "/api/run/stream_metrics/" + run_id;
        }
        loading = False;
    }

    async def handleStop() {
        await fetch("/api/run/stop_run/" + run_id, {
            "method": "POST",
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
        });
        loadRun();
    }

    if loading {
        return
            <div className="min-h-screen flex items-center justify-center">
                <Spinner />
            </div>;
    }

    status = run.get("status", "unknown");
    is_terminal = status in ["completed", "stopped", "failed"];
    badge_variant = "default" if status == "running" else ("secondary" if status == "completed" else "destructive");

    return
        <div className="min-h-screen bg-background">
            <div className="max-w-5xl mx-auto p-6 flex flex-col gap-6">
                <div className="flex items-center justify-between">
                    <div className="flex flex-col gap-1">
                        <button
                            onClick={lambda e: any { navigate("/workspaces/" + ws_id); }}
                            className="text-sm text-muted-foreground hover:text-foreground w-fit"
                        >
                            ← Workspace
                        </button>
                        <div className="flex items-center gap-3">
                            <h1 className="text-xl font-bold">
                                {"Run " + run.get("label", run_id[:8])}
                            </h1>
                            <Badge variant={badge_variant}>
                                {status.upper()}
                            </Badge>
                        </div>
                    </div>
                    {
                        <Button variant="destructive" onClick={handleStop}>
                            Stop run
                        </Button>
                        if status == "running" else
                        <Button
                            variant="outline"
                            onClick={lambda e: any {
                                navigate("/workspaces/" + ws_id + "/runs/new");
                            }}
                        >
                            Re-run
                        </Button>
                    }
                </div>

                {
                    <RunControl
                        run_id={run_id}
                        status={status}
                        on_stop={handleStop}
                    />
                    if not is_terminal else None
                }

                {
                    <MetricsDashboard run_id={run_id} stream_url={stream_url} />
                    if not is_terminal else None
                }

                {
                    <div className="flex flex-col gap-4">
                        <Separator />
                        <ReportViewer
                            results_json={run.get("results_json", "{}")}
                            passed_thresholds={run.get("passed_thresholds", None)}
                        />
                    </div>
                    if is_terminal else None
                }
            </div>
        </div>;
}
