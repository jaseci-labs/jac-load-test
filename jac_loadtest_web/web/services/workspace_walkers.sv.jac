"""Workspace CRUD walkers.

All plain (authenticated) walkers — jac-scale enforces a valid JWT and runs
each against the caller's own root, so `[root --> ][?:Workspace]` already
gives per-user isolation with no manual user-id filtering.
"""

import from datetime { datetime, UTC }
import from jaclang.jac0core.constructs { Root }
import from models.workspace { Workspace }
import from models.run { LoadTestRun }

def _workspace_view(ws: Workspace) -> dict {
    run_count = len([root --> ][?:LoadTestRun][?workspace_id == jid(ws)]);
    return {
        "id": jid(ws),
        "name": ws.name,
        "description": ws.description,
        "mode": ws.mode,
        "target_url": ws.target_url,
        "services_map_json": ws.services_map_json,
        "har_entries_json": ws.har_entries_json,
        "username": ws.username,
        "login_path": ws.login_path,
        "include_static": ws.include_static,
        "run_count": run_count,
        "created_at": ws.created_at,
        "updated_at": ws.updated_at,
    };
}

# jobj() resolves regardless of ownership — it would let any authenticated user
# reach another user's workspace by guessing an id. Workspaces hang directly
# off `root`, so scoping the search to [root --> ] is both correct and an
# ownership check for free (also sidesteps jobj()'s raise-on-malformed-id).
def _find_workspace(workspace_id: str) -> Workspace | None {
    for w in [root --> ][?:Workspace] {
        if jid(w) == workspace_id {
            return w;
        }
    }
    return None;
}

walker create_workspace {
    has name: str;
    has description: str = "";
    has mode: str = "monolith";
    has target_url: str | None = None;
    has services_map_json: str | None = None;
    has username: str | None = None;
    has password: str | None = None;
    has login_path: str = "/user/login";
    has include_static: bool = False;
    has har_raw_json: str | None = None;
    has har_entries_json: str | None = None;

    can create with Root entry {
        if not self.name.strip() {
            report {"error": "Workspace name is required"};
            return;
        }
        if self.mode == "monolith" and not (self.target_url and self.target_url.strip()) {
            report {"error": "Target URL is required for monolith workspaces"};
            return;
        }
        if self.mode == "microservice" and not (self.services_map_json and self.services_map_json.strip()) {
            report {"error": "Service map is required for microservice workspaces"};
            return;
        }
        if not (self.har_raw_json and self.har_entries_json) {
            report {"error": "A HAR recording is required"};
            return;
        }
        if bool(self.username) != bool(self.password) {
            report {"error": "Both username and password are required together"};
            return;
        }
        now = datetime.now(UTC).isoformat();
        ws = root ++> Workspace(
            name=self.name.strip(),
            description=self.description,
            mode=self.mode,
            target_url=self.target_url,
            services_map_json=self.services_map_json,
            username=self.username,
            password=self.password,
            login_path=self.login_path,
            include_static=self.include_static,
            har_raw_json=self.har_raw_json,
            har_entries_json=self.har_entries_json,
            created_at=now,
            updated_at=now,
        );
        report _workspace_view(ws);
    }
}

walker list_workspaces {
    can list with Root entry {
        workspaces = [root --> ][?:Workspace];
        report [_workspace_view(ws) for ws in workspaces];
    }
}

walker get_workspace {
    has workspace_id: str;

    can get with Root entry {
        ws = _find_workspace(self.workspace_id);
        if ws is None {
            report {"error": "Workspace not found"};
            return;
        }
        report _workspace_view(ws);
    }
}

walker update_workspace {
    has workspace_id: str;
    has name: str | None = None;
    has description: str | None = None;
    has target_url: str | None = None;
    has services_map_json: str | None = None;
    has username: str | None = None;
    has password: str | None = None;
    has login_path: str | None = None;
    has include_static: bool | None = None;
    has har_raw_json: str | None = None;
    has har_entries_json: str | None = None;

    can update with Root entry {
        ws = _find_workspace(self.workspace_id);
        if ws is None {
            report {"error": "Workspace not found"};
            return;
        }
        if self.name is not None {
            ws.name = self.name;
        }
        if self.description is not None {
            ws.description = self.description;
        }
        if self.target_url is not None {
            ws.target_url = self.target_url;
        }
        if self.services_map_json is not None {
            ws.services_map_json = self.services_map_json;
        }
        if self.username is not None {
            ws.username = self.username;
        }
        if self.password is not None {
            ws.password = self.password;
        }
        if self.login_path is not None {
            ws.login_path = self.login_path;
        }
        if self.include_static is not None {
            ws.include_static = self.include_static;
        }
        if self.har_raw_json is not None {
            ws.har_raw_json = self.har_raw_json;
        }
        if self.har_entries_json is not None {
            ws.har_entries_json = self.har_entries_json;
        }
        ws.updated_at = datetime.now(UTC).isoformat();
        report _workspace_view(ws);
    }
}

walker delete_workspace {
    has workspace_id: str;

    can delete with Root entry {
        ws = _find_workspace(self.workspace_id);
        if ws is None {
            report {"error": "Workspace not found"};
            return;
        }
        del ws;
        report {"ok": True};
    }
}

"""Best-effort reachability ping for the wizard's target-URL step. Never
blocks workspace creation — the client shows this as a warning, not a gate."""
async walker check_reachability {
    has url: str;

    async can ping with Root entry {
        import aiohttp;

        try {
            timeout = aiohttp.ClientTimeout(total=5.0);
            async with aiohttp.ClientSession(timeout=timeout) as session {
                async with session.get(self.url, allow_redirects=True, ssl=False) as resp {
                    report {"reachable": True, "status": resp.status, "error": None};
                    return;
                }
            }
        } except Exception as e {
            report {"reachable": False, "status": None, "error": str(e)};
        }
    }
}
