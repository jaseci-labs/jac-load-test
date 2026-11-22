"""Builds and drives a Locust run in-process.

This is the only module that creates a Locust Environment. It parses the HAR,
builds the RunContext, starts a local runner, waits for the run to end (every
user finished its iterations, the duration elapsed, or the stop signal fired),
and returns the Environment so the output layer can read Locust's own stats.

Locust monkey-patches the standard library with gevent when it is imported, so
this package must never be imported by code that has to stay on plain asyncio.
"""

import time;
import gevent;
import from urllib.parse { urlparse }
import from locust.env { Environment }
import from ..config { LoadTestConfig, parse_duration }
import from ..core.har_parser { parse_har, HarEntry }
import from ..core.correlation { build_rules }
import from ..core.parameterize { parse_param_rules }
import from ..bridge.auth { parse_accounts, Credential }
import from ..bridge.body_check { baseline_shapes }
import from ..bridge.topology { TopologyRouter }
import from .context { RunContext, set_context }
import from .users { HarUser }

obj RunHandle {
    has env: any;
    has context: RunContext;
    has wall_s: float = 0.0;
}

def _origin(url: str) -> str {
    p = urlparse(url);
    return f"{p.scheme}://{p.netloc}";
}

def build_context(config: LoadTestConfig) -> RunContext {
    if not config.har_file {
        raise ValueError("har_file is required");
    }
    if config.har_file and config.mode == "monolith" and not config.url {
        raise ValueError("url is required for monolith mode");
    }
    all_entries = parse_har(
        config.har_file,
        target_url=config.url if config.mode == "monolith" else None,
        include_static=config.include_static,
        login_path=config.login_path,
    );
    if not all_entries {
        raise ValueError(
            "no API entries found after filtering; "
            "set include_static=True to include static assets"
        );
    }
    entries = [e for e in all_entries if e.protocol in ("http", "graphql")];
    accounts = parse_accounts(config.accounts);
    if not accounts and config.username and config.password {
        accounts = [Credential(username=config.username, password=config.password)];
    }
    if config.mode == "microservice" and accounts and not config.url {
        raise ValueError(
            "url (gateway URL) is required when using authentication in microservice mode"
        );
    }
    return RunContext(
        config=config,
        entries=entries,
        accounts=accounts,
        rules=build_rules(all_entries, config.correlate, config.auto_correlate, announce=False),
        param_rules=parse_param_rules(config.param),
        baseline=baseline_shapes(entries),
        topology=TopologyRouter.from_config(config),
    );
}

def run_locust(config: LoadTestConfig, stop_event: any = None) -> RunHandle {
    ctx = build_context(config);
    set_context(ctx);

    timeout_s = parse_duration(config.timeout);
    setattr(HarUser, "network_timeout", timeout_s);
    setattr(HarUser, "connection_timeout", timeout_s);

    host = config.url or _origin(ctx.entries[0].url);
    env = Environment(user_classes=[HarUser], host=host);
    runner = env.create_local_runner();

    ramp_s = parse_duration(config.ramp_up) if config.ramp_up else 0.0;
    spawn_rate = float(config.vus) / ramp_s if ramp_s > 0 else float(config.vus);

    t0 = time.time();
    runner.start(config.vus, spawn_rate=spawn_rate);
    deadline = t0 + parse_duration(config.duration) if config.duration else None;

    # Give the spawner a moment to create the first users before watching
    # user_count; "spawning" covers the ramp.
    gevent.sleep(0.2);
    while runner.state == "spawning" or runner.user_count > 0 {
        if deadline is not None and time.time() >= deadline {
            break;
        }
        if stop_event is not None and stop_event.is_set() {
            break;
        }
        gevent.sleep(0.1);
    }
    runner.quit();
    return RunHandle(env=env, context=ctx, wall_s=time.time() - t0);
}
