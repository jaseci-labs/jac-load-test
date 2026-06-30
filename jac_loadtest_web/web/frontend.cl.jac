"""Root application component with react-router-dom routes."""

import from 'react-router-dom' { BrowserRouter, Routes, Route }
import from .pages.Landing { Landing }
import from .pages.Login { Login }
import from .pages.Register { Register }
import from .pages.WorkspaceList { WorkspaceList }
import from .pages.WorkspaceCreate { WorkspaceCreate }
import from .pages.WorkspaceDetail { WorkspaceDetail }
import from .pages.RunCreate { RunCreate }
import from .pages.RunDetail { RunDetail }

def:pub App() -> JsxElement {
    return
        <BrowserRouter>
            <Routes>
                <Route path="/" element={<Landing />} />
                <Route path="/login" element={<Login />} />
                <Route path="/register" element={<Register />} />
                <Route path="/workspaces" element={<WorkspaceList />} />
                <Route path="/workspaces/new" element={<WorkspaceCreate />} />
                <Route path="/workspaces/:id" element={<WorkspaceDetail />} />
                <Route path="/workspaces/:id/runs/new" element={<RunCreate />} />
                <Route path="/workspaces/:id/runs/:run_id" element={<RunDetail />} />
            </Routes>
        </BrowserRouter>;
}
