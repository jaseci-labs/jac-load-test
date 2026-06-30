"""Workspace creation wizard (/workspaces/new) — 3-step form."""

import from 'react-router-dom' { useNavigate }
import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ..components.ui.button { Button }
import from ..components.ui.input { Input }
import from ..components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }  # used in step 1 mode select
import from ..components.ui.field { Field, FieldLabel, FieldContent, FieldError }

def:pub WorkspaceCreate() -> JsxElement {
    has step: int = 1,
        name: str = "",
        mode: str = "monolith",
        target_url: str = "",
        username: str = "",
        password: str = "",
        login_path: str = "/user/login",
        error: str = "",
        loading: bool = False;

    navigate = useNavigate();

    async def handleCreate(e: any) {
        e.preventDefault();
        loading = True;
        error = "";
        resp = await fetch("/api/workspace/create_workspace", {
            "method": "POST",
            "headers": {
                "Content-Type": "application/json",
                "Authorization": "Bearer " + (localStorage.getItem("token") or "")
            },
            "body": JSON.stringify({
                "name": name,
                "mode": mode,
                "target_url": target_url,
                "username": username if username else None,
                "password": password if password else None,
                "login_path": login_path,
                "include_static": False
            })
        });
        if resp.ok {
            ws = await resp.json();
            navigate("/workspaces/" + ws["id"]);
        } else {
            data = await resp.json();
            error = data.get("detail", "Failed to create workspace");
        }
        loading = False;
    }

    step_label = "Workspace details" if step == 1 else ("Target URL" if step == 2 else "Credentials");

    return
        <div className="min-h-screen bg-background p-6">
            <div className="max-w-xl mx-auto flex flex-col gap-6">
                <div>
                    <button
                        onClick={lambda e: any { navigate("/workspaces"); }}
                        className="text-sm text-muted-foreground hover:text-foreground"
                    >
                        ← Back to workspaces
                    </button>
                    <h1 className="text-2xl font-bold mt-2">New workspace</h1>
                </div>

                <Card>
                    <CardHeader>
                        <CardTitle>Step {step} of 3</CardTitle>
                        <CardDescription>{step_label}</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-4">
                        {
                            <div className="flex flex-col gap-4">
                                <Field>
                                    <FieldLabel>Name</FieldLabel>
                                    <FieldContent>
                                        <Input
                                            placeholder="My API workspace"
                                            value={name}
                                            onChange={lambda e: any { name = e.target.value; }}
                                            required={True}
                                        />
                                    </FieldContent>
                                </Field>
                                <Field>
                                    <FieldLabel>Mode</FieldLabel>
                                    <FieldContent>
                                        <Select
                                            value={mode}
                                            onValueChange={lambda v: any { mode = v; }}
                                        >
                                            <SelectTrigger>
                                                <SelectValue />
                                            </SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="monolith">
                                                    Monolith (single URL)
                                                </SelectItem>
                                                <SelectItem value="microservice">
                                                    Microservice (service map)
                                                </SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </FieldContent>
                                </Field>
                            </div>
                            if step == 1 else None
                        }
                        {
                            <Field>
                                <FieldLabel>Target URL</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="url"
                                        placeholder="https://api.example.com"
                                        value={target_url}
                                        onChange={lambda e: any { target_url = e.target.value; }}
                                    />
                                </FieldContent>
                            </Field>
                            if step == 2 else None
                        }
                        {
                            <div className="flex flex-col gap-4">
                                <p className="text-sm text-muted-foreground">
                                    Leave username and password blank for public (unauthenticated) endpoints.
                                    Use the same account that was active when the HAR was recorded.
                                </p>
                                <Field>
                                    <FieldLabel>Username (optional)</FieldLabel>
                                    <FieldContent>
                                        <Input
                                            placeholder="user@example.com"
                                            value={username}
                                            onChange={lambda e: any { username = e.target.value; }}
                                        />
                                    </FieldContent>
                                </Field>
                                <Field>
                                    <FieldLabel>Password (optional)</FieldLabel>
                                    <FieldContent>
                                        <Input
                                            type="password"
                                            placeholder="••••••••"
                                            value={password}
                                            onChange={lambda e: any { password = e.target.value; }}
                                        />
                                    </FieldContent>
                                </Field>
                                <Field>
                                    <FieldLabel>Login path</FieldLabel>
                                    <FieldContent>
                                        <Input
                                            placeholder="/user/login"
                                            value={login_path}
                                            onChange={lambda e: any { login_path = e.target.value; }}
                                        />
                                    </FieldContent>
                                </Field>
                                {<FieldError>{error}</FieldError> if error else None}
                            </div>
                            if step == 3 else None
                        }
                    </CardContent>
                    <CardFooter className="gap-2 justify-end">
                        {
                            <Button
                                variant="outline"
                                onClick={lambda e: any { step = step - 1; }}
                            >
                                Back
                            </Button>
                            if step > 1 else None
                        }
                        {
                            <Button onClick={lambda e: any { step = step + 1; }}>
                                Next
                            </Button>
                            if step < 3 else
                            <Button onClick={handleCreate} disabled={loading}>
                                {"Creating…" if loading else "Create workspace"}
                            </Button>
                        }
                    </CardFooter>
                </Card>
            </div>
        </div>;
}
