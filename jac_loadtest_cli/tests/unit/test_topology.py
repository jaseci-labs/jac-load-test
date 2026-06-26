"""Unit tests for bridge/topology.py — no network, no jac_scale imports.

All tests that touch jac.toml discovery monkeypatch _load_toml_routes so that
jac_scale is never imported during the unit test run.
"""
from __future__ import annotations

import pytest

from jac_loadtest_cli.bridge.topology import TopologyRouter, ServiceRoute
from jac_loadtest_cli.config import LoadTestConfig


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _cfg(**kwargs) -> LoadTestConfig:
    """Build a minimal LoadTestConfig with sensible defaults for testing."""
    defaults: dict = dict(mode="monolith", url="http://localhost:8000", services_map=None)
    defaults.update(kwargs)
    return LoadTestConfig(**defaults)


# ---------------------------------------------------------------------------
# Monolith mode
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_monolith_routes_all_to_url():
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://localhost:8000"))
    url, svc = router.resolve("http://recorded:8000/walker/search")
    assert url.startswith("http://localhost:8000")
    assert svc == "monolith"


@pytest.mark.unit
def test_monolith_preserves_path_and_query():
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://gateway:9000"))
    url, _ = router.resolve("http://recorded:8000/walker/order/create?page=2&sort=asc")
    assert url == "http://gateway:9000/walker/order/create?page=2&sort=asc"


@pytest.mark.unit
def test_monolith_service_label_is_monolith():
    router = TopologyRouter.from_config(_cfg(mode="monolith", url="http://localhost:8000"))
    _, svc = router.resolve("http://recorded:8000/user/login")
    assert svc == "monolith"


# ---------------------------------------------------------------------------
# --services-map JSON parsing (no disk I/O)
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_services_map_json_parsed(monkeypatch):
    # Ensure no disk read happens even if jac.toml exists somewhere
    monkeypatch.setattr("jac_loadtest_cli.bridge.topology._load_toml_routes", lambda: {})
    config = _cfg(
        mode="microservice",
        services_map='{"/walker/order": "http://order:18001"}',
    )
    router = TopologyRouter.from_config(config)
    url, svc = router.resolve("http://rec:8000/walker/order/foo")
    assert svc == "walker/order"
    assert url.startswith("http://order:18001")


@pytest.mark.unit
def test_services_map_invalid_json_raises(monkeypatch):
    monkeypatch.setattr("jac_loadtest_cli.bridge.topology._load_toml_routes", lambda: {})
    config = _cfg(mode="microservice", services_map="{not valid json}")
    with pytest.raises(ValueError, match="not valid JSON"):
        TopologyRouter.from_config(config)


# ---------------------------------------------------------------------------
# Prefix matching correctness
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_longest_prefix_wins():
    routes = [
        ServiceRoute(name="walker_generic", prefix="/walker", url="http://generic:1"),
        ServiceRoute(name="order_service",  prefix="/walker/order", url="http://order:2"),
    ]
    router = TopologyRouter(_routes=routes)
    url, svc = router.resolve("http://rec:8000/walker/order/create")
    assert svc == "order_service"
    assert url.startswith("http://order:2")


@pytest.mark.unit
def test_shorter_prefix_no_false_match():
    # /walker/order should NOT match /walker/inventory/...
    routes = [ServiceRoute(name="inv", prefix="/walker/inventory", url="http://inv:3")]
    router = TopologyRouter(_routes=routes, _fallback_url="http://fallback:9")
    url, svc = router.resolve("http://rec:8000/walker/order/create")
    assert svc == "gateway"
    assert url.startswith("http://fallback:9")


@pytest.mark.unit
def test_prefix_exact_match_without_trailing_slash():
    # path == prefix exactly (no trailing slash) must still match; stripped path becomes "/"
    routes = [ServiceRoute(name="ping", prefix="/ping", url="http://svc:1")]
    router = TopologyRouter(_routes=routes)
    url, svc = router.resolve("http://rec:8000/ping")
    assert svc == "ping"
    assert url == "http://svc:1/"


@pytest.mark.unit
def test_prefix_does_not_match_similar_longer_path():
    # /walker must NOT match /walker-admin (no slash boundary)
    routes = [ServiceRoute(name="walker_svc", prefix="/walker", url="http://walker:1")]
    router = TopologyRouter(_routes=routes, _fallback_url="http://fallback:9")
    url, svc = router.resolve("http://rec:8000/walker-admin/panel")
    assert svc == "gateway"  # fell through to fallback


@pytest.mark.unit
def test_no_match_routes_to_gateway():
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:1")]
    router = TopologyRouter(_routes=routes, _fallback_url="http://gateway:8000")
    url, svc = router.resolve("http://rec:8000/some/unknown/path")
    assert svc == "gateway"
    assert url.startswith("http://gateway:8000")
    assert "/some/unknown/path" in url


