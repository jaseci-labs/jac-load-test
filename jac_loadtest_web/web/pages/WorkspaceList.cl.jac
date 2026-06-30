"""Workspace list page (/workspaces)."""

import from 'react-router-dom' { useNavigate }
import from ..components.ui.button { Button }
import from ..components.ui.spinner { Spinner }
import from ..components.WorkspaceCard { WorkspaceCard }

def:pub WorkspaceList() -> JsxElement {
    has workspaces: list = [],
        loading: bool = True,
        error: str = "";

    navigate = useNavigate();

    can with entry {
        loadWorkspaces();
    }

    async def loadWorkspaces() {
        resp = await fetch("/api/workspace/list_workspaces", {
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
        });
        if resp.ok {
            workspaces = await resp.json();
        } else {
            error = "Failed to load workspaces";
        }
        loading = False;
    }

    if loading {
        return
            <div className="min-h-screen flex items-center justify-center">
                <Spinner />
            </div>;
    }

    return
        <div className="min-h-screen bg-background">
            <div className="max-w-4xl mx-auto p-6 flex flex-col gap-6">
                <div className="flex items-center justify-between">
                    <h1 className="text-2xl font-bold">Workspaces</h1>
                    <Button onClick={lambda e: any { navigate("/workspaces/new"); }}>
                        New workspace
                    </Button>
                </div>
                {<p className="text-destructive text-sm">{error}</p> if error else None}
                {
                    <div className="text-muted-foreground text-sm py-12 text-center">
                        No workspaces yet. Create one to get started.
                    </div>
                    if len(workspaces) == 0 else
                    <div className="grid gap-4">
                        {[
                            <WorkspaceCard
                                key={ws["id"]}
                                id={ws["id"]}
                                name={ws["name"]}
                                mode={ws["mode"]}
                                run_count={ws.get("run_count", 0)}
                            />
                            for ws in workspaces
                        ]}
                    </div>
                }
            </div>
        </div>;
}
