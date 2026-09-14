"""Response correlation — thread each VU's own server-generated IDs through a replay.

The problem (CONSTRAINTS.md section 1): a HAR records one user's session, and any
request that operates on an existing object carries a server-generated ID captured
at record time. Replayed as-is, that ID belongs to the recording user's data and to
a row that may no longer exist, so every mixed create -> update -> delete workflow
fails its ownership check. Rotating credentials does not help: the ID is in the
request body, not the token.

The fix is to notice at runtime that `AddTodo` returned an id, and to substitute
*that* id into the `ToggleTodo` that follows — separately for every VU, so VU 3
toggles the todo VU 3 just created.

Two ways a rule gets here:

1. **Detected from the HAR** (default). The recording already contains the answer:
   a value that appears in one response and reappears in a later request is, by
   construction, a value the client copied forward. detect_correlations() finds
   those pairs by reading the file — no baseline run against the server, no extra
   round trip, so it is cheap enough to do on every startup rather than hiding it
   behind a separate scan command.

2. **Stated explicitly** via --correlate, or per-entry in the HAR via an
   `x-jac-correlate` annotation, for the cases detection cannot see — most often a
   value that the recording happens to use only once, so there is no second
   occurrence to match against.

Detected and explicit rules differ in how they inject, and deliberately so.
A detected rule knows the literal value the recording used, so it can replace that
exact string wherever it appears — body, query string, or URL path — without
having to model where in the request it sits. An explicit rule has no recorded
value to anchor to, so it addresses its target by path.
"""

import json;
import re;
import from .har_parser { HarEntry }

# A value has to look like a server-generated identifier before it is worth
# threading. The risk being managed is a false positive: correlating something
# that merely happens to repeat (a status string, a page size, a label) would
# silently send different data than the recording did, which is worse than not
# correlating at all. These bounds are deliberately conservative -- a missed
# correlation is visible as a 404 the user can fix with --correlate, while a
# wrong one is invisible.
glob _MIN_VALUE_LEN: int = 8;
glob _MAX_VALUE_LEN: int = 512;
glob _ID_PATTERN: object = re.compile(r"^[A-Za-z0-9_:.\-+/=]+$");
# Values that are long enough to pass the length test but carry no identity.
glob _STOPWORDS: set[str] = {
    "undefined", "anonymous", "localhost", "application/json", "text/html",
    "successful", "completed", "requested", "unchanged",
};

obj CorrelationRule {
    # Endpoint that produces the value, as a normalized path ("/walker/AddTodo").
    has producer: str;
    # Dotted path into the producer's JSON response ("reports.0.id"), or
    # "header.<name>" to read a response header instead.
    has source_path: str;
    # Endpoint that consumes it.
    has consumer: str;
    # Dotted path into the consumer's request ("body.nd", "query.id"), or "" when
    # the rule carries a recorded_value and substitutes by literal match instead.
    has target_path: str = "";
    # The literal string the recording used. Present on detected rules, absent on
    # explicit ones. When present, injection is a literal substitution across the
    # whole request, which is both simpler and more robust than path surgery.
    has recorded_value: str | None = None;
    # Stable name for debug output and RequestResult.correlation_applied.
    has name: str = "";

    def label() -> str {
        if self.name {
            return self.name;
        }
        return f"{self.producer}.{self.source_path}->{self.consumer}";
    }
}

def _endpoint_of(har_entry: HarEntry) -> str {
    import from urllib.parse { urlparse }
    return urlparse(har_entry.url).path or har_entry.url;
}

def _short_name(endpoint: str) -> str {
    # "/walker/AddTodo" -> "AddTodo". Lets --correlate use the walker name alone,
    # which is how people refer to these endpoints, while still matching on the
    # full path internally.
    parts = [p for p in endpoint.split("/") if p];
    return parts[-1] if parts else endpoint;
}

def endpoint_matches(rule_side: str, endpoint: str) -> bool {
    # A rule may name an endpoint either fully ("/walker/AddTodo") or by its last
    # segment ("AddTodo").
    if not rule_side {
        return False;
    }
    if rule_side == endpoint {
        return True;
    }
    return rule_side == _short_name(endpoint);
}

