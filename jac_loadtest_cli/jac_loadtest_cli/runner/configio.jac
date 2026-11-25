"""Carry a LoadTestConfig across a process boundary as plain JSON.

Used for the subprocess runner (web app) and for Locust worker processes.
LoadTestConfig.from_dict drops None values, which would turn a duration-only run
(iterations=None) into a one-iteration run, so iterations is restored by hand.
"""

import json;
import from ..config { LoadTestConfig, BUILT_IN_DEFAULTS, _NON_BUILT_IN_DEFAULTS }

def config_to_dict(config: LoadTestConfig) -> dict[str, any] {
    keys = list(BUILT_IN_DEFAULTS.keys()) + list(_NON_BUILT_IN_DEFAULTS.keys());
    return {k: getattr(config, k, None) for k in keys};
}

def config_from_dict(raw: dict[str, any]) -> LoadTestConfig {
    cfg = LoadTestConfig.from_dict(raw);
    if "iterations" in raw {
        cfg.iterations = raw["iterations"];
    }
    return cfg;
}

def dump_config(config: LoadTestConfig, path: str) -> None {
    with open(path, "w") as f {
        json.dump(config_to_dict(config), f, `default=str);
    }
}

def load_config(path: str) -> LoadTestConfig {
    return config_from_dict(json.load(open(path)));
}
