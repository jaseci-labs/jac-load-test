"""jac-loadtest web — fullstack entry point.

sv imports wire the server-side walkers into the jac-scale HTTP router.
cl import wires the React root component into the Vite bundle.
"""

# These have no .cl.jac caller yet (no sv import references them), so per the
# fullstack self-registration rule they need this plain entry-module import
# to register as REST endpoints at all.
import from services.auth_walkers { logout_user, me }
import from services.workspace_walkers { list_workspaces, get_workspace, update_workspace, delete_workspace }
import from services.run_walkers { list_runs }
import from services.stream_walkers { stream_metrics }

cl import from .frontend { App }
cl import ".styles.global.css";

cl def:pub app -> JsxElement {
    return <App />;
}