# ---------------------------------------------------------------------------
# jac.toml auto-discovery (monkeypatched)
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_jac_toml_discovery(monkeypatch):
    monkeypatch.setattr(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        lambda: {
            "order_service": "/walker/order",
            "inventory_service": "/walker/inventory",
        },
    )
    monkeypatch.setenv("JAC_SV_ORDER_SERVICE_URL", "http://localhost:18001")
    monkeypatch.setenv("JAC_SV_INVENTORY_SERVICE_URL", "http://localhost:18002")

    config = _cfg(mode="microservice", url="http://gateway:8000")
    router = TopologyRouter.from_config(config)

    url_o, svc_o = router.resolve("http://gateway:8000/walker/order/item/42")
    assert svc_o == "order_service"
    assert "18001" in url_o
    assert "/item/42" in url_o  # prefix /walker/order stripped; service receives /item/42

    url_i, svc_i = router.resolve("http://gateway:8000/walker/inventory/list")
    assert svc_i == "inventory_service"
    assert "18002" in url_i


@pytest.mark.unit
def test_jac_toml_missing_env_var_raises(monkeypatch):
    monkeypatch.setattr(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        lambda: {"order_service": "/walker/order"},
    )
    # Ensure the env var is absent
    monkeypatch.delenv("JAC_SV_ORDER_SERVICE_URL", raising=False)

    config = _cfg(mode="microservice", url="http://gateway:8000")
    with pytest.raises(ValueError, match="JAC_SV_ORDER_SERVICE_URL"):
        TopologyRouter.from_config(config)


# ---------------------------------------------------------------------------
# --services-map overrides jac.toml URL
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_services_map_overrides_toml_url(monkeypatch):
    # jac.toml has prefix; --services-map overrides the URL
    monkeypatch.setattr(
        "jac_loadtest_cli.bridge.topology._load_toml_routes",
        lambda: {"order_service": "/walker/order"},
    )
    config = _cfg(
        mode="microservice",
        services_map='{"order_service": "http://override:9999"}',
        url="http://gateway:8000",
    )
    router = TopologyRouter.from_config(config)
    url, svc = router.resolve("http://rec:8000/walker/order/create")
    assert svc == "order_service"
    assert url.startswith("http://override:9999")
    # prefix /walker/order matched via toml, then stripped; service receives /create
    assert "/create" in url


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_missing_toml_and_no_services_map_raises(monkeypatch):
    monkeypatch.setattr("jac_loadtest_cli.bridge.topology._load_toml_routes", lambda: {})
    config = _cfg(mode="microservice", services_map=None, url=None)
    with pytest.raises(ValueError, match="jac.toml"):
        TopologyRouter.from_config(config)


@pytest.mark.unit
def test_no_fallback_and_no_match_raises():
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:1")]
    router = TopologyRouter(_routes=routes, _fallback_url=None)
    with pytest.raises(ValueError, match="No route for path"):
        router.resolve("http://rec:8000/unknown/path")


# ---------------------------------------------------------------------------
# Service label correctness
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_service_label_on_result():
    routes = [
        ServiceRoute(name="order_service",     prefix="/walker/order",     url="http://o:1"),
        ServiceRoute(name="inventory_service", prefix="/walker/inventory", url="http://i:2"),
    ]
    router = TopologyRouter(_routes=routes)
    _, svc1 = router.resolve("http://rec:8000/walker/order/create")
    _, svc2 = router.resolve("http://rec:8000/walker/inventory/list")
    assert svc1 == "order_service"
    assert svc2 == "inventory_service"


@pytest.mark.unit
def test_path_and_query_preserved_in_routed_url():
    routes = [ServiceRoute(name="orders", prefix="/walker/order", url="http://order:18001")]
    router = TopologyRouter(_routes=routes)
    url, _ = router.resolve("http://rec:8000/walker/order/create?owner=me&page=1")
    assert "/create" in url  # prefix /walker/order stripped; service receives /create
    assert "owner=me" in url
    assert "page=1" in url


# ---------------------------------------------------------------------------
# Path-prefix keys in --services-map (jacBuilder pattern)
# ---------------------------------------------------------------------------

@pytest.mark.unit
def test_services_map_slash_prefix_key(monkeypatch):
    """Keys starting with '/' are used directly as path prefixes (jacBuilder pattern)."""
    monkeypatch.setattr("jac_loadtest_cli.bridge.topology._load_toml_routes", lambda: {})
    config = _cfg(
        mode="microservice",
        url="http://gateway:8000",
        services_map='{ "/walker/ai_chat": "http://jac-coder:18002", "/walker": "http://builder:18001" }',
    )
    router = TopologyRouter.from_config(config)

    # ai_chat path — longer prefix wins
    url_ai, svc_ai = router.resolve("http://gateway:8000/walker/ai_chat")
    assert svc_ai == "walker/ai_chat"  # leading slash stripped from service name
    assert "18002" in url_ai

    # other walker path — shorter /walker prefix
    url_me, svc_me = router.resolve("http://gateway:8000/walker/me")
    assert svc_me == "walker"  # leading slash stripped from service name
    assert "18001" in url_me

    # auth path — falls back to gateway
    url_auth, svc_auth = router.resolve("http://gateway:8000/user/login")
    assert svc_auth == "gateway"
    assert "gateway:8000" in url_auth
