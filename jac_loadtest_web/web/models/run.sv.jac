"""LoadTestRun node — a single load-test execution inside a Workspace.

All fields map directly to LoadTestConfig fields in jac_loadtest_cli.
The sv walker builds LoadTestConfig.from_dict() from these values —
no jac.toml lookup happens.

Note: the engine's only stop condition is `iterations` (N HAR replays per
VU) — there is no wall-clock "duration" concept in LoadTestConfig, so this
node doesn't carry one either.
"""

node LoadTestRun {
    has label: str = "";
    has workspace_id: str = "";

    # engine settings
    has vus: int = 1;
    has iterations: int = 1;
    has ramp_up: str = "0s";
    has workers: int = 0;    # 0 = auto (server resolves via os.cpu_count() at start_run)
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
    has results_html: str | None = None;
    has error_message: str | None = None;
}
