"""Unit tests for bridge/topology.jac — no network, no jac_scale imports."""

import os;
import from unittest { mock }
import from jac_loadtest_cli.bridge.topology { TopologyRouter, ServiceRoute }
import from jac_loadtest_cli.config { LoadTestConfig }


def _cfg(
    mode: str = "monolith",
    url: str | None = "http://localhost:8000",
    services_map: str | None = None,
) -> LoadTestConfig {
    return LoadTestConfig(mode=mode, url=url, services_map=services_map);
}


# ---------------------------------------------------------------------------
# Monolith mode
# ---------------------------------------------------------------------------

test "monolith routes all to url" {
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://localhost:8000"));
    result = router.resolve("http://recorded:8000/walker/search");
    assert result[0].startswith("http://localhost:8000");
    assert result[1] == "monolith";
}

test "monolith preserves path and query" {
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://gateway:9000"));
    result = router.resolve("http://recorded:8000/walker/order/create?page=2&sort=asc");
    assert result[0] == "http://gateway:9000/walker/order/create?page=2&sort=asc";
}

test "monolith service label is monolith" {
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://localhost:8000"));
    result = router.resolve("http://recorded:8000/user/login");
    assert result[1] == "monolith";
}


# ---------------------------------------------------------------------------
# --services-map JSON parsing (no disk I/O)
# ---------------------------------------------------------------------------

test "services map json parsed" {
    with mock.patch("jac_loadtest_cli.bridge.topology._load_toml_routes", return_value={}) {
        config = _cfg(
            mode="microservice",
            services_map='{"/walker/order": "http://order:18001"}',
        );
        router = TopologyRouter.from_config(config);
        result = router.resolve("http://rec:8000/walker/order/foo");
        assert result[1] == "walker/order";
        assert result[0].startswith("http://order:18001");
    }
}

test "services map invalid json raises" {
    with mock.patch("jac_loadtest_cli.bridge.topology._load_toml_routes", return_value={}) {
        config = _cfg(mode="microservice", services_map="{not valid json}");
        raised = False;
        try {
            TopologyRouter.from_config(config);
        } except ValueError as e {
            raised = True;
            assert "not valid JSON" in str(e);
        }
        assert raised;
    }
}


# ---------------------------------------------------------------------------
# Prefix matching correctness
# ---------------------------------------------------------------------------

test "longest prefix wins" {
    routes = [
        ServiceRoute(name="walker_generic", prefix="/walker",       url="http://generic:1"),
        ServiceRoute(name="order_service",  prefix="/walker/order", url="http://order:2"),
    ];
    router = TopologyRouter(_routes=routes);
    result = router.resolve("http://rec:8000/walker/order/create");
    assert result[1] == "order_service";
    assert result[0].startswith("http://order:2");
}

test "shorter prefix no false match" {
    routes = [ServiceRoute(name="inv", prefix="/walker/inventory", url="http://inv:3")];
    router = TopologyRouter(_routes=routes, _fallback_url="http://fallback:9");
    result = router.resolve("http://rec:8000/walker/order/create");
    assert result[1] == "gateway";
    assert result[0].startswith("http://fallback:9");
}

test "prefix exact match without trailing slash" {
    routes = [ServiceRoute(name="ping", prefix="/ping", url="http://svc:1")];
    router = TopologyRouter(_routes=routes);
    result = router.resolve("http://rec:8000/ping");
    assert result[1] == "ping";
    assert result[0] == "http://svc:1/";
}

test "prefix does not match similar longer path" {
    routes = [ServiceRoute(name="walker_svc", prefix="/walker", url="http://walker:1")];
    router = TopologyRouter(_routes=routes, _fallback_url="http://fallback:9");
    result = router.resolve("http://rec:8000/walker-admin/panel");
    assert result[1] == "gateway";
}

test "no match routes to gateway" {
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:1")];
    router = TopologyRouter(_routes=routes, _fallback_url="http://gateway:8000");
    result = router.resolve("http://rec:8000/some/unknown/path");
    assert result[1] == "gateway";
    assert result[0].startswith("http://gateway:8000");
    assert "/some/unknown/path" in result[0];
}


# ---------------------------------------------------------------------------
# jac.toml auto-discovery (monkeypatched)
# ---------------------------------------------------------------------------

