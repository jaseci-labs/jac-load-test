"""Root application component with react-router-dom routes."""

import from 'react-router-dom' { BrowserRouter, Routes, Route }
import from "@jac/runtime" { AuthGuard }
import from .components.ThemeProvider { ThemeProvider }
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
    # ThemeProvider wraps the whole router (not embedded per-page) so the
    # saved theme is read ONCE at the true app root and every <ThemeToggle/>
    # shares that single live value — a hard refresh on any route re-applies
    # it before paint, and pages don't each re-derive their own copy on
    # their own loading timeline (see ThemeProvider for why that mattered).
    return
        <ThemeProvider>
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
            </BrowserRouter>
        </ThemeProvider>;
}
