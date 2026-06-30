"""File upload and proxy recorder walkers.

Phase 6 walkers to implement:
  - upload_har(workspace_id, har_file: multipart)
        -> {entries: list, security_warning: bool}
  - update_har_entries(workspace_id, enabled_entries: list[int]) -> {ok}
  - upload_credentials_csv(workspace_id, csv_file: multipart)
        -> {row_count, preview: list}
  - start_proxy(workspace_id, port: int, scope_url: str) -> {ok}
  - stop_proxy(workspace_id) -> {entries: list}

The proxy walker spins up a local aiohttp HTTP proxy on the given port.
Captured traffic is accumulated in-memory in the sv codespace until
stop_proxy is called.
"""
