"""Register page — email + password + confirm form.

Uses jac-scale's built-in auth helpers (jacSignup + jacLogin against
/user/register + /user/login) rather than a hand-rolled walker — see jac
guide jac-cl-auth. jacSignup does NOT establish a session by itself; it
must always be followed by jacLogin with the same credentials.
"""

import from 'react-router-dom' { useNavigate }
import from "@jac/runtime" { jacSignup, jacLogin }
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
        # Pre-declare vars holding awaited results before assigning — see
        # jac-cl-auth: `var = await fn()` can compile to a JS `let` scoped
        # tighter than this function, making a later `if not var` throw
        # ReferenceError. jacSignup returns a dict, jacLogin a bool.
        signup_result: dict | None = None;
        login_ok: bool = False;
        signup_result = await jacSignup(email, password);
        if not signup_result["success"] {
            error = signup_result.get("error", "Registration failed");
            loading = False;
            return;
        }
        login_ok = await jacLogin(email, password);
        if login_ok {
            navigate("/workspaces");
        } else {
            error = "Account created, but sign-in failed — try logging in";
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
