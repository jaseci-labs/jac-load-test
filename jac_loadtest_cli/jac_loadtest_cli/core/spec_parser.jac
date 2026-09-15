"""OpenAPI 3.0/3.1 and Swagger 2.0 spec import — Phase 10c.

Turns a spec document (a URL or a local JSON/YAML file) into a list of
HAR-entry-shaped dicts, the same raw shape core/har_parser.jac:parse_har()
reads out of a recorded HAR's `log.entries`. That means a spec-derived
"recording" rides the existing pipeline (auth, correlation, --param,
engine.jac) completely unchanged once it is wrapped in a `{"log": {...}}`
envelope and written to disk — see cli.jac:run_from_spec().

No AI, no heuristics beyond the spec itself: examples come from the
document's own `example`/`default` fields, falling back to a type-shaped
placeholder value when neither is present. Path templates (`/pets/{petId}`)
are intentionally left untouched in the synthesised URL — there is no
recorded value to substitute in their place — so the real per-run value
comes from `--param 'GetPet.path=ids.txt'` or `--correlate '... -> GetPet.path'`,
which already know how to rewrite the last path segment
(core/parameterize.jac, core/correlation.jac).
"""

import json;
import requests;
import from urllib.parse { urlencode, urljoin, urlparse }

glob _HTTP_METHODS: tuple[str] = ("get", "post", "put", "patch", "delete", "head", "options", "trace");

glob _PLACEHOLDER_BY_TYPE: dict[str, object] = {
    "string": "string",
    "integer": 1,
    "number": 1.0,
    "boolean": True,
    "array": [],
    "object": {},
};


def _is_url(source: str) -> bool {
    return source.startswith("http://") or source.startswith("https://");
}


def _load_text(source: str) -> str {
    if _is_url(source) {
        resp = requests.get(source, timeout=30);
        resp.raise_for_status();
        return resp.text;
    }
    with open(source, encoding="utf-8") as fh {
        return fh.read();
    }
}


def _load_spec(source: str) -> dict {
    text = _load_text(source);
    try {
        parsed = json.loads(text);
    } except json.JSONDecodeError {
        try {
            import yaml;
        } except ImportError as exc {
            raise ValueError(
                f"{source!r} is not valid JSON and PyYAML is not installed to try YAML"
            ) from exc;
        }
        try {
            parsed = yaml.safe_load(text);
        } except yaml.YAMLError as exc {
            raise ValueError(f"{source!r} is neither valid JSON nor valid YAML: {exc}") from exc;
        }
    }
    if not isinstance(parsed, dict) {
        raise ValueError(f"{source!r} did not parse to a JSON/YAML object");
    }
    return parsed;
}


def _spec_kind(spec: dict) -> str {
    if "openapi" in spec {
        return "openapi3";
    }
    if "swagger" in spec {
        return "swagger2";
    }
    raise ValueError("spec has neither an 'openapi' nor a 'swagger' version key");
}


def _base_url(spec: dict, source: str, kind: str) -> str {
    origin = "";
    if _is_url(source) {
        p = urlparse(source);
        origin = f"{p.scheme}://{p.netloc}";
    }
    if kind == "openapi3" {
        servers = spec.get("servers");
        if isinstance(servers, list) and servers {
            first = servers[0];
            url = str(first.get("url", "")) if isinstance(first, dict) else "";
            if url {
                return url if _is_url(url) else (urljoin(origin + "/", url.lstrip("/")) if origin else url);
            }
        }
        return origin or "http://localhost";
    }
    # Swagger 2.0
    schemes = spec.get("schemes") or ["https"];
    scheme = str(schemes[0]);
    host = str(spec.get("host", "")) or (urlparse(origin).netloc if origin else "localhost");
    base_path = str(spec.get("basePath", "") or "");
    return f"{scheme}://{host}{base_path}";
}


def _resolve_ref(spec: dict, ref: str) -> dict {
    # Only local refs ('#/components/schemas/Pet', '#/definitions/Pet') — a
    # spec importer has no business following remote $ref documents.
    if not ref.startswith("#/") {
        return {};
    }
    cursor = spec;
    for part in ref[2:].split("/") {
        if not isinstance(cursor, dict) or part not in cursor {
            return {};
        }
        cursor = cursor[part];
    }
    return cursor if isinstance(cursor, dict) else {};
}


def _example_for_schema(schema: dict, spec: dict, depth: int = 0) -> object {
    if depth > 6 {
        # Cycle guard — a self-referencing schema (e.g. a tree/linked-list
        # shape) would otherwise recurse forever.
        return None;
    }
    ref = schema.get("$ref");
    if isinstance(ref, str) {
        return _example_for_schema(_resolve_ref(spec, ref), spec, depth + 1);
    }
    if "example" in schema {
        return schema["example"];
    }
    if "default" in schema {
        return schema["default"];
    }
    enum_values = schema.get("enum");
    if isinstance(enum_values, list) and enum_values {
        return enum_values[0];
    }
    schema_type = schema.get("type");
    if schema_type == "object" or "properties" in schema {
        props = schema.get("properties", {});
        return {
            name: _example_for_schema(prop_schema, spec, depth + 1)
            for (name, prop_schema) in props.items()
            if isinstance(prop_schema, dict)
        };
    }
    if schema_type == "array" {
        item_schema = schema.get("items", {});
        item = _example_for_schema(item_schema, spec, depth + 1) if isinstance(item_schema, dict) else None;
        return [item] if item is not None else [];
    }
    return _PLACEHOLDER_BY_TYPE.get(str(schema_type), None);
}


