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
import sys;
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
glob _ID_PATTERN: re.Pattern[str] = re.compile(r"^[A-Za-z0-9_:.\-+/=]+$");
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
    # "detected" (found in the HAR) or "explicit" (--correlate / x-jac-correlate).
    has origin: str = "explicit";

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

def _flatten(cursor: object, prefix: str, out: list[tuple[str, object]]) -> None {
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

def flatten_json(text: str | None) -> list[tuple[str, object]] {
    if not text {
        return [];
    }
    try {
        parsed = json.loads(text);
    } except Exception {
        return [];
    }
    out: list[tuple[str, object]] = [];
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

def detect_correlations(
    entries: list[HarEntry], notes: list[dict[str, any]] | None = None
) -> list[CorrelationRule] {
    # Find values a recorded response hands to a later recorded request.
    #
    # Reads only the HAR. For each entry's recorded response, index the id-like
    # scalars it contains, then look for those exact strings in the requests that
    # follow. A hit means the browser carried that value forward, which is the
    # behaviour the replay has to reproduce per-VU.
    #
    # A value can show up in several responses (a create call returns an id, and a
    # later list query returns it again). The producer is the earliest response
    # that carried it: that is where the browser first saw the value, so it is the
    # only response that can have been the source of a request that follows. When
    # more than one response carried the value the choice is recorded in `notes`,
    # so the user can see it and override it with --correlate.
    #
    rules: list[CorrelationRule] = [];
    seen: set = set();

    # Every response each value appears in, in recording order: (entry, path).
    producers_of: dict[str, list[tuple[int, str]]] = {};
    indexed: list[list[tuple[str, str]]] = [];
    for i in range(len(entries)) {
        har_entry = entries[i];
        pairs: list[tuple[str, str]] = [];
        if har_entry.protocol in ("http", "graphql") {
            pairs = [
                (path, str(value)) for (path, value) in flatten_json(har_entry.recorded_response)
                if is_id_like(value)
            ];
        }
        indexed.append(pairs);
        for (path, value) in pairs {
            found = producers_of.setdefault(value, []);
            if not any(entry_no == i for (entry_no, _p) in found) {
                found.append((i, path));
            }
        }
    }

    for i in range(len(entries)) {
        producer = entries[i];
        if producer.protocol not in ("http", "graphql") {
            continue;
        }
        producer_endpoint = _endpoint_of(producer);
        for (source_path, value) in indexed[i] {
            if producers_of[value][0][0] != i {
                continue;
            }
            consumers_seen: list[str] = [];
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
                consumers_seen.append(consumer_endpoint);
                rules.append(CorrelationRule(
                    producer=producer_endpoint,
                    source_path=source_path,
                    consumer=consumer_endpoint,
                    recorded_value=value,
                    name=f"{_short_name(producer_endpoint)}.{source_path}->{_short_name(consumer_endpoint)}",
                    origin="detected",
                ));
            }
            if notes is not None and consumers_seen and len(producers_of[value]) > 1 {
                notes.append({
                    "kind": "ambiguous_value",
                    "value": value[:12] + ("..." if len(value) > 12 else ""),
                    "producers": [
                        f"{_endpoint_of(entries[n])}:{p}" for (n, p) in producers_of[value]
                    ],
                    "chosen": f"{producer_endpoint}:{source_path}",
                    "consumers": consumers_seen,
                });
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
        if "." not in left {
            raise ValueError(
                f"--correlate rule must be '<producer>.<source-path> -> "
                f"<consumer>[.<target-path>]': {item!r}"
            );
        }
        (producer, source_path) = left.split(".", 1);
        if "." in right {
            (consumer, target_path) = right.split(".", 1);
        } else {
            # No target path: the rule relies entirely on literal-substring mode,
            # resolved from the HAR at build time (see build_rules). Valid only
            # when that resolution succeeds -- there is nothing to fall back to.
            (consumer, target_path) = (right, "");
        }
        if source_path.startswith("response.") {
            source_path = source_path[len("response."):];
        }
        if not source_path or not consumer {
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

def _lookup_path(flat: dict[str, str], path: str, resolve: any = None) -> str | None {
    # Which key of a flattened response `path` addresses. `resolve` is the
    # envelope-aware lookup from bridge/ (core/ must not import bridge/); without
    # one the match is literal.
    if resolve is not None {
        return resolve(flat, path);
    }
    return path if path in flat else None;
}

def _producer_values(
    entries: list[HarEntry], producer: str, source_path: str, resolve: any = None
) -> list[str] {
    # Every value recorded at `source_path` across all of `producer`'s occurrences,
    # in the order the HAR recorded them. Used to hydrate an explicit rule with the
    # same literal a detected rule would have carried, had detection been able to
    # attribute the value to a single producer.
    values: list[str] = [];
    for har_entry in entries {
        if har_entry.protocol not in ("http", "graphql") {
            continue;
        }
        if not endpoint_matches(producer, _endpoint_of(har_entry)) {
            continue;
        }
        flat = {path: str(value) for (path, value) in flatten_json(har_entry.recorded_response)};
        key = _lookup_path(flat, source_path, resolve);
        if key is not None {
            values.append(flat[key]);
        }
    }
    return values;
}

def hydrate_explicit_rule(
    entries: list[HarEntry], rule: CorrelationRule, announce: bool = True, resolve: any = None
) -> None {
    # Explicit (--correlate / x-jac-correlate) rules are parsed with no
    # recorded_value, which forces apply_correlations() into strict JSON-path-set
    # mode: an unconditional missing-check, and substitution that can only
    # overwrite a whole field. Detected rules don't have either problem because
    # they know the literal the recording used. Give explicit rules that same
    # literal, read straight out of the HAR, so they get the same conditional
    # missing-check and substring-anywhere substitution -- apply_correlations()
    # itself needs no changes for this.
    if rule.recorded_value is not None {
        return;
    }
    values = _producer_values(entries, rule.producer, rule.source_path, resolve);
    if not values {
        # Nothing to hydrate from -- most often the field is null/absent in the
        # recording. Fall back to strict mode, which needs a target path to work.
        if not rule.target_path {
            raise ValueError(
                f"--correlate rule {rule.label()!r} has no target path, and the "
                f"recording has no {rule.source_path!r} in {rule.producer!r}'s "
                "response to resolve a literal from -- add a target path "
                "(e.g. 'Consumer.body.field') so it can fall back to field-set mode"
            );
        }
        return;
    }

    distinct = sorted(set(values));
    first = values[0];
    if len(distinct) > 1 and announce {
        print(
            f"Correlation: {rule.producer}.{rule.source_path} produced "
            f"{len(distinct)} distinct values in the recording; {rule.label()} "
            f"will thread only the first ({first!r}) -- per-occurrence "
            "correlation across multiple values isn't supported yet.",
            file=sys.stderr,
        );
    }

    if is_id_like(first) {
        rule.recorded_value = first;
        return;
    }
    # The resolved literal is too short/generic to trust as a substring-replace
    # anchor (it could accidentally match unrelated text). Fall back to strict
    # mode rather than risk a wrong substitution.
    if not rule.target_path {
        raise ValueError(
            f"--correlate rule {rule.label()!r} resolved to {first!r}, which "
            "doesn't look like an id (too short or generic) and has no target "
            "path to fall back to -- add a target path (e.g. 'Consumer.body.field')"
        );
    }
    if announce {
        print(
            f"Correlation: {rule.producer}.{rule.source_path} resolved to "
            f"{first!r}, which doesn't look id-like; {rule.label()} will use "
            "exact field-set mode instead of substring replace.",
            file=sys.stderr,
        );
    }
}

glob _COUNT_FIELDS: tuple[str, str, str, str] = ("producer_runs", "captured", "applied", "missed");

obj CorrelationStats {
    # What each rule actually did during a run, keyed by rule label. Kept apart from
    # the per-VU CorrelationTable (which is reset every iteration) so the whole run
    # can be summarised, and as plain dicts so a worker can ship it to the master.
    #
    #   producer_runs  responses from the producer endpoint that got a status back
    #   captured       of those, how many yielded the rule's source value
    #   applied        consumer requests the captured value was injected into
    #   missed         consumer requests skipped because nothing had been captured
    has counts: dict[str, dict[str, int]] = {};

    def bump(label: str, field: str) -> None {
        row = self.counts.get(label);
        if row is None {
            row = {name: 0 for name in _COUNT_FIELDS};
            self.counts[label] = row;
        }
        row[field] = row[field] + 1;
    }

    def absorb(other: dict[str, dict[str, int]]) -> None {
        # Add another process's counts into this one.
        for (label, row) in other.items() {
            mine = self.counts.get(label);
            if mine is None {
                mine = {name: 0 for name in _COUNT_FIELDS};
                self.counts[label] = mine;
            }
            for name in _COUNT_FIELDS {
                mine[name] = mine[name] + int(row.get(name, 0));
            }
        }
    }
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

    def capture(
        rules: list[CorrelationRule], endpoint: str, body: bytes, headers: Mapping[str, str],
        resolve: any = None, stats: CorrelationStats | None = None
    ) -> None {
        relevant = [r for r in rules if endpoint_matches(r.producer, endpoint)];
        if not relevant {
            return;
        }
        flat: dict[str, str] | None = None;
        for rule in relevant {
            if stats is not None {
                stats.bump(rule.label(), "producer_runs");
            }
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
                    if stats is not None {
                        stats.bump(rule.label(), "captured");
                    }
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
            key = _lookup_path(flat, rule.source_path, resolve);
            if key is not None {
                self.values[rule.label()] = flat[key];
                if stats is not None {
                    stats.bump(rule.label(), "captured");
                }
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
    stats: CorrelationStats | None = None,
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
    if stats is not None {
        for label in applied {
            stats.bump(label, "applied");
        }
        for label in missing {
            stats.bump(label, "missed");
        }
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

def unresolved_rules(rules: list[CorrelationRule], stats: CorrelationStats) -> list[str] {
    # Labels of rules that never worked live, on either side:
    #   - the producer answered but the source value was never found (captured == 0),
    #     almost always envelope or schema drift; or
    #   - a value was captured but never injected while consumers were skipped
    #     (applied == 0, missed > 0): the rule's target is not in the request.
    # Only rules whose producer actually answered count. If it never ran (the run was
    # aborted, the endpoint was unroutable) a miss says nothing about the rule. A rule
    # that works sometimes and misses on iterations where the producer failed is
    # normal under load and is left to the per-rule counts in the report.
    out: list[str] = [];
    for rule in rules {
        row = stats.counts.get(rule.label());
        if row is None or row["producer_runs"] == 0 {
            continue;
        }
        if row["captured"] == 0 or (row["applied"] == 0 and row["missed"] > 0) {
            out.append(rule.label());
        }
    }
    return out;
}

def correlation_report(
    rules: list[CorrelationRule], stats: CorrelationStats, notes: list[dict[str, any]] | None = None
) -> dict[str, any] {
    # The per-rule outcome of a run, as plain data for the JSON report.
    rows: list[dict[str, any]] = [];
    for rule in rules {
        row = stats.counts.get(rule.label()) or {name: 0 for name in _COUNT_FIELDS};
        rows.append({
            "rule": rule.label(),
            "producer": rule.producer,
            "source_path": rule.source_path,
            "consumer": rule.consumer,
            "mode": "explicit-path" if rule.recorded_value is None else "literal",
            "producer_runs": row["producer_runs"],
            "captured": row["captured"],
            "applied": row["applied"],
            "missed": row["missed"],
        });
    }
    return {"rules": rows, "unresolved": unresolved_rules(rules, stats), "notes": list(notes or [])};
}

def describe_unresolved(corr: dict[str, any]) -> list[str] {
    # One warning line per rule that never captured, naming what it cost.
    by_rule = {row["rule"]: row for row in corr.get("rules", [])};
    lines: list[str] = [];
    for label in corr.get("unresolved", []) {
        row = by_rule.get(label, {});
        if row.get("captured", 0) > 0 {
            lines.append(
                f"correlation rule {label!r} captured {row.get('captured', 0)} value(s) but "
                f"never injected one, and {row.get('missed', 0)} request(s) were skipped as "
                "CORRELATION_MISS. The rule's target path was not found in the consumer "
                "request; check it against the consumer's body or URL."
            );
            continue;
        }
        lines.append(
            f"correlation rule {label!r} never captured a value: its producer "
            f"answered {row.get('producer_runs', 0)} time(s) but {row.get('source_path', '?')!r} "
            f"was never found, so {row.get('missed', 0)} request(s) were skipped as "
            "CORRELATION_MISS. This is usually a response envelope or schema change; "
            "check the rule's source path against a live response."
        );
    }
    return lines;
}

def describe_startup(rules: list[CorrelationRule], notes: list[dict[str, any]]) -> list[str] {
    # What the run is about to do, for the start of a run: the rules in force, and
    # every value that more than one recorded response carried, with the producer
    # chosen for it.
    lines: list[str] = [];
    if rules {
        detected = [r for r in rules if r.origin == "detected"];
        lines.append(
            f"Correlation: {len(rules)} rule(s) will thread each VU's own values "
            f"({len(detected)} detected, {len(rules) - len(detected)} explicit):"
        );
        lines.extend(describe_rules(rules).split("\n"));
        lines.append("  (disable detection with --no-auto-correlate; override with --correlate)");
    }
    for note in notes {
        if note.get("kind") != "ambiguous_value" {
            continue;
        }
        lines.append(
            f"Correlation: value {note['value']} appears in {len(note['producers'])} "
            f"recorded responses ({', '.join(note['producers'])}); threaded from "
            f"{note['chosen']}, the first one the client saw, into "
            f"{', '.join(_short_name(c) for c in note['consumers'])}. "
            "Pass --correlate to use a different source."
        );
    }
    return lines;
}

def describe_rules(rules: list[CorrelationRule]) -> str {
    lines = [];
    for rule in rules {
        source = (
            rule.source_path if rule.source_path.startswith("header.")
            else f"response.{rule.source_path}"
        );
        if rule.recorded_value is not None {
            target = "(matched value)";
            mode = "literal-substring";
        } else {
            target = rule.target_path or "(matched value)";
            mode = "json-path-set";
        }
        lines.append(
            f"  {_short_name(rule.producer)}.{source} -> {_short_name(rule.consumer)}.{target}"
            f"  [{mode}]"
        );
    }
    return "\n".join(lines);
}

def build_rules(
    entries: list[HarEntry],
    explicit: list[str] | None,
    auto_detect: bool,
    announce: bool = True,
    resolve: any = None,
    notes: list[dict[str, any]] | None = None,
) -> list[CorrelationRule] {
    # Single place that decides what correlation a run will do, so cli.jac and
    # headless.jac cannot drift apart.
    #
    # Precedence: explicit --correlate flags, then x-jac-correlate annotations in
    # the HAR, then anything detection proposes. A detected rule is dropped when
    # an explicit one already covers the same producer/consumer pair -- if
    # someone has stated what should happen between two endpoints, a heuristic
    # should not also fire on them.
    stated = parse_correlate_rules(explicit) + rules_from_har_annotations(entries);
    for rule in stated {
        hydrate_explicit_rule(entries, rule, announce=announce, resolve=resolve);
    }
    if announce and stated {
        hydrated = [r for r in stated if r.recorded_value is not None];
        if hydrated {
            print(
                f"\nCorrelation: {len(hydrated)} explicit rule(s) resolved to a "
                "recorded literal and will use substring replace:",
                file=sys.stderr,
            );
            print(describe_rules(hydrated), file=sys.stderr);
        }
    }
    rules = list(stated);
    if auto_detect {
        covered = {(r.producer, r.consumer) for r in stated};
        detected = [
            r for r in detect_correlations(entries, notes)
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
