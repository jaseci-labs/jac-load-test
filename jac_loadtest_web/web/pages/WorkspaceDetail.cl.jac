"""Workspace detail page (/workspaces/:id)."""

import from 'react-router-dom' { useParams, useNavigate }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from ..components.ui.spinner { Spinner }
import from ..components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter }
import from ..components.HarEntryTable { HarEntryTable }
import from ..components.WorkspaceCard { WorkspaceCard }

def:pub WorkspaceDetail() -> JsxElement {
    has workspace: dict = {},
        runs: list = [],
        loading: bool = True,
        deleting: bool = False,
        deleteOpen: bool = False;

    params = useParams();
    navigate = useNavigate();
    ws_id = params["id"];

    can with entry {
        loadData();
    }

    async def loadData() {
        token = localStorage.getItem("token") or "";
        headers = {"Authorization": "Bearer " + token};
        ws_resp = await fetch("/api/workspace/get_workspace/" + ws_id, {"headers": headers});
        runs_resp = await fetch("/api/run/list_runs/" + ws_id, {"headers": headers});
        if ws_resp.ok {
            workspace = await ws_resp.json();
        }
        if runs_resp.ok {
            runs = await runs_resp.json();
        }
        loading = False;
    }

    async def handleDelete() {
        deleting = True;
        resp = await fetch("/api/workspace/delete_workspace/" + ws_id, {
            "method": "DELETE",
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("token") or "")}
        });
        if resp.ok {
            navigate("/workspaces");
        }
        deleting = False;
    }

    def onToggleEntry(index: int, enabled: bool) {
        entries = workspace.get("har_entries", []);
        entries[index]["enabled"] = enabled;
        workspace = {**workspace, "har_entries": entries};
    }

    if loading {
        return
            <div className="min-h-screen flex items-center justify-center">
                <Spinner />
            </div>;
    }

    return
        <div className="min-h-screen bg-background">
            <div className="max-w-5xl mx-auto p-6 flex flex-col gap-6">
                <div className="flex items-center justify-between">
                    <div className="flex flex-col gap-1">
                        <button
                            onClick={lambda e: any { navigate("/workspaces"); }}
                            className="text-sm text-muted-foreground hover:text-foreground w-fit"
                        >
                            ← Workspaces
                        </button>
                        <div className="flex items-center gap-3">
                            <h1 className="text-2xl font-bold">
                                {workspace.get("name", ws_id)}
                            </h1>
                            <Badge variant="secondary">
                                {workspace.get("mode", "monolith")}
                            </Badge>
                        </div>
                    </div>
                    <div className="flex gap-2">
                        <Button
                            variant="outline"
                            onClick={lambda e: any { navigate("/workspaces/" + ws_id + "/runs/new"); }}
                        >
                            New run
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
                                    <DialogTitle>Delete workspace?</DialogTitle>
                                    <DialogDescription>
                                        This permanently deletes the workspace and all its runs.
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
                </div>

                <Tabs defaultValue="requests">
                    <TabsList>
                        <TabsTrigger value="requests">Requests</TabsTrigger>
                        <TabsTrigger value="runs">Run history</TabsTrigger>
                    </TabsList>
                    <TabsContent value="requests" className="mt-4">
                        <HarEntryTable
                            entries={workspace.get("har_entries", [])}
                            on_toggle={onToggleEntry}
                        />
                    </TabsContent>
                    <TabsContent value="runs" className="mt-4">
                        {
                            <p className="text-muted-foreground text-sm text-center py-8">
                                No runs yet.
                            </p>
                            if len(runs) == 0 else
                            <div className="grid gap-3">
                                {[
                                    <WorkspaceCard
                                        key={r["id"]}
                                        id={r["id"]}
                                        name={"Run " + r.get("label", r["id"][:8])}
                                        mode={r.get("status", "unknown")}
                                        run_count={r.get("total_requests", 0)}
                                    />
                                    for r in runs
                                ]}
                            </div>
                        }
                    </TabsContent>
                </Tabs>
            </div>
        </div>;
}
