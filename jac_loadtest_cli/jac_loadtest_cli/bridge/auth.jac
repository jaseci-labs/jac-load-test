import csv;
import aiohttp;
import from ..config { LoadTestConfig }

class AuthenticationError(Exception) { }

obj Credential {
    has username: str;
    has password: str;
}

obj AuthProvider {
    has _credentials: list[Credential];
    has _login_path: str = "/user/login";

    class def from_config(config: LoadTestConfig) -> AuthProvider | None {
        if config.credentials_file {
            creds = _load_csv(config.credentials_file);
        } elif config.username and config.password {
            creds = [Credential(username=config.username, password=config.password)];
        } else {
            return None;
        }
        return AuthProvider(_credentials=creds, _login_path=config.login_path);
    }

    def get_credential(vu_id: int) -> Credential {
        return self._credentials[vu_id % len(self._credentials)];
    }

    async def authenticate(vu_id: int, session: aiohttp.ClientSession, base_url: str) -> str {
        cred = self.get_credential(vu_id);
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

def _load_csv(path: str) -> list[Credential] {
    credentials = [];
    with open(path, newline="") as f {
        reader = csv.reader(f);
        i = 0;
        for row in reader {
            if len(row) < 2 {
                i += 1;
                continue;
            }
            username = row[0].strip();
            password = row[1].strip();
            if i == 0 and username.lower() == "username" {
                i += 1;
                continue;
            }
            credentials.append(Credential(username=username, password=password));
            i += 1;
        }
    }
    if not credentials {
        raise ValueError(f"No credentials found in {path!r}");
    }
    return credentials;
}
