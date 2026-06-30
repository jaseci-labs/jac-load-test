"""Run creation page (/workspaces/:id/runs/new)."""

import from 'react-router-dom' { useParams, useNavigate }
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
        resp = await fetch("/api/workspace/get_workspace/" + ws_id, {
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
        });
        if resp.ok {
            workspace = await resp.json();
        }
        loading = False;
    }

    async def handleSubmit(settings: dict) {
        submitting = True;
        error = "";
        run_resp = await fetch("/api/run/create_run", {
            "method": "POST",
            "headers": {
                "Content-Type": "application/json",
                "Authorization": "Bearer " + (localStorage.getItem("token") or "")
            },
            "body": JSON.stringify({**settings, "workspace_id": ws_id})
        });
        if run_resp.ok {
            run = await run_resp.json();
            await fetch("/api/run/start_run/" + run["id"], {
                "method": "POST",
                "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
            });
            navigate("/workspaces/" + ws_id + "/runs/" + run["id"]);
        } else {
            data = await run_resp.json();
            error = data.get("detail", "Failed to create run");
        }
        submitting = False;
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
