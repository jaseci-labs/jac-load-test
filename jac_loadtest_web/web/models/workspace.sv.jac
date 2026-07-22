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

    # HAR — raw recording content and the user's enable/disable selection over its
    # entries. Stored as text directly on the node for now rather than through
    # jac-scale's file Storage abstraction (har_file_path is reserved for that
    # migration later); HAR files are small enough for this to be fine in dev.
    has har_file_path: str | None = None;
    has har_raw_json: str | None = None;
    has har_entries_json: str | None = None;

    # target-app credentials (NOT web-app auth)
    has username: str | None = None;
    has password: str | None = None;
    has login_path: str = "/user/login";
    has include_static: bool = False;

    has created_at: str = "";
    has updated_at: str = "";
}