test "jac toml discovery" {
    with mock.patch(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        return_value={
            "order_service":     "/walker/order",
            "inventory_service": "/walker/inventory",
        },
    ) {
        with mock.patch.dict(os.environ, {
            "JAC_SV_ORDER_SERVICE_URL":     "http://localhost:18001",
            "JAC_SV_INVENTORY_SERVICE_URL": "http://localhost:18002",
        }) {
            config = _cfg(mode="microservice", url="http://gateway:8000");
            router = TopologyRouter.from_config(config);

            res_o = router.resolve("http://gateway:8000/walker/order/item/42");
            assert res_o[1] == "order_service";
            assert "18001" in res_o[0];
            assert "/item/42" in res_o[0];

            res_i = router.resolve("http://gateway:8000/walker/inventory/list");
            assert res_i[1] == "inventory_service";
            assert "18002" in res_i[0];
        }
    }
}

test "jac toml missing env var raises" {
    with mock.patch(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        return_value={"order_service": "/walker/order"},
    ) {
        saved = os.environ.pop("JAC_SV_ORDER_SERVICE_URL", None);
        try {
            config = _cfg(mode="microservice", url="http://gateway:8000");
            raised = False;
            try {
                TopologyRouter.from_config(config);
            } except ValueError as e {
                raised = True;
                assert "JAC_SV_ORDER_SERVICE_URL" in str(e);
            }
            assert raised;
        } finally {
            if saved is not None {
                os.environ["JAC_SV_ORDER_SERVICE_URL"] = saved;
            }
        }
    }
}


# ---------------------------------------------------------------------------
# --services-map overrides jac.toml URL
# ---------------------------------------------------------------------------

test "services map overrides toml url" {
    with mock.patch(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        return_value={"order_service": "/walker/order"},
    ) {
        config = _cfg(
            mode="microservice",
            services_map='{"order_service": "http://override:9999"}',
            url="http://gateway:8000",
        );
        router = TopologyRouter.from_config(config);
        result = router.resolve("http://rec:8000/walker/order/create");
        assert result[1] == "order_service";
        assert result[0].startswith("http://override:9999");
        assert "/create" in result[0];
    }
}


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

test "missing toml and no services map raises" {
    with mock.patch("jac_loadtest_cli.bridge.topology._load_toml_routes", return_value={}) {
        config = _cfg(mode="microservice", services_map=None, url=None);
        raised = False;
        try {
            TopologyRouter.from_config(config);
        } except ValueError as e {
            raised = True;
            assert "jac.toml" in str(e);
        }
        assert raised;
    }
}

test "no fallback and no match raises" {
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:1")];
    router = TopologyRouter(_routes=routes, _fallback_url=None);
    raised = False;
    try {
        router.resolve("http://rec:8000/unknown/path");
    } except ValueError as e {
        raised = True;
        assert "No route for path" in str(e);
    }
    assert raised;
}


# ---------------------------------------------------------------------------
# Service label correctness
# ---------------------------------------------------------------------------

test "service label on result" {
    routes = [
        ServiceRoute(name="order_service",     prefix="/walker/order",     url="http://o:1"),
        ServiceRoute(name="inventory_service", prefix="/walker/inventory", url="http://i:2"),
    ];
    router = TopologyRouter(_routes=routes);
    assert router.resolve("http://rec:8000/walker/order/create")[1]    == "order_service";
    assert router.resolve("http://rec:8000/walker/inventory/list")[1]  == "inventory_service";
}

test "path and query preserved in routed url" {
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:18001")];
    router = TopologyRouter(_routes=routes);
    url = router.resolve("http://rec:8000/walker/order/create?owner=me&page=1")[0];
    assert "/create" in url;
    assert "owner=me" in url;
    assert "page=1" in url;
}


# ---------------------------------------------------------------------------
# Path-prefix keys in --services-map (jacBuilder pattern)
# ---------------------------------------------------------------------------

test "services map slash prefix key" {
    with mock.patch("jac_loadtest_cli.bridge.topology._load_toml_routes", return_value={}) {
        config = _cfg(
            mode="microservice",
            url="http://gateway:8000",
            services_map='{ "/walker/ai_chat": "http://jac-coder:18002", "/walker": "http://builder:18001" }',
        );
        router = TopologyRouter.from_config(config);

        res_ai = router.resolve("http://gateway:8000/walker/ai_chat");
        assert res_ai[1] == "walker/ai_chat";
        assert "18002" in res_ai[0];

        res_me = router.resolve("http://gateway:8000/walker/me");
        assert res_me[1] == "walker";
        assert "18001" in res_me[0];

        res_auth = router.resolve("http://gateway:8000/user/login");
        assert res_auth[1] == "gateway";
        assert "gateway:8000" in res_auth[0];
    }
}
