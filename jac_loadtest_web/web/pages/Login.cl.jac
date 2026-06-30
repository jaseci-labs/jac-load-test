"""Login page — email + password form."""

import from 'react-router-dom' { useNavigate }
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
        resp = await fetch("/api/auth/login", {
            "method": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": JSON.stringify({"email": email, "password": password})
        });
        data = await resp.json();
        if resp.ok {
            localStorage.setItem("token", data["token"]);
            navigate("/workspaces");
        } else {
            error = data.get("detail", "Login failed");
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
