# Jaseci Python API Reference

Research findings from exploring `/home/sahan/dev/jaseci` repo.
Relevant for `bridge/` module implementation and future Jac migration.

---

## Package Versions and Python Requirement

| Package | PyPI name | Version | Python |
|---------|-----------|---------|--------|
| Jac language runtime | `jaclang` | `>=0.15.2` | `>=3.12` |
| jac-scale plugin | `jac-scale` | `>=0.2.18` | `>=3.12` |

**Both packages require Python 3.12+.** No 3.11 fallback needed.

`aiohttp>=3.9.0` is already a core dependency of `jac-scale` — do not declare it separately.

---

## Critical: JacMetaImporter

`.jac` files are compiled to Python on the fly. The meta importer must be registered
**before any `jac_scale.*` import** — put it at the very top of `cli.py`:

```python
from jaclang.meta_importer import JacMetaImporter
import sys
if not any(isinstance(f, JacMetaImporter) for f in sys.meta_path):
    sys.meta_path.insert(0, JacMetaImporter())
```

Without this, importing from `jac_scale.microservices.*` or `jac_scale.config_loader` will fail.

---

## jac-scale: Config Loading

**File:** `jac-scale/jac_scale/impl/config_loader.impl.jac`

```python
from jac_scale.config_loader import get_scale_config, JacScaleConfig

config: JacScaleConfig = get_scale_config()          # reads ./jac.toml by default
config = get_scale_config(project_dir=Path("/some/path"))  # explicit path

ms = config.get_microservices_config()
# ms keys:
#   enabled: bool
#   gateway_port: int
#   gateway_host: str
#   routes: dict          # {module_name: url_prefix}
#   services: dict        # per-service overrides keyed by module name
#   drain_timeout_seconds: float
#   http_forward_timeout: float
#   rate_limit: dict
#   cors: dict
#   client: dict
#   ingress: dict
#   shared_volumes: list
```

Other config getters available on `JacScaleConfig`:
- `get_jwt_config()`
- `get_sso_config()`
- `get_database_config()`
- `get_server_config()`
- `get_kubernetes_config()`
- `get_monitoring_config()`
- `get_scheduler_config()`
- `get_telemetry_config()`

---

## jac-scale: ServiceRegistry

**File:** `jac-scale/jac_scale/microservices/service_registry.jac`

```python
from jac_scale.microservices.service_registry import ServiceRegistry, ServiceEntry, ServiceStatus
```

### ServiceEntry fields

```python
ServiceEntry:
    name: str           # e.g. "order_service"
    file: str           # e.g. "order_service.jac"
    prefix: str         # e.g. "/walker/order"
    port: int           # e.g. 18001
    url: str            # e.g. "http://localhost:18001"
    status: ServiceStatus
    # also: replicas, env vars, PID, health check timestamp
```

### ServiceRegistry methods

```python
registry = ServiceRegistry()
registry.register(entry: ServiceEntry) -> None
registry.deregister(name: str) -> bool
registry.match_route(path: str) -> ServiceEntry | None   # longest-prefix matching
registry.health_summary() -> dict[str, dict]
```

`match_route()` sorts prefixes by length descending — longest matching prefix wins.
This is the exact algorithm `bridge/topology.py` must replicate (or can directly use).

### ServiceStatus enum

```python
ServiceStatus.REGISTERED
ServiceStatus.STARTING
ServiceStatus.HEALTHY
ServiceStatus.UNHEALTHY
ServiceStatus.STOPPED
```

---

## jac-scale: Microservice Orchestrator

```python
from jac_scale.microservices.orchestrator import (
    start_microservice_mode,
    start_gateway_only,
    build_registry,
    MicroserviceGateway,
    ServiceProcessManager,
    LocalDeployer,
)
```

`build_registry()` is the function that constructs a `ServiceRegistry` from config.
Useful reference for how `bridge/topology.py` should build its routing table.

---

## jac-scale: Auth (server-side only)

There is **no reusable auth client** in jac-scale for our use case.
The auth module is server-side (FastAPI request handlers).

Our approach: plain `aiohttp` HTTP POST to `/user/login` — correct, no jac-scale import needed.

jac-scale login request shape (confirmed from docs):
```json
POST /user/login
{
  "identity": { "type": "username", "value": "myuser" },
  "credential": { "type": "password", "password": "secret" }
}
```
Response: `{"ok": true, "data": {"token": "eyJ...", "user_id": "...", "role": "user"}}`

---

## jaclang: Runtime API

```python
from jaclang import JacRuntime, JacRuntimeInterface, JacRuntimeImpl, JacMetaImporter
```

`JacRuntime` can execute `.jac` walkers, manage node/edge/archetype systems,
and call walkers from Python. Useful when rewriting tool modules in Jac (Phase 3).

---

## jac-scale: Shared Microservice Utilities

**File:** `jac-scale/jac_scale/microservices/_util.jac`

```python
from jac_scale.microservices._util import pick_free_port, resolve_jac_binary

pick_free_port(name: str, base: int = 18000) -> int
resolve_jac_binary() -> str

# Constants:
DEFAULT_GATEWAY_PORT = 8000
DEFAULT_GATEWAY_HOST = "0.0.0.0"
K8S_CLUSTER_DNS_SUFFIX = "svc.cluster.local"
```

---

## pyproject.toml for jac-loadtest

```toml
[project]
requires-python = ">=3.12"

[project.dependencies]
jaclang  = ">=0.15.2"
jac-scale = ">=0.2.18"
rich = ">=13.0.0"
# aiohttp comes transitively via jac-scale — do not declare separately
```

---

## Migration Path (3 phases)

```
Phase 1 (now):
  Python code → imports jac_scale compiled modules via JacMetaImporter
  bridge/topology.py uses get_scale_config() + ServiceRegistry from disk

Phase 2 (jac-scale integration):
  Python code → calls jac_scale in-process (no disk reads)
  bridge/ becomes native jac-scale plugin code

Phase 3 (Jac rewrite):
  Tool modules rewritten in Jac
  Uses JacRuntime directly
  cli.py becomes plugin.jac entry point
```

Each phase is a module-level change — architecture does not change.
