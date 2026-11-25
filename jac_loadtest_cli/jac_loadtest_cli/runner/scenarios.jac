"""Explicit WebSocket and graphql-ws scenarios from config.

`ws_scenarios` / `graphql_scenarios` accept a JSON array (or its string form) of
scenario objects. Each becomes one extra HAR-style entry that every user replays
after the recorded flow on each iteration. A scenario's own `vus`, `iterations`
and `duration` no longer apply: Locust users all replay the whole flow, and the
run's --vus/--iterations/--duration govern.
"""

import json;
import from ..core.har_parser { HarEntry }

def _load(raw: any, label: str) -> list[dict[str, any]] {
    if not raw {
        return [];
    }
    if isinstance(raw, str) {
        try {
            parsed = json.loads(raw);
        } except json.JSONDecodeError as exc {
            raise ValueError(f"{label} is not valid JSON: {exc}") from exc;
        }
    } else {
        parsed = raw;
    }
    if not isinstance(parsed, list) {
        raise ValueError(f"{label} must be a JSON array of scenario objects");
    }
    return parsed;
}

def ws_scenario_entries(raw: any) -> list[HarEntry] {
    out: list[HarEntry] = [];
    for item in _load(raw, "ws_scenarios") {
        if not isinstance(item, dict) or not item.get("url") {
            raise ValueError("each ws scenario must be an object with a 'url' field");
        }
        out.append(HarEntry(
            method="GET", url=str(item["url"]), headers=dict(item.get("headers") or {}),
            body=None, body_mime=None, think_time_ms=float(item.get("think_time_ms", 0.0)),
            is_login=False, original_url=str(item["url"]), protocol="ws",
            ws_messages=[str(m) for m in (item.get("messages") or [])],
        ));
    }
    return out;
}

def graphql_scenario_entries(raw: any) -> list[HarEntry] {
    out: list[HarEntry] = [];
    for item in _load(raw, "graphql_scenarios") {
        if not isinstance(item, dict) or not item.get("url") or not item.get("query") {
            raise ValueError(
                "each graphql scenario must be an object with 'url' and 'query' fields"
            );
        }
        out.append(HarEntry(
            method="GET", url=str(item["url"]), headers=dict(item.get("headers") or {}),
            body=None, body_mime=None, think_time_ms=0.0, is_login=False,
            original_url=str(item["url"]), protocol="graphql_ws",
            graphql_query=str(item["query"]),
            graphql_variables=dict(item["variables"]) if item.get("variables") else None,
            graphql_operation_name=item.get("operation_name"),
        ));
    }
    return out;
}
