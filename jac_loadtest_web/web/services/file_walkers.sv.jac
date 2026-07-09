"""File upload walkers.

Scope note: this pass implements upload_har only (file-picker path for the
workspace-creation wizard's HAR step). The live proxy recorder
(start_proxy/stop_proxy) and CSV credential upload are separate, deferred
work — not needed for the file-upload-only wizard flow.

upload_har does its own lightweight parsing of the raw HAR JSON rather than
reusing jac_loadtest_cli's core.har_parser.parse_har(): that parser produces
HarEntry objects shaped for replay (method/url/headers/body/think_time_ms —
no response status, MIME type, or timing), already filtered for static
assets and cache-busting. The wizard's entry table needs the opposite: the
raw per-request status/MIME/response-time metadata for a human to review and
toggle, before any replay-time filtering happens. That translation from
"reviewed HAR entries" to actual replay entries belongs to the future load
test run walker, not here.
"""

import json;
import from fastapi { UploadFile }
import from urllib.parse { urlparse }
import from jaclang.jac0core.constructs { Root }

glob _SENSITIVE_HEADERS: set[str] = {"authorization", "cookie"};

walker upload_har {
    has file: UploadFile;

    can parse with Root entry {
        raw_bytes = self.file.file.read();
        try {
            text = raw_bytes.decode("utf-8");
            har = json.loads(text);
        } except Exception as e {
            report {"error": f"Invalid HAR file: {e}"};
            return;
        }

        raw_entries = har.get("log", {}).get("entries", []);
        entries: list[dict] = [];
        security_warning = False;

        for entry in raw_entries {
            request = entry.get("request", {});
            response = entry.get("response", {});
            headers = request.get("headers", []);
            for h in headers {
                if h.get("name", "").lower() in _SENSITIVE_HEADERS {
                    security_warning = True;
                }
            }
            url = request.get("url", "");
            entries.append({
                "method": request.get("method", "GET"),
                "url": url,
                "path": urlparse(url).path if url else "",
                "status": response.get("status", 0),
                "mime_type": response.get("content", {}).get("mimeType", ""),
                "time": entry.get("time", 0),
                "headers": headers,
                "enabled": True,
            });
        }

        report {
            "entries": entries,
            "security_warning": security_warning,
            "har_raw_json": text,
        };
    }
}
