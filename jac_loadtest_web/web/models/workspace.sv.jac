"""Workspace node — persistent load-test project.

Holds mode, target URL / services map, HAR file path, and credentials.
One user owns many workspaces; one workspace has many LoadTestRun nodes.
"""

node Workspace {
    has name: str;
    has description: str = "";
    has mode: str = "monolith";

    # monolith
    has target_url: str | None = None;

    # microservice
    has services_map_json: str | None = None;

    # HAR
    has har_file_path: str | None = None;
    has har_entries_json: str | None = None;

    # target-app credentials (NOT web-app auth)
    has username: str | None = None;
    has password: str | None = None;
    has login_path: str = "/user/login";
    has include_static: bool = False;

    has created_at: str = "";
    has updated_at: str = "";
}
