"""Web-app authentication walkers.

These walkers manage user accounts for the jac-loadtest web application.
This is completely separate from the load-test target-app credentials
stored on the Workspace node.

register_user / login_user are public (walker:pub) since the caller has no
token yet. logout_user / me are plain walkers, so jac-scale requires a valid
JWT and runs them against the caller's own root — no manual Bearer-header
parsing or 403 checks needed, the framework rejects unauthenticated calls
before the walker body ever runs.

me() needs the token again as an explicit field (redundant with the
Authorization header the framework already validated) rather than reading
identity off `root`: a graph node written from register_user/login_user
would have to be attached from *inside* those calls, but they run
unauthenticated (before the new user has a session), so `root` there is the
anonymous guest root, not the new user's — and jobj(root_id) can resolve the
real root by id but writing to it is correctly blocked by the permission
system (edge_write requires a grant the caller doesn't have). Decoding the
same JWT UserManager already validated and reading identity storage directly
sidesteps that graph-permission wall entirely.

Local dev persistence: no [plugins.scale.database] section is configured in
jac.toml, so jac-scale defaults to local SQLite under .jac/data/ — exactly
the "local development capabilities" this phase is scoped to. Nothing here
needs to change for that; it's already the default.

logout_user cannot revoke the JWT server-side — jac-scale issues stateless
JWTs with no revocation list, so a token stays valid until it expires
regardless of "logout". The client is the actual enforcement point: drop the
token (localStorage removal + jacLogout()) so it's never sent again.
"""

import from jaclang { JacRuntime as Jac }
import from jaclang.jac0core.constructs { Root }

def _find_email(user: dict) -> str {
    for identity in user.get("identities", []) {
        if identity.get("type") == "email" {
            return identity.get("value_raw", "");
        }
    }
    return "";
}

walker:pub register_user {
    has email: str;
    has password: str;

    can register with Root entry {
        user_manager = Jac.get_user_manager(base_path=".");
        result = user_manager.create_user_with_identities(
            identities=[{"type": "email", "value": self.email}],
            credential={"type": "password", "password": self.password},
        );
        if "error" in result {
            report {"error": result["error"]};
            return;
        }
        user_id = result["user_id"];
        token = user_manager.create_jwt_token(user_id);
        report {"token": token, "email": self.email};
    }
}

walker:pub login_user {
    has email: str;
    has password: str;

    can login with Root entry {
        user_manager = Jac.get_user_manager(base_path=".");
        result = user_manager.authenticate(self.email, self.password);
        if not result {
            report {"error": "invalid email or password"};
            return;
        }
        user_id = result["user_id"];
        token = user_manager.create_jwt_token(user_id);
        report {"token": token, "email": self.email};
    }
}

walker logout_user {
    can logout with Root entry {
        # No server-side JWT revocation in jac-scale — see module docstring.
        # This exists for API symmetry / future audit logging; the client
        # dropping the token is what actually ends the session.
        report {"ok": True};
    }
}

walker me {
    has token: str;

    can whoami with Root entry {
        user_manager = Jac.get_user_manager(base_path=".");
        user_id = user_manager.validate_jwt_token(self.token);
        if not user_id {
            report {"error": "invalid or expired token"};
            return;
        }
        user = user_manager.get_user(user_id);
        email = _find_email(user) if user else "";
        report {"id": user_id, "email": email};
    }
}
