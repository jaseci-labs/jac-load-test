"""Root application component with react-router-dom routes."""

import from 'react-router-dom' { BrowserRouter, Routes, Route }
import from "@jac/runtime" { AuthGuard }
import from .pages.Landing { Landing }
import from .pages.Login { Login }
import from .pages.Register { Register }
import from .pages.WorkspaceList { WorkspaceList }
import from .pages.WorkspaceCreate { WorkspaceCreate }
import from .pages.WorkspaceDetail { WorkspaceDetail }
import from .pages.RunCreate { RunCreate }
import from .pages.RunDetail { RunDetail }
import ".styles.global.css";

# AuthGuard is a layout route: when logged in it renders <Outlet/> (ignoring
# any children passed directly to it), so protected pages must be nested
# Route children under it, not wrapped individually as
# `<AuthGuard><Page/></AuthGuard>` — that form renders blank, since Outlet
# has no nested route to fill in that case.
def:pub App() -> JsxElement {
    return
        <BrowserRouter>
            <Routes>
                <Route path="/" element={<Landing />} />
                <Route path="/login" element={<Login />} />
                <Route path="/register" element={<Register />} />
                <Route element={<AuthGuard redirect="/login" />}>
                    <Route path="/workspaces" element={<WorkspaceList />} />
                    <Route path="/workspaces/new" element={<WorkspaceCreate />} />
                    <Route path="/workspaces/:id" element={<WorkspaceDetail />} />
                    <Route path="/workspaces/:id/runs/new" element={<RunCreate />} />
                    <Route path="/workspaces/:id/runs/:run_id" element={<RunDetail />} />
                </Route>
            </Routes>
        </BrowserRouter>;
}