def _flatten(cursor: object, prefix: str, out: list) -> None {
    # Walk a parsed JSON document into (dotted-path, scalar-value) pairs.
    if isinstance(cursor, dict) {
        for (key, value) in cursor.items() {
            child = f"{prefix}.{key}" if prefix else str(key);
            _flatten(value, child, out);
        }
    } elif isinstance(cursor, list) {
        for (i, value) in enumerate(cursor) {
            child = f"{prefix}.{i}" if prefix else str(i);
            _flatten(value, child, out);
        }
    } else {
        out.append((prefix, cursor));
    }
}

def flatten_json(text: str | None) -> list {
    if not text {
        return [];
    }
    try {
        parsed = json.loads(text);
    } except Exception {
        return [];
    }
    out: list = [];
    _flatten(parsed, "", out);
    return out;
}

def is_id_like(value: object) -> bool {
    # Booleans are checked before numbers on purpose: in Python `True` is an int,
    # and every bool would otherwise slip through the numeric branch.
    if isinstance(value, bool) or value is None {
        return False;
    }
    if isinstance(value, (int, float)) {
        # A small integer is far more likely to be a count, an index, a status or
        # a page size than an identifier worth threading.
        return isinstance(value, int) and abs(value) >= 10_000;
    }
    if not isinstance(value, str) {
        return False;
    }
    text = value.strip();
    if len(text) < _MIN_VALUE_LEN or len(text) > _MAX_VALUE_LEN {
        return False;
    }
    if text.lower() in _STOPWORDS {
        return False;
    }
    if " " in text {
        # Prose, not an identifier.
        return False;
    }
    if not _ID_PATTERN.match(text) {
        return False;
    }
    # Require some digit or separator content: a long lowercase word ("processing")
    # is the shape of a status, not of an id.
    return any(ch.isdigit() for ch in text) or "-" in text or "_" in text or ":" in text;
}

def _request_surface(har_entry: HarEntry) -> str {
    # Everything a recorded value could have been copied into: the body, and the
    # URL (which covers both path segments and query-string values). Searched as
    # one string so a detected rule does not need to know which of the three it is.
    return f"{har_entry.body or ''}\n{har_entry.url}";
}

def detect_correlations(entries: list[HarEntry]) -> list[CorrelationRule] {
    # Find values a recorded response hands to a later recorded request.
    #
    # Reads only the HAR. For each entry's recorded response, index the id-like
    # scalars it contains, then look for those exact strings in the requests that
    # follow. A hit means the browser carried that value forward, which is the
    # behaviour the replay has to reproduce per-VU.
    #
    rules: list[CorrelationRule] = [];
    seen: set = set();

    # How many distinct responses each value appears in. A value produced in
    # several places is ambiguous -- there is no single producer to attribute it
    # to -- so it is skipped rather than guessed at.
    producers_by_value: dict[str, int] = {};
    indexed: list = [];
    for har_entry in entries {
        pairs = [
            (path, str(value)) for (path, value) in flatten_json(har_entry.recorded_response)
            if is_id_like(value)
        ];
        indexed.append(pairs);
        for (_path, value) in set(pairs) {
            producers_by_value[value] = producers_by_value.get(value, 0) + 1;
        }
    }

    for i in range(len(entries)) {
        producer = entries[i];
        if producer.protocol not in ("http", "graphql") {
            continue;
        }
        producer_endpoint = _endpoint_of(producer);
        for (source_path, value) in indexed[i] {
            if producers_by_value.get(value, 0) != 1 {
                continue;
            }
            for j in range(i + 1, len(entries)) {
                consumer = entries[j];
                if consumer.protocol not in ("http", "graphql") {
                    continue;
                }
                if value not in _request_surface(consumer) {
                    continue;
                }
                consumer_endpoint = _endpoint_of(consumer);
                key = (producer_endpoint, source_path, consumer_endpoint, value);
                if key in seen {
                    continue;
                }
                seen.add(key);
                rules.append(CorrelationRule(
                    producer=producer_endpoint,
                    source_path=source_path,
                    consumer=consumer_endpoint,
                    recorded_value=value,
                    name=f"{_short_name(producer_endpoint)}.{source_path}->{_short_name(consumer_endpoint)}",
                ));
            }
        }
    }
    return rules;
}

