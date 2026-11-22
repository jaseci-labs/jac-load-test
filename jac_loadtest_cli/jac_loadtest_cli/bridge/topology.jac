import json;
import os;
import from urllib.parse { urlparse, urlunparse }
import from ..config { LoadTestConfig }

obj ServiceRoute {
    has name: str;
    has prefix: str;
    has url: str;
}

obj TopologyRouter {
    has _routes: list[ServiceRoute];
    has _fallback_url: str | None = None;

    def __post_init__() {
        self._routes = sorted(self._routes, key=lambda (r: ServiceRoute) { return len(r.prefix); }, reverse=True);
    }

    def resolve(entry_url: str) -> tuple[str, str] {
        parsed = urlparse(entry_url);
        path = parsed.path;

        for route in self._routes {
            if _prefix_matches(path, route.prefix) {
                t = urlparse(route.url);
                if route.prefix {
                    service_path = path[len(route.prefix):] or "/";
                } else {
                    service_path = path;
                }
                base_path = t.path.rstrip("/") if t.path else "";
                routed_path = f"{base_path}{service_path}" if base_path else service_path;
                routed = urlunparse((
                    t.scheme, t.netloc,
                    routed_path, parsed.params, parsed.query, "",
                ));
                return (routed, route.name);
            }
        }

        if self._fallback_url {
            t = urlparse(self._fallback_url);
            base_path = t.path.rstrip("/") if t.path else "";
            routed_path = f"{base_path}{path}" if base_path else path;
            routed = urlunparse((
                t.scheme, t.netloc,
                routed_path, parsed.params, parsed.query, "",
            ));
            return (routed, "gateway");
        }

        raise ValueError(
            f"No route for path '{path}' and no --url fallback provided. "
            "Use --services-map or declare service apps ([apps.<name>] kind = \"service\") in jac.toml."
        );
    }

    class def from_config(config: LoadTestConfig) -> TopologyRouter {
        if config.mode != "microservice" {
            return TopologyRouter(
                _routes=[ServiceRoute(name="monolith", prefix="", url=config.url or "")],
                _fallback_url=None,
            );
        }
        return _build_microservice_topology(config);
    }
}

def _build_microservice_topology(config: LoadTestConfig) -> TopologyRouter {
    toml_routes = _load_toml_routes();

    if config.services_map {
        try {
            services_json = json.loads(config.services_map);
        } except json.JSONDecodeError as exc {
            raise ValueError(f"--services-map is not valid JSON: {exc}") from exc;
        }

        routes = [];
        for item in services_json.items() {
            name = item[0];
            url = item[1];
            prefix = toml_routes.get(name);
            if prefix is None {
                if name.startswith("/") {
                    prefix = name;
                } else {
                    raise ValueError(
                        f"--services-map key '{name}' is not a service app declared in jac.toml "
                        "and does not start with '/'. "
                        f"Use a path prefix as the key or declare '[apps.{name}]' with kind = \"service\" in jac.toml."
                    );
                }
            }
            routes.append(ServiceRoute(
                name=name.lstrip("/") if name.startswith("/") else name,
                prefix=prefix,
                url=url.rstrip("/"),
            ));
        }
        return TopologyRouter(_routes=routes, _fallback_url=config.url);
    }

    if not toml_routes {
        raise ValueError(
            "Microservice mode requires either --services-map or "
            "service apps ([apps.<name>] kind = \"service\") in jac.toml. Neither was found."
        );
    }

    routes = [];
    missing = [];
    for item in toml_routes.items() {
        name = item[0];
        prefix = item[1];
        env_var = _app_url_env_var(name);
        url = os.environ.get(env_var);
        if not url {
            missing.append(env_var);
        } else {
            routes.append(ServiceRoute(name=name, prefix=prefix, url=url.rstrip("/")));
        }
    }

    if missing {
        raise ValueError(
            f"Microservice mode: missing environment variable(s): {', '.join(missing)}. "
            "Expected format: JAC_APP_<APP_NAME>_URL=http://host:port"
        );
    }

    return TopologyRouter(_routes=routes, _fallback_url=config.url);
}

def _prefix_matches(path: str, prefix: str) -> bool {
    if not prefix {
        return True;
    }
    return path == prefix or path.startswith(prefix + "/");
}

def _app_url_env_var(app_name: str) -> str {
    # Same sanitising as jaclang.server.sv_client.peer_url_env_key: every
    # non-alphanumeric character becomes "_", so "order-service" -> ORDER_SERVICE.
    safe = "".join(ch if ch.isalnum() else "_" for ch in app_name);
    return f"JAC_APP_{safe.upper()}_URL";
}

def _load_toml_routes -> dict[str, str] {
    # Service apps declared in jac.toml: app name -> public route prefix
    # (the app's `route`, defaulting to /api/<name>).
    try {
        import from pathlib { Path }
        import from jaclang.project.config { get_config }
        jac_config = get_config(Path.cwd(), True);
        if jac_config is None {
            return {};
        }
        routes: dict[str, str] = {};
        for app in jac_config.serving_apps() {
            if app.kind == "service" {
                routes[app.name] = app.effective_route();
            }
        }
        return routes;
    } except Exception {
        return {};
    }
}
