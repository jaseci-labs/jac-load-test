"""Telling a WAF's deny page apart from the application failing.

Phase 8a (issue #24). Every VU egresses from one network interface, so the
target sees hundreds of requests per second from a single IP. Behind a WAF, an
API gateway rate limiter, or a CDN bot filter, that trips a control and a
fraction of requests come back as an identical non-JSON deny page -- typically
403 or 429 with an HTML body.

Counted naively, those land as per-endpoint application errors, and the run then
reports a failure the application never saw: the headline error rate is inflated,
the per-endpoint breakdown blames whichever endpoints happened to get blocked,
and their p95 is skewed by the fast deny response. The run looks like an app
problem when the generator tripped a network control.

The signal that separates them is that a deny page is *the same page everywhere*.
An application failure is specific to what was asked -- different endpoints fail
differently, and the bodies differ. Infrastructure does not care what you asked
for: it returns one canned page across unrelated endpoints at the same moment.

So: hash the non-JSON bodies of failed responses, bucket by time, and flag a hash
that appears across at least N distinct endpoints in the same bucket. One
endpoint returning the same HTML error repeatedly is left alone -- that is
plausibly the application. Several unrelated endpoints returning byte-identical
HTML within seconds of each other is not.

This has to run after the fact rather than per request, because no single
response carries the evidence. Nothing is deleted: samples are relabelled, and
the report counts them separately rather than discarding them.
"""

import hashlib;

glob INFRA_BLOCK: str = "INFRA_BLOCK_SUSPECTED";
# Wide enough that a blocked burst lands together, narrow enough that unrelated
# failures hours apart are not read as one event.
glob BUCKET_SECONDS: float = 10.0;


def body_fingerprint(body: bytes) -> str | None {
    # Only non-JSON bodies are fingerprinted. A JSON body is the application
    # answering -- even a JSON error is the app talking, not a gateway.
    if not body {
        return None;
    }
    head = body.lstrip()[:1];
    if head in (b"{", b"[") {
        return None;
    }
    return hashlib.sha256(body[:2048]).hexdigest()[:16];
}


def classify(samples: list, threshold: int, t_start: float) -> int {
    # Relabels matching samples in place and returns how many were reclassified.
    # A threshold below 2 disables the check: "identical across >= 1 endpoint" is
    # every repeated error, which would swallow real application failures.
    if threshold < 2 or not samples {
        return 0;
    }

    endpoints_by_key: dict = {};
    for sample in samples {
        if sample.body_hash is None {
            continue;
        }
        if sample.error_type is None and sample.status == sample.expected_status {
            continue;
        }
        bucket = int((sample.timestamp - t_start) // BUCKET_SECONDS);
        key = (bucket, sample.body_hash);
        if key not in endpoints_by_key {
            endpoints_by_key[key] = set();
        }
        endpoints_by_key[key].add(sample.endpoint);
    }

    blocked_keys = {
        key for (key, endpoints) in endpoints_by_key.items()
        if len(endpoints) >= threshold
    };
    if not blocked_keys {
        return 0;
    }

    reclassified = 0;
    for sample in samples {
        if sample.body_hash is None {
            continue;
        }
        bucket = int((sample.timestamp - t_start) // BUCKET_SECONDS);
        if (bucket, sample.body_hash) not in blocked_keys {
            continue;
        }
        if sample.error_type is None and sample.status == sample.expected_status {
            continue;
        }
        sample.error_type = f"{INFRA_BLOCK}: identical non-JSON body across endpoints";
        reclassified += 1;
    }
    return reclassified;
}


def is_infra_block(error_type: str | None) -> bool {
    return error_type is not None and error_type.startswith(INFRA_BLOCK);
}


def load_proxies(source: str | None) -> list[str] {
    # One proxy URL per line; blank lines and # comments ignored.
    # A partial mitigation only: it spreads egress over a handful of addresses,
    # which is enough to stay under a per-IP threshold in some setups and is not
    # a substitute for Phase 11's distributed workers.
    if not source {
        return [];
    }
    import os;
    if not os.path.exists(source) {
        raise ValueError(f"--proxy-pool file not found: {source!r}");
    }
    with open(source, "r", encoding="utf-8") as fh {
        lines = fh.read().splitlines();
    }
    proxies = [
        line.strip() for line in lines
        if line.strip() and not line.strip().startswith("#")
    ];
    if not proxies {
        raise ValueError(f"--proxy-pool file {source!r} has no proxy entries");
    }
    for proxy in proxies {
        if "://" not in proxy {
            raise ValueError(
                f"--proxy-pool entry {proxy!r} needs a scheme, "
                "e.g. http://host:port or socks5://host:port"
            );
        }
    }
    return proxies;
}

def proxy_for(proxies: list[str], vu_id: int) -> str | None {
    # Per VU rather than per request, so one VU's session keeps one egress
    # address -- a connection pool that changed proxy mid-session would defeat
    # keep-alive and distort the latency being measured.
    if not proxies {
        return None;
    }
    return proxies[vu_id % len(proxies)];
}
