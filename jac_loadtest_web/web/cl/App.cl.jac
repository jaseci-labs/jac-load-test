"""Root application component.

Phase 6: wire react-router-dom routes here once pages are implemented.

Route plan:
  /login           -> Login
  /register        -> Register
  /workspaces      -> WorkspaceList      (auth-guarded)
  /workspaces/new  -> WorkspaceCreate    (auth-guarded)
  /workspaces/:id  -> WorkspaceDetail    (auth-guarded)
  /workspaces/:id/runs/new      -> RunCreate   (auth-guarded)
  /workspaces/:id/runs/:run_id  -> RunDetail   (auth-guarded)
"""

cl def:pub App() -> JsxElement {
    return <div>jac-loadtest</div>;
}
