"""Run-wide state handed to every Locust user.

Locust instantiates user classes itself, with only an Environment, so anything a
user needs (the parsed HAR, the config, correlation rules, the account pool)
cannot be passed to its constructor. The runner builds one RunContext before the
run starts and parks it here; users read it in on_start.

No Locust import here: this module is safe to import anywhere.
"""

import from ..config { LoadTestConfig }
import from ..core.har_parser { HarEntry }
import from ..core.correlation { CorrelationRule }
import from ..core.parameterize { ParamRule }
import from ..bridge.auth { Credential }
import from ..bridge.body_check { ResponseShape }
import from ..bridge.topology { TopologyRouter }
import from .checks { PollRule }
import from .infra { Suspect }

obj RunContext {
    has config: LoadTestConfig;
    has entries: list[HarEntry];
    has accounts: list[Credential] = [];
    has rules: list[CorrelationRule] = [];
    has param_rules: list[ParamRule] = [];
    has baseline: dict[str, ResponseShape] = {};
    has topology: TopologyRouter | None = None;
    has poll_rules: dict[str, PollRule] = {};
    # >1 when this run is split across Locust worker processes.
    has worker_count: int = 1;
    # One-element lists because a module-level int cannot be rebound from a method.
    has next_vu: list[int] = [0];
    has warned_unrouted: list[str] = [];
    # Failed non-JSON responses, fingerprinted for the WAF/infra-block pass.
    has suspects: list[Suspect] = [];
    # Auth failures, reported after the run: (username, reason).
    has auth_failures: list[tuple[str, str]] = [];
}

glob CTX: list[RunContext] = [];

def set_context(ctx: RunContext) -> None {
    CTX.clear();
    CTX.append(ctx);
}

def get_context() -> RunContext {
    return CTX[0];
}

def next_vu_id(ctx: RunContext) -> int {
    vu = ctx.next_vu[0];
    ctx.next_vu[0] = vu + 1;
    return vu;
}
