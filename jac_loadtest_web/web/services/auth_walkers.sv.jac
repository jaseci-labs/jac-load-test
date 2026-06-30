"""Web-app authentication walkers.

These walkers manage user accounts for the jac-loadtest web application.
This is completely separate from the load-test target-app credentials
stored on the Workspace node.

Phase 6 walkers to implement:
  - register_user(email, password) -> {token}
  - login_user(email, password)    -> {token}
  - logout_user()                  -> {ok}
  - me()                           -> {id, email}
"""
