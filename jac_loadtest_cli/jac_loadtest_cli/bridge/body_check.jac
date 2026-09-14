"""jac-scale response-body correctness — a 200 is not the same as a success.

Phase 8b. Status-code checking answers "is the server up?", not "is it correct
under load?". On jac-scale that gap is wide: walkers routinely return HTTP 200
with the failure inside the JSON body, so a run can report a 0% error rate while
every walker is refusing to do anything.

This lives in bridge/ because it encodes jac-scale's response envelope
specifically -- `reports`, and the error shapes its handlers produce. core/ stays
protocol-shaped and knows nothing about it.

Three signals, all read from a body that already came back 200:

  * an `error` / `errors` key carrying something
  * an inner `status` of 400 or more, i.e. the envelope reporting a failure the
    transport did not
  * an empty `reports` array where the *recording* for that same endpoint had a
    non-empty one -- the walker ran and produced nothing, which is invisible to
    status checking and is what a broken query under load actually looks like

The third is why HarEntry.recorded_response exists beyond correlation: it is a
per-endpoint baseline the tool already has, with no extra run needed.

Deliberately conservative. A body that is not JSON, or that carries none of these
markers, is left alone -- this flags responses that say they failed, not
responses that merely look unfamiliar. Shape drift is a separate, softer signal.
"""

import json;

glob APP_ERROR: str = "APP_ERROR_IN_200";
glob SHAPE_DRIFT: str = "SHAPE_DRIFT";


obj ResponseShape {
    # What a recorded response looked like, reduced to the parts worth comparing.
    has keys: list = [];
    has reports_non_empty: bool = False;
    has parsed: bool = False;
}

def shape_of(text: str | None) -> ResponseShape {
    if not text {
        return ResponseShape();
    }
    try {
        body = json.loads(text);
    } except Exception {
        return ResponseShape();
    }
    if not isinstance(body, dict) {
        return ResponseShape(parsed=True);
    }
    reports = body.get("reports");
    return ResponseShape(
        keys=sorted(str(k) for k in body.keys()),
        reports_non_empty=isinstance(reports, list) and len(reports) > 0,
        parsed=True,
    );
}

def baseline_shapes(entries: list) -> dict {
    # endpoint -> ResponseShape, taken from the HAR. Only entries whose recorded
    # response actually parsed contribute; an endpoint recorded without a body
    # simply has no baseline and is never compared.
    import from urllib.parse { urlparse }
    out: dict = {};
    for item in entries {
        shape = shape_of(item.recorded_response);
        if not shape.parsed {
            continue;
        }
        endpoint = urlparse(item.url).path;
        if endpoint not in out {
            out[endpoint] = shape;
        }
    }
    return out;
}


def _inner_status(body: dict) -> int | None {
    value = body.get("status");
    if isinstance(value, bool) {
        return None;
    }
    if isinstance(value, int) {
        return value;
    }
    if isinstance(value, str) and value.isdigit() {
        return int(value);
    }
    return None;
}

def check_body(
    raw: bytes, baseline: ResponseShape | None
) -> str | None {
    # Returns an error_type when the body reports a failure the status did not,
    # else None. Called only for responses that already matched their expected
    # status -- a status mismatch is a failure on its own, and stacking a second
    # unrelated reason on top of it would just be noise.
    try {
        text = raw.decode("utf-8", errors="replace");
    } except Exception {
        return None;
    }
    if not text.strip() {
        return None;
    }
    try {
        body = json.loads(text);
    } except Exception {
        # Not JSON. Could be an infrastructure deny page; that is 8a's job to
        # classify across endpoints, not something to guess at from one response.
        return None;
    }
    if not isinstance(body, dict) {
        return None;
    }

    for key in ("error", "errors") {
        value = body.get(key);
        if value {
            return f"{APP_ERROR}: '{key}' in a {200} response";
        }
    }

    inner = _inner_status(body);
    if inner is not None and inner >= 400 {
        return f"{APP_ERROR}: inner status {inner}";
    }

    reports = body.get("reports");
    if (
        isinstance(reports, list)
        and len(reports) == 0
        and baseline is not None
        and baseline.reports_non_empty
    ) {
        # The walker returned nothing where the recording got results. Invisible
        # to a status check, and exactly what a query failing under load looks
        # like.
        return f"{APP_ERROR}: empty 'reports' (recording had results)";
    }

    return None;
}

def check_shape(raw: bytes, baseline: ResponseShape | None) -> str | None {
    # Softer than check_body: the response did not say it failed, it just does
    # not look like what was recorded. Reported as a warning class rather than
    # counted against the error rate unless the user opts in.
    if baseline is None or not baseline.parsed or not baseline.keys {
        return None;
    }
    try {
        live = shape_of(raw.decode("utf-8", errors="replace"));
    } except Exception {
        return None;
    }
    if not live.parsed or not live.keys {
        return None;
    }
    missing = [k for k in baseline.keys if k not in live.keys];
    if missing {
        return f"{SHAPE_DRIFT}: missing key(s) {','.join(missing[:3])}";
    }
    return None;
}
