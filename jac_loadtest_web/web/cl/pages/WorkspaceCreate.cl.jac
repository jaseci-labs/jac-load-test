"""Workspace creation wizard  (/workspaces/new).

5-step wizard:
  Step 1 — Name + description
  Step 2 — Mode (monolith → target URL | microservice → service map)
  Step 3 — HAR upload or proxy recorder
  Step 4 — Credentials (none / single / CSV + login path)
  Step 5 — Review & create

On submit: POST to create_workspace sv walker, redirect to /workspaces/:id.
"""

cl def:pub WorkspaceCreate() -> JsxElement {
    return <div>WorkspaceCreate wizard — TODO</div>;
}
