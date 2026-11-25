"""Telling a WAF's deny page apart from the application failing.

A deny page is *the same page everywhere*: an application failure is specific to
what was asked, while a WAF, gateway rate limiter or CDN bot filter answers with
one canned non-JSON body across unrelated endpoints at the same moment. So users
fingerprint the non-JSON body of every failed response as it happens, and after
the run any fingerprint seen on at least N distinct endpoints inside one time
bucket is classified as an infrastructure block (INFRA_BLOCK_SUSPECTED).

It cannot be decided per request, because no single response carries the
evidence. Nothing is discarded: the report counts blocked responses separately
and leaves them out of the error rate.
"""

import hashlib;

glob INFRA_BLOCK: str = "INFRA_BLOCK_SUSPECTED";
# Wide enough that a blocked burst lands together, narrow enough that unrelated
# failures hours apart are not read as one event.
glob BUCKET_SECONDS: float = 10.0;

obj Suspect {
    has timestamp: float;
    has endpoint: str;
    has fingerprint: str;
}

def body_fingerprint(body: bytes) -> str | None {
    # Only non-JSON bodies: a JSON body is the application answering, even when
    # it is an error.
    if not body {
        return None;
    }
    head = body.lstrip()[:1];
    if head in (b"{", b"[") {
        return None;
    }
    return hashlib.sha256(body[:2048]).hexdigest()[:16];
}

def blocked_keys(suspects: list[Suspect], threshold: int, t_start: float) -> set[tuple[int, str]] {
    # A threshold below 2 disables the check: "identical across >= 1 endpoint" is
    # every repeated error, which would swallow real application failures.
    if threshold < 2 or not suspects {
        return set();
    }
    seen: dict[tuple[int, str], set[str]] = {};
    for s in suspects {
        key = (int((s.timestamp - t_start) // BUCKET_SECONDS), s.fingerprint);
        if key not in seen {
            seen[key] = set();
        }
        seen[key].add(s.endpoint);
    }
    return {key for (key, endpoints) in seen.items() if len(endpoints) >= threshold};
}

def blocks_per_endpoint(suspects: list[Suspect], threshold: int, t_start: float) -> dict[str, int] {
    keys = blocked_keys(suspects, threshold, t_start);
    out: dict[str, int] = {};
    if not keys {
        return out;
    }
    for s in suspects {
        key = (int((s.timestamp - t_start) // BUCKET_SECONDS), s.fingerprint);
        if key in keys {
            out[s.endpoint] = out.get(s.endpoint, 0) + 1;
        }
    }
    return out;
}
