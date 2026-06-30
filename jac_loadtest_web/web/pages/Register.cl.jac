"""Register page — email + password + confirm form."""

import from 'react-router-dom' { useNavigate }
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
        resp = await fetch("/api/auth/register", {
            "method": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": JSON.stringify({"email": email, "password": password})
        });
        data = await resp.json();
        if resp.ok {
            localStorage.setItem("token", data["token"]);
            navigate("/workspaces");
        } else {
            error = data.get("detail", "Registration failed");
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
