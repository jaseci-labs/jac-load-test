import json;
import re;
import sys;
import from urllib.parse { parse_qs, urlparse, urlunparse }

glob _SKIP_MIME_PREFIXES: tuple[str] = (
    "image/",
    "font/",
    "text/css",
    "application/javascript",
    "text/javascript",
    "application/wasm",
);

glob _STRIP_HEADERS: set[str] = {"authorization", "cookie", "host", "content-length"};

glob _SKIP_RESOURCE_TYPES: set[str] = {
    "websocket",
    "eventsource",
    "document",
    "manifest",
    "texttrack",
    "media",
    "font",
};

glob _CACHE_BUSTER_PARAMS: set[str] = {"_", "cb", "cachebust", "cache_bust", "nocache", "bust"};
glob _TIMESTAMP_RE: re.Pattern[str] = re.compile(r"^\d{10,13}$");

obj HarEntry {
    has method: str;
    has url: str;
    has headers: dict[str, str];
    has body: str | None;
    has body_mime: str | None;
    has think_time_ms: float;
    has is_login: bool;
    has original_url: str;
    has expected_status: int = 200;
    has occurrence: int = 0;
    has total_occurrences: int = 0;
}

def _origin(url: str) -> str {
    p = urlparse(url);
    return str(urlunparse((p.scheme, p.netloc, "", "", "", "")));
}

def _rewrite_url(original: str, target_url: str) -> str {
    p = urlparse(original);
    t = urlparse(target_url);
    rewritten: str = str(urlunparse((t.scheme, t.netloc, p.path, p.params, p.query, "")));
    return rewritten;
}

def _is_static(mime: str) -> bool {
    if not mime {
        return False;
    }
    mime_lower = mime.lower().split(";")[0].strip();
    return bool(any([mime_lower.startswith(str(prefix)) for prefix in _SKIP_MIME_PREFIXES]));
}

def _is_unsupported_type(raw_ent: object) -> bool {
    if not isinstance(raw_ent, dict) {
        return False;
    }
    resource_type = str(raw_ent.get("_resourceType", "")).lower();
    if resource_type in _SKIP_RESOURCE_TYPES {
        return True;
    }
    request = raw_ent.get("request") or {};
    url = str(request.get("url", "")) if isinstance(request, dict) else "";
    return bool(url.startswith(("ws://", "wss://")));
}

def _has_missing_body(method: str, raw_headers: list[dict[str, str]], post_data: object) -> bool {
    if method.upper() not in ("POST", "PUT", "PATCH") {
        return False;
    }
    headers = raw_headers if isinstance(raw_headers, list) else [];
    content_length: str = "0";
    for h in headers {
        if h.get("name", "").lower() == "content-length" {
            content_length = str(h["value"]);
            break;
        }
    }
    try {
        has_content = bool(int(str(content_length)) > 0);
    } except ValueError {
        has_content = False;
    }
    post = post_data if isinstance(post_data, dict) else {};
    body_text = post.get("text");
    return bool(has_content and not body_text);
}

def _has_cache_buster(url: str) -> bool {
    qs = parse_qs(urlparse(url).query);
    return bool(any([
        str(item[0]).lower() in _CACHE_BUSTER_PARAMS
        and bool(item[1])
        and bool(_TIMESTAMP_RE.match(str(item[1][0])))
        for item in qs.items()
    ]));
}

