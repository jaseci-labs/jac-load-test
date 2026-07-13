"""Run detail page (/workspaces/:id/runs/:run_id) — live metrics and final report."""

import from 'react-router-dom' { useParams, useNavigate }
import from ..services.run_walkers { get_run, stop_run, delete_run }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.spinner { Spinner }
import from ..components.ui.separator { Separator }
import from ..components.ui.alert { Alert, AlertDescription }
import from ..components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter }
import from ..components.MetricsDashboard { MetricsDashboard }
import from ..components.ReportViewer { ReportViewer }
import from ..components.ThemeToggle { ThemeToggle }

def:pub RunDetail() -> JsxElement {
    has run: dict = {},
        loading: bool = True,
        deleting: bool = False,
        deleteOpen: bool = False;

    params = useParams();
    navigate = useNavigate();
    ws_id = params["id"];
    run_id = params["run_id"];

    can with entry {
        loadRun();
    }

    async def loadRun() {
        result = root spawn get_run(run_id=run_id);
        reply: dict = result.reports[0] if result.reports else {};
        if not reply.get("error") {
            run = reply;
        } else {
            # get_run failing here (e.g. right as the stream wraps up) used to
            # be silent — `run` is left at its stale previous value with no
            # way to tell why, which looks like the run being stuck
            # "running" forever. Log it so this is visible in devtools.
            console.error("get_run failed for run " + run_id + ": " + str(reply.get("error")));
        }
        loading = False;
    }

    async def _delay(ms: int) {
        await new(Promise, lambda resolve: any { setTimeout(resolve, ms); });
    }

    async def handleStop() {
        await (root spawn stop_run(run_id=run_id));
    }

    async def handleDelete() {
        deleting = True;
        result = root spawn delete_run(run_id=run_id);
        reply: dict = result.reports[0] if result.reports else {};
        if not reply.get("error") {
            navigate("/workspaces/" + ws_id);
        }
        deleting = False;
    }

    # Fired once the live SSE stream ends — reloads the run so
    # results_json/passed_thresholds (only set once the background execution
    # finishes) show up in the post-run report. The stream ending should mean
    # the run is terminal server-side by now, but a get_run issued right at
    # that instant can occasionally still observe "running" (the completion
    # write landing a beat after the stream's own close reaches the client).
    # Retry briefly instead of getting stuck showing the live dashboard
    # forever on a status that's already stale by the time it's read.
    async def handleRunFinished() {
        attempt = 0;
        while attempt < 5 {
            await loadRun();
            if run.get("status", "running") != "running" {
                return;
            }
            attempt = attempt + 1;
            await _delay(1000);
        }
        console.error("Run " + run_id + " still shows 'running' after stream ended and 5 retries");
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
                    <div className="flex items-center gap-2">
                        <ThemeToggle />
                        {
                            <div className="flex items-center gap-2">
                                <Button
                                    variant="outline"
                                    onClick={lambda e: any {
                                        navigate("/workspaces/" + ws_id + "/runs/new");
                                    }}
                                >
                                    Re-run
                                </Button>
                                <Dialog
                                    open={deleteOpen}
                                    onOpenChange={lambda v: any { deleteOpen = v; }}
                                >
                                    <DialogTrigger asChild={True}>
                                        <Button variant="destructive">Delete</Button>
                                    </DialogTrigger>
                                    <DialogContent>
                                        <DialogHeader>
                                            <DialogTitle>Delete run?</DialogTitle>
                                            <DialogDescription>
                                                This permanently deletes this run and its results.
                                            </DialogDescription>
                                        </DialogHeader>
                                        <DialogFooter>
                                            <Button
                                                variant="outline"
                                                onClick={lambda e: any { deleteOpen = False; }}
                                            >
                                                Cancel
                                            </Button>
                                            <Button
                                                variant="destructive"
                                                onClick={handleDelete}
                                                disabled={deleting}
                                            >
                                                {"Deleting…" if deleting else "Delete"}
                                            </Button>
                                        </DialogFooter>
                                    </DialogContent>
                                </Dialog>
                            </div>
                            if is_terminal else None
                        }
                    </div>
                </div>

                {
                    <MetricsDashboard
                        run_id={run_id}
                        on_stop={handleStop}
                        on_finished={handleRunFinished}
                    />
                    if not is_terminal else None
                }

                {
                    <div className="flex flex-col gap-4">
                        <Alert variant={"destructive" if status == "failed" else "default"}>
                            <AlertDescription>
                                {
                                    ("Run failed: " + run.get("error_message", "unknown error"))
                                    if status == "failed" else
                                    ("Load test run complete." if status == "completed" else "Load test run stopped.")
                                }
                            </AlertDescription>
                        </Alert>
                        <Separator />
                        <ReportViewer
                            run_id={run_id}
                            results_json={run.get("results_json", "{}")}
                            passed_thresholds={run.get("passed_thresholds", None)}
                        />
                    </div>
                    if is_terminal else None
                }
            </div>
        </div>;
}