def parse_correlate_rules(raw: list[str] | None) -> list[CorrelationRule] {
    # Parse --correlate "Producer.response.a.b -> Consumer.body.c" strings.
    if not raw {
        return [];
    }
    rules: list[CorrelationRule] = [];
    for item in raw {
        text = str(item).strip();
        if "->" not in text {
            raise ValueError(
                f"--correlate rule must contain '->' separating source and target: {item!r}"
            );
        }
        (left, right) = [side.strip() for side in text.split("->", 1)];
        if "." not in left or "." not in right {
            raise ValueError(
                f"--correlate rule must be '<producer>.<source-path> -> "
                f"<consumer>.<target-path>': {item!r}"
            );
        }
        (producer, source_path) = left.split(".", 1);
        (consumer, target_path) = right.split(".", 1);
        if source_path.startswith("response.") {
            source_path = source_path[len("response."):];
        }
        if not source_path or not target_path {
            raise ValueError(f"--correlate rule has an empty path: {item!r}");
        }
        rules.append(CorrelationRule(
            producer=producer.strip(),
            source_path=source_path.strip(),
            consumer=consumer.strip(),
            target_path=target_path.strip(),
            name=text,
        ));
    }
    return rules;
}

def rules_from_har_annotations(entries: list[HarEntry]) -> list[CorrelationRule] {
    # x-jac-correlate lets a team annotate a HAR once and commit it, instead of
    # passing the same --correlate flags on every run.
    annotations: list[str] = [];
    for har_entry in entries {
        for item in har_entry.correlate_annotations {
            annotations.append(item);
        }
    }
    return parse_correlate_rules(annotations);
}

obj CorrelationTable {
    # One VU's view of the values it has seen this iteration.
    #
    # Per VU because the whole point is that VU 3 threads VU 3's ids; per iteration
    # because iteration 2 creates a fresh object and must operate on that one, not
    # on the one iteration 1 made.
    #
    has values: dict[str, str] = {};

    def reset() -> None {
        self.values = {};
    }

    def capture(rules: list[CorrelationRule], endpoint: str, body: bytes, headers: object) -> None {
        relevant = [r for r in rules if endpoint_matches(r.producer, endpoint)];
        if not relevant {
            return;
        }
        flat: dict[str, str] | None = None;
        for rule in relevant {
            if rule.source_path.startswith("header.") {
                header_name = rule.source_path[len("header."):];
                found = None;
                try {
                    found = headers.get(header_name);
                } except Exception {
                    found = None;
                }
                if found {
                    self.values[rule.label()] = str(found);
                }
                continue;
            }
            if flat is None {
                try {
                    text = body.decode("utf-8", errors="replace");
                } except Exception {
                    text = "";
                }
                flat = {path: str(value) for (path, value) in flatten_json(text)};
            }
            if rule.source_path in flat {
                self.values[rule.label()] = flat[rule.source_path];
            }
        }
    }
}

def _set_json_path(doc: object, path: str, value: str) -> bool {
    # Walk to the parent of `path` and set the leaf. Returns False when the path
    # does not exist rather than creating it: a rule that no longer matches the
    # payload is a mistake worth surfacing, not something to paper over by
    # inventing a field the server never expects.
    parts = path.split(".");
    cursor = doc;
    for part in parts[:-1] {
        if isinstance(cursor, list) {
            try {
                cursor = cursor[int(part)];
            } except Exception {
                return False;
            }
        } elif isinstance(cursor, dict) {
            if part not in cursor {
                return False;
            }
            cursor = cursor[part];
        } else {
            return False;
        }
    }
    leaf = parts[-1];
    if isinstance(cursor, list) {
        try {
            cursor[int(leaf)] = value;
            return True;
        } except Exception {
            return False;
        }
    }
    if isinstance(cursor, dict) and leaf in cursor {
        cursor[leaf] = value;
        return True;
    }
    return False;
}

obj CorrelationOutcome {
    has url: str;
    has body: str | None;
    has applied: list[str] = [];
    # Set when a rule should have fired but its value was never captured -- the
    # producing request failed, or returned a different shape. The caller fails
    # the request with this rather than sending the recording's stale id, which
    # would otherwise show up as a puzzling 404 attributed to the application.
    has missing: list[str] = [];
}

