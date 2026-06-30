"""LoadTestRun node — a single load-test execution inside a Workspace.

All fields map directly to LoadTestConfig fields in jac_loadtest_cli.
The sv walker builds LoadTestConfig.from_dict() from these values —
no jac.toml lookup happens.
"""

node LoadTestRun {
    has label: str = "";
    has workspace_id: str = "";

    # engine settings
    has vus: int = 1;
    has duration: str = "60s";
    has iterations: int = 1;
    has ramp_up: str = "0s";
    has workers: int = 1;
    has rps: int = 0;
    has think_time: str = "none";
    has think_time_scale: float = 1.0;
    has timeout: str = "30s";
    has max_samples: int = 1000000;

    # thresholds
    has fail_on_error_rate: float | None = None;
    has fail_on_p95: float | None = None;
    has fail_on_p99: float | None = None;
    has abort_on_fail: bool = False;
    has threshold_start_delay: str = "0s";

    # lifecycle
    has status: str = "pending";    # "pending"|"running"|"completed"|"failed"|"stopped"
    has started_at: str | None = None;
    has completed_at: str | None = None;
    has passed_thresholds: bool | None = None;
    has results_json: str | None = None;
}
