"""Login page — email + password form."""

import from 'react-router-dom' { useNavigate }
import from "@jac/runtime" { jacSetToken, jacLogout }
import from ..services.auth_walkers { login_user }
import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ..components.ui.button { Button }
import from ..components.ui.input { Input }
import from ..components.ui.field { Field, FieldLabel, FieldContent, FieldError }

def:pub Login() -> JsxElement {
    has email: str = "",
        password: str = "",
        error: str = "",
        loading: bool = False;

    navigate = useNavigate();

    async def handleSubmit(e: any) {
        e.preventDefault();
        loading = True;
        error = "";
        # A leftover jac_token from a prior session gets sent as the
        # Authorization header on every RPC call, including this public
        # walker — if it points at a user_id no longer in the identity
        # store, root resolution fails with "User not found" before
        # login_user's body ever runs. Drop it before authenticating.
        jacLogout();
        result = root spawn login_user(email=email, password=password);
        reply: dict = result.reports[0] if result.reports else {};
        if reply.get("token") {
            localStorage.setItem("token", reply["token"]);
            jacSetToken(reply["token"]);
            navigate("/workspaces");
        } else {
            error = reply.get("error", "Login failed");
        }
        loading = False;
    }

    return
        <div className="min-h-screen flex items-center justify-center bg-background p-4">
            <Card className="w-full max-w-sm">
                <CardHeader>
                    <CardTitle>Sign in</CardTitle>
                    <CardDescription>
                        Enter your credentials to access jac-loadtest
                    </CardDescription>
                </CardHeader>
                <CardContent>
                    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
                        <Field>
                            <FieldLabel>Email</FieldLabel>
                            <FieldContent>
                                <Input
                                    type="email"
                                    placeholder="you@example.com"
                                    value={email}
                                    onChange={lambda e: any { email = e.target.value; }}
                                    required={True}
                                />
                            </FieldContent>
                        </Field>
                        <Field>
                            <FieldLabel>Password</FieldLabel>
                            <FieldContent>
                                <Input
                                    type="password"
                                    placeholder="••••••••"
                                    value={password}
                                    onChange={lambda e: any { password = e.target.value; }}
                                    required={True}
                                />
                            </FieldContent>
                            {<FieldError>{error}</FieldError> if error else None}
                        </Field>
                        <Button type="submit" disabled={loading} className="w-full">
                            {"Signing in…" if loading else "Sign in"}
                        </Button>
                    </form>
                </CardContent>
                <CardFooter className="flex-col gap-3">
                    <div className="flex justify-center text-sm gap-1">
                        <span className="text-muted-foreground">No account?</span>
                        <a href="/register" className="text-primary underline-offset-4 hover:underline">
                            Register
                        </a>
                    </div>
                    <a href="/" className="text-xs text-muted-foreground hover:text-primary transition-colors underline-offset-4 hover:underline">
                        ← Back to home
                    </a>
                </CardFooter>
            </Card>
        </div>;
}
