"""Unit tests for core/infra_block.jac — telling a deny page from an app failure."""

import os;
import tempfile;
import from jac_loadtest_cli.core.infra_block {
    BUCKET_SECONDS, body_fingerprint, classify, is_infra_block, load_proxies, proxy_for
}
import from jac_loadtest_cli.core.metrics { RequestResult }

glob DENY: bytes = b"<html><body>403 Forbidden - request blocked</body></html>";


def _sample(
    endpoint: str, status: int = 403, offset: float = 0.0,
    body: bytes | None = None, error: str | None = None
) -> RequestResult {
    return RequestResult(
        endpoint=endpoint, service="monolith", status=status, latency_ms=5.0,
        bytes_received=10, timestamp=1000.0 + offset, vu_id=0,
        error_type=error, expected_status=200,
        body_hash=body_fingerprint(body if body is not None else DENY),
    );
}


# ---------------------------------------------------------------------------
# body_fingerprint
# ---------------------------------------------------------------------------

test "only non-JSON bodies are fingerprinted" {
    # A JSON error is the application talking; a gateway does not speak the
    # app's envelope, so JSON is never a candidate.
    assert body_fingerprint(b'{"error":"nope"}') is None;
    assert body_fingerprint(b'[1,2]') is None;
    assert body_fingerprint(b"") is None;
    assert body_fingerprint(DENY) is not None;
}

test "identical bodies share a fingerprint and different ones do not" {
    assert body_fingerprint(DENY) == body_fingerprint(DENY);
    assert body_fingerprint(DENY) != body_fingerprint(b"<html>different</html>");
}

test "leading whitespace does not hide a JSON body" {
    assert body_fingerprint(b'  \n {"a":1}') is None;
}


# ---------------------------------------------------------------------------
# classify
# ---------------------------------------------------------------------------

test "one page across enough endpoints is classified as an infrastructure block" {
    samples = [_sample(f"/walker/{name}") for name in ["A", "B", "C"]];
    assert classify(samples, 3, 1000.0) == 3;
    for s in samples {
        assert is_infra_block(s.error_type);
    }
}

test "the same page on too few endpoints is left as an application error" {
    # One endpoint repeatedly returning the same HTML error is plausibly the
    # application. Reclassifying it would hide a real failure.
    samples = [_sample("/walker/A"), _sample("/walker/A"), _sample("/walker/A")];
    assert classify(samples, 3, 1000.0) == 0;
    for s in samples {
        assert not is_infra_block(s.error_type);
    }
}

test "blocks are only grouped within the same time bucket" {
    # Unrelated failures far apart are not one event.
    far = BUCKET_SECONDS * 5;
    samples = [
        _sample("/walker/A", offset=0.0),
        _sample("/walker/B", offset=0.0),
        _sample("/walker/C", offset=far),
    ];
    assert classify(samples, 3, 1000.0) == 0;
}

test "a genuine application failure alongside blocks keeps its own error" {
    # The case that matters: the run must not lose a real 500 just because a WAF
    # was also active.
    app_error = RequestResult(
        endpoint="/walker/Broken", service="monolith", status=500, latency_ms=5.0,
        bytes_received=10, timestamp=1000.0, vu_id=0, error_type=None,
        expected_status=200, body_hash=body_fingerprint(b'{"error":"boom"}'),
    );
    samples = [
        _sample("/walker/A"), _sample("/walker/B"), _sample("/walker/C"), app_error
    ];
    assert classify(samples, 3, 1000.0) == 3;
    assert not is_infra_block(app_error.error_type);
    assert app_error.error_type is None;
}

test "successful responses are never reclassified" {
    ok = _sample("/walker/A", status=200);
    samples = [ok, _sample("/walker/B"), _sample("/walker/C"), _sample("/walker/D")];
    classify(samples, 3, 1000.0);
    assert not is_infra_block(ok.error_type);
}

test "a threshold below two disables the check" {
    # "identical across >= 1 endpoint" is every repeated error, which would
    # swallow real application failures.
    samples = [_sample(f"/walker/{n}") for n in ["A", "B", "C"]];
    assert classify(samples, 1, 1000.0) == 0;
    assert classify(samples, 0, 1000.0) == 0;
}

test "classify copes with an empty run" {
    assert classify([], 3, 1000.0) == 0;
}

test "a higher threshold needs more endpoints before flagging" {
    samples = [_sample(f"/walker/{n}") for n in ["A", "B", "C"]];
    assert classify(samples, 5, 1000.0) == 0;
    assert classify(samples, 3, 1000.0) == 3;
}


# ---------------------------------------------------------------------------
# proxy pool
# ---------------------------------------------------------------------------

def _write(content: str) -> str {
    handle = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8");
    handle.write(content);
    handle.close();
    return handle.name;
}

test "load_proxies reads entries and ignores comments and blanks" {
    path = _write("# egress pool\nhttp://a:8080\n\nsocks5://b:1080\n");
    try {
        assert load_proxies(path) == ["http://a:8080", "socks5://b:1080"];
    } finally {
        os.unlink(path);
    }
}

test "load_proxies rejects a missing scheme, file or content" {
    path = _write("a:8080\n");
    try {
        raised = False;
        try {
            load_proxies(path);
        } except ValueError as exc {
            raised = True;
            assert "scheme" in str(exc);
        }
        assert raised;
    } finally {
        os.unlink(path);
    }

    empty = _write("# only a comment\n");
    try {
        raised = False;
        try {
            load_proxies(empty);
        } except ValueError {
            raised = True;
        }
        assert raised;
    } finally {
        os.unlink(empty);
    }

    raised = False;
    try {
        load_proxies("/definitely/not/here.txt");
    } except ValueError as exc {
        raised = True;
        assert "not found" in str(exc);
    }
    assert raised;
    assert load_proxies(None) == [];
}

test "proxies are assigned per VU so a session keeps one egress address" {
    # Rotating mid-session would break keep-alive and distort the latency the
    # run is trying to measure.
    pool = ["http://a", "http://b"];
    assert [proxy_for(pool, i) for i in range(4)] == [
        "http://a", "http://b", "http://a", "http://b"
    ];
    assert proxy_for([], 0) is None;
}
