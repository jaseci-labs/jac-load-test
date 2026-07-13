"""jac-loadtest web — fullstack entry point.

sv imports wire the server-side walkers into the jac-scale HTTP router.
cl import wires the React root component into the Vite bundle.
"""

# Web-app user accounts run entirely on jac-scale's built-in /user/register,
# /user/login, /user/me, /user/logout endpoints (see jac guide jac-cl-auth /
# jac-sv-auth) — no auth walkers of our own to register here.
#
# Every OTHER walker below is addressed generically over HTTP by
# `root spawn <name>(...)` — unlike `def:pub` function RPC, that mechanism
# has no `sv import` client stub to self-register from, so every such walker
# any page calls must be bound into this entry module's own namespace or it
# 405s (see docs/DATA_FLOWS.md).
import from services.workspace_walkers { list_workspaces, get_workspace, update_workspace, delete_workspace, create_workspace, check_reachability }
import from services.run_walkers { list_runs, create_run, start_run, get_run, stop_run, delete_run, get_run_html }
import from services.stream_walkers { stream_metrics }
import from services.file_walkers { upload_har }

cl import from .frontend { App }
cl import ".styles.global.css";

cl def:pub app -> JsxElement {
    return <App />;
}
