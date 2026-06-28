"""HarEntryTable component.

Phase 6: renders parsed HAR entries with columns:
  method, path, status code (from recording), MIME type, response time.
Per-row enable/disable toggle. "Save" persists selection to server.
Shows security warning banner when Authorization/Cookie headers detected.
"""

cl def:pub HarEntryTable(
    entries: list,
    on_toggle: object
) -> JsxElement {
    return <div>HarEntryTable — TODO</div>;
}
