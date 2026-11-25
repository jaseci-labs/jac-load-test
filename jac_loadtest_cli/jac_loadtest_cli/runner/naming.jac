"""Stable report names for requests."""

import re;
import from urllib.parse { urlparse }

def normalize_path(url: str) -> str {
    # Id-looking path segments (numbers, uuids) collapse to {id} so one endpoint
    # is one row in the report instead of one row per id.
    segments = urlparse(url).path.split("/");
    out: list[str] = [];
    for seg in segments {
        if re.fullmatch(r"\d+", seg) or re.fullmatch(r"[0-9a-f\-]{32,36}", seg) {
            out.append("{id}");
        } else {
            out.append(seg);
        }
    }
    return "/".join(out);
}
