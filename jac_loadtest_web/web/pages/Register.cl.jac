"""Register page — email + password + confirm form."""

import from 'react-router-dom' { useNavigate }
import from "@jac/runtime" { jacSetToken, jacLogout }
import from ..services.auth_walkers { register_user }
import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ..components.ui.button { Button }
import from ..components.ui.input { Input }
import from ..components.ui.field { Field, FieldLabel, FieldContent, FieldError }

def:pub Register() -> JsxElement {
    has email: str = "",
        password: str = "",
        confirm: str = "",
        error: str = "",
        loading: bool = False;

    navigate = useNavigate();

    async def handleSubmit(e: any) {
        e.preventDefault();
        if password != confirm {
            error = "Passwords do not match";
            return;
        }
        loading = True;
        error = "";
        # A leftover jac_token from a prior session gets sent as the
        # Authorization header on every RPC call, including this public
        # walker — if it points at a user_id no longer in the identity
        # store, root resolution fails with "User not found" before
        # register_user's body ever runs. Drop it before registering.
        jacLogout();
        result = root spawn register_user(email=email, password=password);
        reply: dict = result.reports[0] if result.reports else {};
        if reply.get("token") {
            localStorage.setItem("token", reply["token"]);
            jacSetToken(reply["token"]);
            navigate("/workspaces");
        } else {
            error = reply.get("error", "Registration failed");
        }
        loading = False;
    }

    return
        <div className="min-h-screen flex items-center justify-center bg-background p-4">
            <Card className="w-full max-w-sm">
                <CardHeader>
                    <CardTitle>Create account</CardTitle>
                    <CardDescription>
                        Sign up to start running load tests
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
                        </Field>
                        <Field>
                            <FieldLabel>Confirm password</FieldLabel>
                            <FieldContent>
                                <Input
                                    type="password"
                                    placeholder="••••••••"
                                    value={confirm}
                                    onChange={lambda e: any { confirm = e.target.value; }}
                                    required={True}
                                />
                            </FieldContent>
                            {<FieldError>{error}</FieldError> if error else None}
                        </Field>
                        <Button type="submit" disabled={loading} className="w-full">
                            {"Creating account…" if loading else "Create account"}
                        </Button>
                    </form>
                </CardContent>
                <CardFooter className="flex-col gap-3">
                    <div className="flex justify-center text-sm gap-1">
                        <span className="text-muted-foreground">Already have an account?</span>
                        <a href="/login" className="text-primary underline-offset-4 hover:underline">
                            Sign in
                        </a>
                    </div>
                    <a href="/" className="text-xs text-muted-foreground hover:text-primary transition-colors underline-offset-4 hover:underline">
                        ← Back to home
                    </a>
                </CardFooter>
            </Card>
        </div>;
}
