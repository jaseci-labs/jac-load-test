import aiohttp;
import from ..config { LoadTestConfig }

class AuthenticationError(Exception) { }

obj Credential {
    has username: str;
    has password: str;
}

obj AuthProvider {
    has _credential: Credential;
    has _login_path: str = "/user/login";

    class def from_config(config: LoadTestConfig) -> AuthProvider | None {
        if config.username and config.password {
            return AuthProvider(
                _credential=Credential(username=config.username, password=config.password),
                _login_path=config.login_path
            );
        }
        return None;
    }

    async def authenticate(vu_id: int, session: aiohttp.ClientSession, base_url: str) -> str {
        cred = self._credential;
        identity_type = "email" if "@" in cred.username else "username";
        payload = {
            "identity": {"type": identity_type, "value": cred.username},
            "credential": {"type": "password", "password": cred.password},
        };
        url = base_url.rstrip("/") + self._login_path;
        try {
            async with session.post(url, json=payload) as resp {
                if resp.status == 401 {
                    raise AuthenticationError(
                        f"Login failed for VU {vu_id} ({identity_type}={cred.username!r}): "
                        "401 Unauthorized — check credentials."
                    );
                }
                if not resp.ok {
                    raise AuthenticationError(
                        f"Login failed for VU {vu_id} ({identity_type}={cred.username!r}): "
                        f"server returned {resp.status}."
                    );
                }
                body = await resp.json();
            }
        } except aiohttp.ClientConnectorError as exc {
            raise AuthenticationError(
                f"Cannot reach login endpoint {url!r}: {exc}"
            ) from exc;
        }
        try {
            return body["data"]["token"];
        } except (KeyError, TypeError) as exc {
            raise AuthenticationError(
                f"Unexpected login response shape from {url!r}: {body!r}"
            ) from exc;
        }
    }
}

