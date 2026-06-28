"""WorkspaceCard component.

Phase 6: displays workspace name, mode, run count, and last-run status.
Used in WorkspaceList and as the run-history row in WorkspaceDetail.
"""

cl def:pub WorkspaceCard(
    id: str,
    name: str,
    mode: str,
    run_count: int = 0
) -> JsxElement {
    return <div>{name} ({mode}) — TODO</div>;
}
