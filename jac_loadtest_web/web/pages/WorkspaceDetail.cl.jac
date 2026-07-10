"""Workspace detail page (/workspaces/:id)."""

import from 'react-router-dom' { useParams, useNavigate }
import from ..services.workspace_walkers { get_workspace, delete_workspace, update_workspace }
import from ..services.run_walkers { list_runs }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from ..components.ui.spinner { Spinner }
import from ..components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter }
import from ..components.HarEntryTable { HarEntryTable }

def:pub WorkspaceDetail() -> JsxElement {
    has workspace: dict = {},
        har_entries: list = [],
        har_dirty: bool = False,
        saving_har: bool = False,
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
        ws_result = root spawn get_workspace(workspace_id=ws_id);
        ws_reply: dict = ws_result.reports[0] if ws_result.reports else {};
        if not ws_reply.get("error") {
            workspace = ws_reply;
            entries_json = ws_reply.get("har_entries_json") or "[]";
            har_entries = JSON.parse(entries_json);  # jac:ignore[W6001,W6002]
        }

        runs_result = root spawn list_runs(workspace_id=ws_id);
        runs = runs_result.reports[0] if runs_result.reports else [];

        loading = False;
    }

    async def handleDelete() {
        deleting = True;
        result = root spawn delete_workspace(workspace_id=ws_id);
        reply: dict = result.reports[0] if result.reports else {};
        if not reply.get("error") {
            navigate("/workspaces");
        }
        deleting = False;
    }

    def onToggleEntry(index: int, enabled: bool) {
        updated = [{**e} for e in har_entries];
        updated[index]["enabled"] = enabled;
        har_entries = updated;
        har_dirty = True;
    }

    async def handleSaveHar() {
        saving_har = True;
        result = root spawn update_workspace(
            workspace_id=ws_id,
            har_entries_json=JSON.stringify(har_entries),  # jac:ignore[W6001,W6002]
        );
        reply: dict = result.reports[0] if result.reports else {};
        if not reply.get("error") {
            har_dirty = False;
        }
        saving_har = False;
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
                        {
                            <p className="text-sm text-muted-foreground font-mono">
                                {workspace.get("target_url")}
                            </p>
                            if workspace.get("mode", "monolith") == "monolith" and workspace.get("target_url") else None
                        }
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
                    <TabsContent value="requests" className="mt-4 flex flex-col gap-3">
                        <HarEntryTable
                            entries={har_entries}
                            on_toggle={onToggleEntry}
                        />
                        {
                            <Button
                                size="sm"
                                className="w-fit"
                                onClick={handleSaveHar}
                                disabled={saving_har}
                            >
                                {"Saving…" if saving_har else "Save changes"}
                            </Button>
                            if har_dirty else None
                        }
                    </TabsContent>
                    <TabsContent value="runs" className="mt-4">
                        {
                            <p className="text-muted-foreground text-sm text-center py-8">
                                No runs yet.
                            </p>
                            if len(runs) == 0 else
                            <div className="flex flex-col gap-2">
                                {[
                                    <div
                                        key={r["id"]}
                                        className="flex items-center justify-between rounded-md border p-3 cursor-pointer hover:bg-muted/50"
                                        onClick={lambda e: any {
                                            navigate("/workspaces/" + ws_id + "/runs/" + r["id"]);
                                        }}
                                    >
                                        <div className="flex flex-col gap-0.5">
                                            <span className="text-sm font-medium">
                                                {r.get("label") or r["id"][:8]}
                                            </span>
                                            <span className="text-xs text-muted-foreground">
                                                {str(r.get("vus", 0)) + " VUs · " + str(r.get("iterations", 0)) + " iterations"}
                                            </span>
                                        </div>
                                        <Badge variant="secondary">{r.get("status", "unknown")}</Badge>
                                    </div>
                                    for r in runs
                                ]}
                            </div>
                        }
                    </TabsContent>
                </Tabs>
            </div>
        </div>;
}
