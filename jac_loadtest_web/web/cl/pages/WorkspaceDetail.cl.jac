"""Workspace detail page  (/workspaces/:id).

Sections:
  - HAR entry table with per-entry enable/disable toggles
  - "Replace HAR" / "Update Credentials" buttons
  - Run history list (WorkspaceCard list of LoadTestRun rows)
  - "New Run" button → /workspaces/:id/runs/new
  - Settings panel (edit name, URL, services map, login path)
  - Delete workspace (confirmation dialog)
"""

cl def:pub WorkspaceDetail() -> JsxElement {
    return <div>WorkspaceDetail — TODO</div>;
}
