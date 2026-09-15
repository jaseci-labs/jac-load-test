"""Unit tests for core/spec_parser.jac — no network; local files only."""

import json;
import tempfile;
import from jac_loadtest_cli.core.spec_parser { parse_api_spec }
import from jac_loadtest_cli.core.har_parser { parse_har }


def _write(text: str, suffix: str = ".json") -> str {
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=suffix, delete=False);
    tmp.write(text);
    tmp.close();
    return tmp.name;
}


glob _OPENAPI3_SPEC: dict = {
    "openapi": "3.0.3",
    "info": {"title": "Pet Store", "version": "1.0"},
    "servers": [{"url": "https://api.example.com/v1"}],
    "paths": {
        "/pets/{petId}": {
            "parameters": [
                {"name": "petId", "in": "path", "required": True, "schema": {"type": "string"}},
            ],
            "get": {
                "operationId": "GetPet",
                "parameters": [
                    {"name": "verbose", "in": "query", "schema": {"type": "boolean", "example": True}},
                ],
                "responses": {"200": {"description": "ok"}},
            },
        },
        "/pets": {
            "post": {
                "operationId": "CreatePet",
                "requestBody": {
                    "content": {
                        "application/json": {
                            "schema": {"$ref": "#/components/schemas/NewPet"},
                        }
                    }
                },
                "responses": {"201": {"description": "created"}},
            },
        },
    },
    "components": {
        "schemas": {
            "NewPet": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "example": "Rex"},
                    "age": {"type": "integer"},
                },
            },
        },
    },
};

glob _SWAGGER2_SPEC: dict = {
    "swagger": "2.0",
    "host": "api.example.com",
    "basePath": "/v1",
    "schemes": ["https"],
    "paths": {
        "/items": {
            "post": {
                "operationId": "CreateItem",
                "consumes": ["application/json"],
                "parameters": [
                    {"name": "body", "in": "body", "schema": {
                        "type": "object",
                        "properties": {"title": {"type": "string", "default": "untitled"}},
                    }},
                ],
                "responses": {"200": {"description": "ok"}},
            },
        },
    },
};


# ---------------------------------------------------------------------------
# OpenAPI 3.x
# ---------------------------------------------------------------------------

test "openapi3 base url and path templating preserved" {
    path = _write(json.dumps(_OPENAPI3_SPEC));
    entries = parse_api_spec(path);
    assert len(entries) == 2;
    get_pet = next(e for e in entries if e["request"]["method"] == "GET");
    assert get_pet["request"]["url"].startswith("https://api.example.com/v1/pets/{petId}");
    assert "verbose=True" in get_pet["request"]["url"] or "verbose=true" in get_pet["request"]["url"].lower();
}

test "openapi3 request body synthesised from $ref schema" {
    path = _write(json.dumps(_OPENAPI3_SPEC));
    entries = parse_api_spec(path);
    create_pet = next(e for e in entries if e["request"]["method"] == "POST");
    body = json.loads(create_pet["request"]["postData"]["text"]);
    assert body["name"] == "Rex";
    assert body["age"] == 1;
    assert create_pet["response"]["status"] == 201;
    content_types = [h["value"] for h in create_pet["request"]["headers"] if h["name"] == "Content-Type"];
    assert content_types == ["application/json"];
}

test "openapi3 entries are HAR-compatible via parse_har" {
    path = _write(json.dumps(_OPENAPI3_SPEC));
    entries = parse_api_spec(path);
    har_path = _write(json.dumps({"log": {"version": "1.2", "entries": entries}}), suffix=".har");
    har_entries = parse_har(har_path, target_url="http://target:9000");
    assert len(har_entries) == 2;
    assert all(e.url.startswith("http://target:9000") for e in har_entries);
}


# ---------------------------------------------------------------------------
# Swagger 2.0
# ---------------------------------------------------------------------------

test "swagger2 base url from host/basePath/schemes" {
    path = _write(json.dumps(_SWAGGER2_SPEC));
    entries = parse_api_spec(path);
    assert len(entries) == 1;
    entry = entries[0];
    assert entry["request"]["url"] == "https://api.example.com/v1/items";
    body = json.loads(entry["request"]["postData"]["text"]);
    assert body["title"] == "untitled";
}


# ---------------------------------------------------------------------------
# YAML
# ---------------------------------------------------------------------------

test "yaml spec parses the same as json" {
    yaml_text = (
        "openapi: 3.0.3\n"
        "info:\n"
        "  title: Mini\n"
        "  version: '1.0'\n"
        "servers:\n"
        "  - url: http://localhost:8000\n"
        "paths:\n"
        "  /ping:\n"
        "    get:\n"
        "      operationId: Ping\n"
        "      responses:\n"
        "        '200':\n"
        "          description: ok\n"
    );
    path = _write(yaml_text, suffix=".yaml");
    entries = parse_api_spec(path);
    assert len(entries) == 1;
    assert entries[0]["request"]["url"] == "http://localhost:8000/ping";
}


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

test "neither openapi nor swagger key raises" {
    path = _write(json.dumps({"paths": {}}));
    raised = False;
    try {
        parse_api_spec(path);
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "missing file raises" {
    raised = False;
    try {
        parse_api_spec("/no/such/spec.json");
    } except OSError {
        raised = True;
    }
    assert raised;
}

test "empty paths yields no entries" {
    path = _write(json.dumps({"openapi": "3.0.3", "info": {"title": "x", "version": "1"}, "paths": {}}));
    entries = parse_api_spec(path);
    assert entries == [];
}
