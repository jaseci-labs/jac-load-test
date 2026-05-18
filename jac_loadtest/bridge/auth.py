"""jac-scale auth: login via /user/login, per-VU JWT injection.

Implemented in Phase 2.
"""
from __future__ import annotations


async def get_token(
    session: object,
    base_url: str,
    username: str,
    password: str,
    login_path: str = "/user/login",
) -> str:
    raise NotImplementedError("Auth module is implemented in Phase 2.")
