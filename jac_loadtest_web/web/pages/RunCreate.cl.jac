"""Run creation page (/workspaces/:id/runs/new)."""

import from 'react-router-dom' { useParams, useNavigate }
sv import from ..services.workspace_walkers { get_workspace }
sv import from ..services.run_walkers { create_run, start_run }
import from ..components.ui.spinner { Spinner }
import from ..components.RunSettingsForm { RunSettingsForm }

def:pub RunCreate() -> JsxElement {
    has workspace: dict = {},
        loading: bool = True,
        submitting: bool = False,
        error: str = "";

    params = useParams();
    navigate = useNavigate();
    ws_id = params["id"];

    can with entry {
        loadWorkspace();
    }

    async def loadWorkspace() {
        result = root spawn get_workspace(workspace_id=ws_id);
        reply: dict = result.reports[0] if result.reports else {};
        if not reply.get("error") {
            workspace = reply;
        }
        loading = False;
    }

    async def handleSubmit(settings: dict) {
        submitting = True;
        error = "";
        create_result = root spawn create_run(
            workspace_id=ws_id,
            vus=settings["vus"],
            iterations=settings["iterations"],
            ramp_up=settings["ramp_up"],
            workers=settings["workers"],
            rps=settings["rps"],
            think_time=settings["think_time"],
            think_time_scale=settings["think_time_scale"],
            timeout=settings["timeout"],
            fail_on_error_rate=settings["fail_on_error_rate"],
            fail_on_p95=settings["fail_on_p95"],
            fail_on_p99=settings["fail_on_p99"],
            abort_on_fail=settings["abort_on_fail"],
            threshold_start_delay=settings["threshold_start_delay"],
            label=settings["label"] or "",
        );
        create_reply: dict = create_result.reports[0] if create_result.reports else {};
        if create_reply.get("error") {
            error = create_reply["error"];
            submitting = False;
            return;
        }
        run_id = create_reply["id"];
        start_result = root spawn start_run(run_id=run_id);
        start_reply: dict = start_result.reports[0] if start_result.reports else {};
        if start_reply.get("error") {
            error = start_reply["error"];
            submitting = False;
            return;
        }
        navigate("/workspaces/" + ws_id + "/runs/" + run_id);
    }

    if loading {
        return
            <div className="min-h-screen flex items-center justify-center">
                <Spinner />
            </div>;
    }

    return
        <div className="min-h-screen bg-background p-6">
            <div className="max-w-2xl mx-auto flex flex-col gap-6">
                <div>
                    <button
                        onClick={lambda e: any { navigate("/workspaces/" + ws_id); }}
                        className="text-sm text-muted-foreground hover:text-foreground"
                    >
                        ← {workspace.get("name", "Workspace")}
                    </button>
                    <h1 className="text-2xl font-bold mt-2">New run</h1>
                </div>
                {<p className="text-destructive text-sm">{error}</p> if error else None}
                <RunSettingsForm on_submit={handleSubmit} submitting={submitting} />
            </div>
        </div>;
}