def parse_har(
    har_path: str,
    target_url: str | None = None,
    include_static: bool = False,
    login_path: str = "/user/login",
) -> list[HarEntry] {
    with open(har_path, encoding="utf-8") as f {
        data = dict(json.load(f));
    }

    if "log" not in data {
        raise ValueError("Malformed HAR file: missing 'log' key");
    }

    raw_entries:list[dict] = [];
    if isinstance (data, dict) {
        log = data.get("log", {});
        if isinstance(log, dict) {
            version = log.get("version", "unknown");
            entries = log.get("entries", []);
            if isinstance(version, str) {
                _check_version(version);
            }
            if isinstance(entries, list) {
                raw_entries = entries;
            }
        }
    }

    if not raw_entries {
        return [];
    }

    _security_scan(raw_entries);

    result: list[HarEntry] = [];
    warned_unsupported:bool = False;
    warned_cache_buster:bool = False;
    warned_missing_body:bool = False;

    for entry in raw_entries {
        req:dict[str, any] = dict(entry["request"]);
        resp:dict[str, any] = dict(entry.get("response", {}));
        content:dict[str, str] = dict(resp.get("content", {}));
        mime:str = str(content.get("mimeType", ""));

        if _is_unsupported_type(entry) {
            if not warned_unsupported {
                print(
                    "\n\033[33mWarning: HAR contains WebSocket, SSE, or non-API entries "
                    "(websocket, eventsource, document, etc.). "
                    "These are skipped automatically.\033[0m",
                    file=sys.stderr,
                );
                warned_unsupported = True;
            }
            continue;
        }

        original_url:str = str(req["url"]);

        if _has_cache_buster(original_url) {
            if not warned_cache_buster {
                print(
                    "\n\033[33mWarning: HAR contains URLs with cache-busting timestamp "
                    "parameters (e.g. ?_=<timestamp>). These entries are skipped — "
                    "the stale timestamp causes the server to reject the request.\033[0m",
                    file=sys.stderr,
                );
                warned_cache_buster = True;
            }
            continue;
        }

        if not include_static and _is_static(str(mime)) {
            continue;
        }

        if target_url is not None {
            rewritten_url = _rewrite_url(str(original_url), target_url);
        } else {
            rewritten_url = str(original_url);
        }

        raw_headers:list[dict] = list(req.get("headers", []));

        if _has_missing_body(str(req["method"]), raw_headers, req.get("postData")) {
            if not warned_missing_body {
                print(
                    "\n\033[33mWarning: HAR contains POST/PUT/PATCH entries where the request body "
                    "was not captured (postData missing despite non-zero Content-Length). "
                    "These entries are skipped — replaying them without a body would cause "
                    "422 errors. Re-record the HAR to capture the full request body.\033[0m",
                    file=sys.stderr,
                );
                warned_missing_body = True;
            }
            continue;
        }

        headers = _sanitize_headers(raw_headers);

        post_data:dict[str, str] = dict(req.get("postData", {}) or {});
        body: str | None = str(post_data.get("text")) or None;
        body_mime: str | None = str(post_data.get("mimeType")) or None;

        timings:dict[str, float | int] = dict(entry.get("timings", {}));
        think_time_ms:float = float(timings.get("wait", 0.0));

        is_login = urlparse(original_url).path == login_path;

        expected_status:int = int(resp.get("status", 200) or 200);

        result.append(
            HarEntry(
                method=str(req["method"].upper()),
                url=rewritten_url,
                headers=headers,
                body=body,
                body_mime=body_mime,
                think_time_ms=think_time_ms,
                is_login=is_login,
                original_url=original_url,
                expected_status=expected_status,
            )
        );
    }

    totals: dict[str, int] = {};
    for entry in result {
        path: str = str(urlparse(entry.url).path);
        totals[path] = totals.get(path, 0) + 1;
    }

    seen: dict[str, int] = {};
    for entry in result {
        path: str = str(urlparse(entry.url).path);
        seen[path] = seen.get(path, 0) + 1;
        entry.occurrence = int(seen[path]);
        entry.total_occurrences = int(totals[path]);
    }

    return result;
}

glob _SUPPORTED_HAR_VERSIONS: set = {"1.1", "1.2"};

def _check_version(version: str) -> None {
    if version not in _SUPPORTED_HAR_VERSIONS {
        print(
            f"\n\033[33mWarning: HAR version '{version}' is not tested with this tool "
            f"(tested: {', '.join(sorted(_SUPPORTED_HAR_VERSIONS))}).\n"
            "Parsing will continue but results may be incomplete or incorrect.\n"
            "If the output looks wrong, check for a jac-loadtest update.\033[0m",
            file=sys.stderr,
        );
    }
}

def _security_scan(entries: list[dict[str, object]]) -> None {
    for entry in entries {
        for hdr in entry.get("request", {}).get("headers", []) {
            name = hdr.get("name", "").lower();
            value = hdr.get("value", "");
            if name in ("authorization", "cookie") and value {
                print(
                    "\n\033[33mWarning: HAR file contains Authorization/Cookie headers from the "
                    "recording session.\nThese headers are stripped before replay, but "
                    "the file itself contains sensitive data.\n"
                    "Do not commit this HAR file to version control.\033[0m",
                    file=sys.stderr,
                );
                return;
            }
        }
    }
}

def _sanitize_headers(raw_headers: list[dict[str, str]]) -> dict[str, str] {
    return {
        h["name"]: h["value"]
        for h in raw_headers
        if h.get("name", "").lower() not in _STRIP_HEADERS
        and not h.get("name", "").startswith(":")
    };
}