def apply_correlations(
    rules: list[CorrelationRule],
    table: CorrelationTable,
    endpoint: str,
    url: str,
    body: str | None,
) -> CorrelationOutcome {
    relevant = [r for r in rules if endpoint_matches(r.consumer, endpoint)];
    if not relevant {
        return CorrelationOutcome(url=url, body=body);
    }

    new_url = url;
    new_body = body;
    applied: list[str] = [];
    missing: list[str] = [];
    parsed_body: object = None;
    body_dirty = False;

    for rule in relevant {
        label = rule.label();
        replacement = table.values.get(label);
        if replacement is None {
            # Only a miss if this rule's producer actually ran and should have
            # supplied it; a rule whose recorded value is absent from this request
            # simply does not apply here.
            if rule.recorded_value is None or rule.recorded_value in f"{new_body or ''}\n{new_url}" {
                missing.append(label);
            }
            continue;
        }

        if rule.recorded_value is not None {
            # Detected rule: swap the literal the recording used, wherever it sits.
            hit = False;
            if new_body and rule.recorded_value in new_body {
                new_body = new_body.replace(rule.recorded_value, replacement);
                hit = True;
            }
            if rule.recorded_value in new_url {
                new_url = new_url.replace(rule.recorded_value, replacement);
                hit = True;
            }
            if hit {
                applied.append(label);
            }
            continue;
        }

        # Explicit rule: address the target by path.
        target = rule.target_path;
        if target.startswith("query.") {
            param = target[len("query."):];
            new_url = _replace_query_param(new_url, param, replacement);
            applied.append(label);
            continue;
        }
        if target.startswith("body.") or target == "body" {
            json_path = target[len("body."):] if target.startswith("body.") else "";
            if parsed_body is None and new_body {
                try {
                    parsed_body = json.loads(new_body);
                } except Exception {
                    parsed_body = None;
                }
            }
            if parsed_body is not None and json_path and _set_json_path(parsed_body, json_path, replacement) {
                body_dirty = True;
                applied.append(label);
            } else {
                missing.append(label);
            }
            continue;
        }
        if target == "path" {
            # No recorded value to anchor to, so the only safe reading of "path"
            # is "replace the last segment".
            (head, _sep, _tail) = new_url.rpartition("/");
            new_url = f"{head}/{replacement}";
            applied.append(label);
            continue;
        }
        missing.append(label);
    }

    if body_dirty and parsed_body is not None {
        new_body = json.dumps(parsed_body);
    }
    return CorrelationOutcome(url=new_url, body=new_body, applied=applied, missing=missing);
}

def _replace_query_param(url: str, param: str, value: str) -> str {
    import from urllib.parse { urlparse, urlencode, parse_qsl, urlunparse }
    parts = urlparse(url);
    pairs = parse_qsl(parts.query, keep_blank_values=True);
    replaced = False;
    out = [];
    for (key, existing) in pairs {
        if key == param {
            out.append((key, value));
            replaced = True;
        } else {
            out.append((key, existing));
        }
    }
    if not replaced {
        out.append((param, value));
    }
    return urlunparse(parts._replace(query=urlencode(out)));
}

def describe_rules(rules: list[CorrelationRule]) -> str {
    lines = [];
    for rule in rules {
        source = (
            rule.source_path if rule.source_path.startswith("header.")
            else f"response.{rule.source_path}"
        );
        target = rule.target_path or "(matched value)";
        lines.append(
            f"  {_short_name(rule.producer)}.{source} -> {_short_name(rule.consumer)}.{target}"
        );
    }
    return "\n".join(lines);
}

def build_rules(
    entries: list[HarEntry],
    explicit: list[str] | None,
    auto_detect: bool,
    announce: bool = True,
) -> list[CorrelationRule] {
    # Single place that decides what correlation a run will do, so cli.jac and
    # headless.jac cannot drift apart.
    #
    # Precedence: explicit --correlate flags, then x-jac-correlate annotations in
    # the HAR, then anything detection proposes. A detected rule is dropped when
    # an explicit one already covers the same producer/consumer pair -- if
    # someone has stated what should happen between two endpoints, a heuristic
    # should not also fire on them.
    import sys;
    stated = parse_correlate_rules(explicit) + rules_from_har_annotations(entries);
    rules = list(stated);
    if auto_detect {
        covered = {(r.producer, r.consumer) for r in stated};
        detected = [
            r for r in detect_correlations(entries)
            if (r.producer, r.consumer) not in covered
        ];
        rules += detected;
        if announce and detected {
            print(
                f"\nCorrelation: {len(detected)} value(s) detected in the recording "
                "and threaded per-VU:",
                file=sys.stderr,
            );
            print(describe_rules(detected), file=sys.stderr);
            print(
                "  (disable with --no-auto-correlate; override with --correlate)\n",
                file=sys.stderr,
            );
        }
    }
    return rules;
}