def _stringify_param(schema: dict, spec: dict) -> str {
    value = _example_for_schema(schema, spec);
    if value is None {
        return "";
    }
    if isinstance(value, bool) {
        return "true" if value else "false";
    }
    if isinstance(value, (dict, list)) {
        return json.dumps(value);
    }
    return str(value);
}


def _collect_parameters(spec: dict, path_item: dict, operation: dict) -> list[dict] {
    # Path-level parameters apply to every method on that path; an
    # operation-level parameter with the same (name, in) overrides it.
    merged: dict[tuple, dict] = {};
    for raw in list(path_item.get("parameters", []) or []) + list(operation.get("parameters", []) or []) {
        if not isinstance(raw, dict) {
            continue;
        }
        ref = raw.get("$ref");
        param = _resolve_ref(spec, ref) if isinstance(ref, str) else raw;
        if not isinstance(param, dict) or "name" not in param or "in" not in param {
            continue;
        }
        merged[(param["in"], param["name"])] = param;
    }
    return list(merged.values());
}


def _query_string(params: list[dict], spec: dict) -> str {
    pairs = [
        (p["name"], _stringify_param(p.get("schema", p), spec))
        for p in params
        if p.get("in") == "query"
    ];
    return urlencode(pairs) if pairs else "";
}


def _header_list(params: list[dict], spec: dict) -> list[dict] {
    return [
        {"name": p["name"], "value": _stringify_param(p.get("schema", p), spec)}
        for p in params
        if p.get("in") == "header"
    ];
}


def _request_body_v3(operation: dict, spec: dict) -> tuple {
    body = operation.get("requestBody");
    if isinstance(body, dict) and "$ref" in body {
        body = _resolve_ref(spec, body["$ref"]);
    }
    if not isinstance(body, dict) {
        return (None, None);
    }
    content = body.get("content", {});
    if not isinstance(content, dict) or not content {
        return (None, None);
    }
    mime = "application/json" if "application/json" in content else next(iter(content));
    media = content.get(mime, {});
    schema = media.get("schema", {}) if isinstance(media, dict) else {};
    example = media.get("example") if isinstance(media, dict) else None;
    value = example if example is not None else _example_for_schema(schema, spec);
    if value is None {
        return (None, mime);
    }
    text = value if isinstance(value, str) else json.dumps(value);
    return (text, mime);
}


def _request_body_v2(params: list[dict], operation: dict, spec: dict) -> tuple {
    body_param: dict | None = next((p for p in params if p.get("in") == "body"), None);
    if body_param is not None {
        schema = body_param.get("schema", {});
        value = _example_for_schema(schema, spec);
        consumes = operation.get("consumes") or ["application/json"];
        mime = consumes[0];
        if value is None {
            return (None, mime);
        }
        return (value if isinstance(value, str) else json.dumps(value), mime);
    }
    form_params = [p for p in params if p.get("in") == "formData"];
    if form_params {
        pairs = [(p["name"], _stringify_param(p, spec)) for p in form_params];
        return (urlencode(pairs), "application/x-www-form-urlencoded");
    }
    return (None, None);
}


def _response_status(operation: dict) -> int {
    responses = operation.get("responses", {});
    if not isinstance(responses, dict) or not responses {
        return 200;
    }
    numeric_codes = [str(code) for code in responses if str(code).isdigit()];
    for code in numeric_codes {
        if code.startswith("2") {
            return int(code);
        }
    }
    return int(numeric_codes[0]) if numeric_codes else 200;
}


# Parses an OpenAPI 3.0/3.1 or Swagger 2.0 document (URL or file, JSON or
# YAML) into a list of HAR-entry-shaped dicts.
def parse_api_spec(source: str) -> list[dict] {
    spec = _load_spec(source);
    kind = _spec_kind(spec);
    base_url = _base_url(spec, source, kind);

    paths = spec.get("paths", {});
    if not isinstance(paths, dict) {
        return [];
    }

    entries: list[dict] = [];
    for (path, path_item) in paths.items() {
        if not isinstance(path_item, dict) {
            continue;
        }
        for method in _HTTP_METHODS {
            operation = path_item.get(method);
            if not isinstance(operation, dict) {
                continue;
            }
            params = _collect_parameters(spec, path_item, operation);
            query = _query_string(params, spec);
            headers = _header_list(params, spec);

            if kind == "openapi3" {
                (body_text, body_mime) = _request_body_v3(operation, spec);
            } else {
                (body_text, body_mime) = _request_body_v2(params, operation, spec);
            }

            url = base_url.rstrip("/") + path + (f"?{query}" if query else "");

            post_data = {"mimeType": body_mime, "text": body_text} if body_text is not None else None;
            if post_data is not None {
                headers = headers + [{"name": "Content-Type", "value": body_mime or "application/json"}];
            }

            entries.append({
                "request": {
                    "method": method.upper(),
                    "url": url,
                    "headers": headers,
                    "postData": post_data,
                    "queryString": [],
                },
                "response": {
                    "status": _response_status(operation),
                    "content": {"mimeType": "application/json"},
                },
                "timings": {"send": 0, "wait": 0, "receive": 0},
                "_jac_spec_operation": operation.get("operationId") or f"{method.upper()} {path}",
            });
        }
    }
    return entries;
}
