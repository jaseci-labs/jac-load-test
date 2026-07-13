"""Workspace creation wizard (/workspaces/new) — 5-step form.

Step 1: name, description, mode
Step 2: target (monolith URL w/ reachability ping, or microservice service map)
Step 3: HAR file upload + entry review table
Step 4: target-app credentials
Step 5: review + create

HAR capture is file-upload only in this pass — no live proxy recorder yet.
"""

import from 'react-router-dom' { useNavigate }
import from ..services.workspace_walkers { create_workspace, check_reachability }
import from ..services.file_walkers { upload_har }
import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ..components.ui.button { Button }
import from ..components.ui.input { Input }
import from ..components.ui.textarea { Textarea }
import from ..components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ..components.ui.field { Field, FieldLabel, FieldContent, FieldError }
import from ..components.ThemeToggle { ThemeToggle }
import from ..components.ui.badge { Badge }
import from ..components.ui.spinner { Spinner }
import from ..components.HarEntryTable { HarEntryTable }

glob _STEP_LABELS: list[str] = [
    "Workspace details", "Target", "HAR recording", "Credentials", "Review & create"
];

def:pub WorkspaceCreate() -> JsxElement {
    has step: int = 1,
        name: str = "",
        description: str = "",
        mode: str = "monolith",

        target_url: str = "",
        checking_reachability: bool = False,
        reachability_result: dict | None = None,

        service_map_mode: str = "rows",
        services: list[dict] = [],
        services_json_text: str = "",

        har_entries: list[dict] = [],
        har_raw_json: str = "",
        har_security_warning: bool = False,
        har_filename: str = "",
        uploading_har: bool = False,
        har_error: str = "",

        credential_mode: str = "none",
        username: str = "",
        password: str = "",
        login_path: str = "/user/login",

        error: str = "",
        creating: bool = False;

    navigate = useNavigate();

    def canAdvance() -> bool {
        if step == 1 {
            return len(name) > 0;
        }
        if step == 2 {
            if mode == "monolith" {
                return len(target_url) > 0;
            }
            return len(services) > 0 or len(services_json_text) > 0;
        }
        if step == 3 {
            return len(har_entries) > 0;
        }
        if step == 4 {
            if credential_mode == "single" {
                return len(username) > 0 and len(password) > 0;
            }
            return True;
        }
        return True;
    }

    def goNext(_e: any) {
        step = step + 1;
    }

    def goBack(_e: any) {
        step = step - 1;
    }

    async def checkReachability(_e: any) {
        checking_reachability = True;
        reachability_result = None;
        result = root spawn check_reachability(url=target_url);
        reachability_result = result.reports[0] if result.reports else {"reachable": False, "error": "No response"};
        checking_reachability = False;
    }

    def addServiceRow(_e: any) {
        services = services + [{"name": "", "url": ""}];
    }

    def removeServiceRow(idx: int) {
        services = [s for (i, s) in enumerate(services) if i != idx];
    }

    def updateServiceRow(idx: int, key: str, value: str) {
        updated = [{**s} for s in services];
        updated[idx][key] = value;
        services = updated;
    }

    def servicesMapJson() -> str {
        if service_map_mode == "json" {
            return services_json_text;
        }
        mapping: dict = {};
        for s in services {
            if s.get("name") and s.get("url") {
                mapping[s["name"]] = s["url"];
            }
        }
        return JSON.stringify(mapping) if len(mapping) > 0 else "";  # jac:ignore[W6001,W6002]
    }

    async def handleHarFile(e: any) {
        files = e.target.files;
        if not files or len(files) == 0 {
            return;
        }
        file = files[0];
        har_filename = file.name;
        uploading_har = True;
        har_error = "";

        # upload_har takes a File — root spawn only carries JSON bodies (a
        # File can't serialize through it, so the server sees no file at
        # all). A raw multipart POST to the walker's default REST path is
        # the only way to actually send it; sv import is used for every
        # other walker in this file, only this one needs the raw form.
        form_data = new(FormData);
        form_data.append("file", file);
        resp = await fetch("/walker/upload_har", {
            "method": "POST",
            # Built-in jacLogin/jacSignup store the JWT under "jac_token"
            # (see jacSetToken in @jac/runtime) — read the same key here.
            "headers": {"Authorization": "Bearer " + (localStorage.getItem("jac_token") or "")},
            "body": form_data,
        });
        data = await resp.json();
        if not data.get("ok") {
            har_error = data.get("error", {}).get("message", "Failed to parse HAR file");
        } else {
            reply: dict = data["data"]["reports"][0] if data["data"]["reports"] else {};
            if reply.get("error") {
                har_error = reply["error"];
            } else {
                har_entries = reply.get("entries", []);
                har_raw_json = reply.get("har_raw_json", "");
                har_security_warning = reply.get("security_warning", False);
            }
        }
        uploading_har = False;
    }

    def onToggleHarEntry(idx: int, enabled: bool) {
        updated = [{**e} for e in har_entries];
        updated[idx]["enabled"] = enabled;
        har_entries = updated;
    }

    async def handleCreate(_e: any) {
        creating = True;
        error = "";
        result = root spawn create_workspace(
            name=name,
            description=description,
            mode=mode,
            target_url=target_url if mode == "monolith" else None,
            services_map_json=servicesMapJson() if mode == "microservice" else None,
            username=username if credential_mode == "single" else None,
            password=password if credential_mode == "single" else None,
            login_path=login_path,
            include_static=False,
            har_raw_json=har_raw_json if har_raw_json else None,
            har_entries_json=JSON.stringify(har_entries) if len(har_entries) > 0 else None,  # jac:ignore[W6001,W6002]
        );
        reply: dict = result.reports[0] if result.reports else {};
        if reply.get("error") {
            error = reply["error"];
            creating = False;
        } elif reply.get("id") {
            navigate("/workspaces/" + reply["id"]);
        } else {
            error = "Failed to create workspace";
            creating = False;
        }
    }

    enabled_count = len([e for e in har_entries if e.get("enabled", True)]);

    return
        <div className="min-h-screen bg-background p-6">
            <div className="max-w-2xl mx-auto flex flex-col gap-6">
                <div className="flex items-start justify-between">
                    <div>
                        <button
                            onClick={lambda e: any { navigate("/workspaces"); }}
                            className="text-sm text-muted-foreground hover:text-foreground"
                        >
                            ← Back to workspaces
                        </button>
                        <h1 className="text-2xl font-bold mt-2">New workspace</h1>
                    </div>
                    <ThemeToggle />
                </div>

                <Card>
                    <CardHeader>
                        <CardTitle>Step {str(step)} of 5</CardTitle>
                        <CardDescription>{_STEP_LABELS[step - 1]}</CardDescription>
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
                                    <FieldLabel>Description (optional)</FieldLabel>
                                    <FieldContent>
                                        <Textarea
                                            placeholder="What does this workspace test?"
                                            value={description}
                                            onChange={lambda e: any { description = e.target.value; }}
                                        />
                                    </FieldContent>
                                </Field>
                                <Field>
                                    <FieldLabel>Mode</FieldLabel>
                                    <FieldContent>
                                        <Select value={mode} onValueChange={lambda v: any { mode = v; }}>
                                            <SelectTrigger>
                                                <SelectValue />
                                            </SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="monolith">Monolith (single URL)</SelectItem>
                                                <SelectItem value="microservice">Microservice (service map)</SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </FieldContent>
                                </Field>
                            </div>
                            if step == 1 else None
                        }

                        {
                            <div className="flex flex-col gap-4">
                                {
                                    <div className="flex flex-col gap-3">
                                        <Field>
                                            <FieldLabel>Target URL</FieldLabel>
                                            <FieldContent>
                                                <Input
                                                    type="url"
                                                    placeholder="https://api.example.com"
                                                    value={target_url}
                                                    onChange={lambda e: any {
                                                        target_url = e.target.value;
                                                        reachability_result = None;
                                                    }}
                                                    required={True}
                                                />
                                            </FieldContent>
                                        </Field>
                                        <div className="flex items-center gap-2">
                                            <Button
                                                type="button"
                                                variant="outline"
                                                size="sm"
                                                disabled={checking_reachability or len(target_url) == 0}
                                                onClick={checkReachability}
                                            >
                                                {"Checking…" if checking_reachability else "Check reachability"}
                                            </Button>
                                            {
                                                <Badge variant={"default" if reachability_result.get("reachable") else "destructive"}>
                                                    {
                                                        ("Reachable (" + str(reachability_result.get("status")) + ")")
                                                        if reachability_result.get("reachable")
                                                        else ("Unreachable: " + str(reachability_result.get("error", "")))
                                                    }
                                                </Badge>
                                                if reachability_result is not None else None
                                            }
                                        </div>
                                        <p className="text-xs text-muted-foreground">
                                            Unreachable doesn't block workspace creation — the sv server may not
                                            have network access to a target reachable from real load-test traffic.
                                        </p>
                                    </div>
                                    if mode == "monolith" else
                                    <div className="flex flex-col gap-3">
                                        <div className="flex items-center gap-2">
                                            <Button
                                                type="button"
                                                variant={"default" if service_map_mode == "rows" else "outline"}
                                                size="sm"
                                                onClick={lambda e: any { service_map_mode = "rows"; }}
                                            >
                                                Row builder
                                            </Button>
                                            <Button
                                                type="button"
                                                variant={"default" if service_map_mode == "json" else "outline"}
                                                size="sm"
                                                onClick={lambda e: any { service_map_mode = "json"; }}
                                            >
                                                Paste JSON
                                            </Button>
                                        </div>
                                        {
                                            <div className="flex flex-col gap-2">
                                                {[
                                                    <div key={str(idx)} className="flex items-center gap-2">
                                                        <Input
                                                            placeholder="service_name"
                                                            value={svc.get("name", "")}
                                                            onChange={lambda e: any { updateServiceRow(idx, "name", e.target.value); }}
                                                            className="w-1/3"
                                                        />
                                                        <Input
                                                            placeholder="http://service:8000"
                                                            value={svc.get("url", "")}
                                                            onChange={lambda e: any { updateServiceRow(idx, "url", e.target.value); }}
                                                        />
                                                        <Button
                                                            type="button"
                                                            variant="ghost"
                                                            size="sm"
                                                            onClick={lambda e: any { removeServiceRow(idx); }}
                                                        >
                                                            Remove
                                                        </Button>
                                                    </div>
                                                    for (idx, svc) in enumerate(services)
                                                ]}
                                                <Button type="button" variant="outline" size="sm" onClick={addServiceRow}>
                                                    + Add service
                                                </Button>
                                            </div>
                                            if service_map_mode == "rows" else
                                            <Textarea
                                                placeholder={'{"order_service": "http://order:8001", "inventory_service": "http://inventory:8002"}'}
                                                value={services_json_text}
                                                onChange={lambda e: any { services_json_text = e.target.value; }}
                                                className="font-mono text-xs min-h-32"
                                            />
                                        }
                                    </div>
                                }
                            </div>
                            if step == 2 else None
                        }

                        {
                            <div className="flex flex-col gap-4">
                                <Field>
                                    <FieldLabel>HAR file</FieldLabel>
                                    <FieldContent>
                                        <input
                                            type="file"
                                            accept=".har,application/json"
                                            onChange={handleHarFile}
                                            className="text-sm"
                                        />
                                    </FieldContent>
                                </Field>
                                {<p className="text-sm text-muted-foreground">Parsing {har_filename}…</p> if uploading_har else None}
                                {<FieldError>{har_error}</FieldError> if har_error else None}
                                {
                                    <p className="text-sm text-muted-foreground">
                                        {str(enabled_count) + " of " + str(len(har_entries)) + " requests enabled"}
                                    </p>
                                    if len(har_entries) > 0 else
                                    <p className="text-xs text-muted-foreground">
                                        A HAR file is required to continue.
                                    </p>
                                    if not uploading_har else None
                                }
                                <HarEntryTable entries={har_entries} on_toggle={onToggleHarEntry} />
                            </div>
                            if step == 3 else None
                        }

                        {
                            <div className="flex flex-col gap-4">
                                <Field>
                                    <FieldLabel>Target-app authentication</FieldLabel>
                                    <FieldContent>
                                        <Select value={credential_mode} onValueChange={lambda v: any { credential_mode = v; }}>
                                            <SelectTrigger>
                                                <SelectValue />
                                            </SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="none">None (unauthenticated)</SelectItem>
                                                <SelectItem value="single">Single credential (shared by all VUs)</SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </FieldContent>
                                </Field>
                                {
                                    <div className="flex flex-col gap-4">
                                        <p className="text-sm text-muted-foreground">
                                            Use the same account that was active when the HAR was recorded.
                                        </p>
                                        <Field>
                                            <FieldLabel>Username</FieldLabel>
                                            <FieldContent>
                                                <Input
                                                    placeholder="user@example.com"
                                                    value={username}
                                                    onChange={lambda e: any { username = e.target.value; }}
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
                                            <FieldLabel>Login path</FieldLabel>
                                            <FieldContent>
                                                <Input
                                                    placeholder="/user/login"
                                                    value={login_path}
                                                    onChange={lambda e: any { login_path = e.target.value; }}
                                                />
                                            </FieldContent>
                                        </Field>
                                    </div>
                                    if credential_mode == "single" else None
                                }
                            </div>
                            if step == 4 else None
                        }

                        {
                            <div className="flex flex-col gap-4">
                                <div className="rounded-lg border border-border p-4 flex flex-col gap-2 text-sm">
                                    <div className="flex justify-between">
                                        <span className="text-muted-foreground">Name</span>
                                        <span className="font-medium">{name}</span>
                                    </div>
                                    <div className="flex justify-between">
                                        <span className="text-muted-foreground">Mode</span>
                                        <span className="font-medium">{mode}</span>
                                    </div>
                                    <div className="flex justify-between">
                                        <span className="text-muted-foreground">Target</span>
                                        <span className="font-medium font-mono text-xs">
                                            {target_url if mode == "monolith" else (str(len(services)) + " services")}
                                        </span>
                                    </div>
                                    <div className="flex justify-between">
                                        <span className="text-muted-foreground">HAR entries</span>
                                        <span className="font-medium">
                                            {str(enabled_count) + " of " + str(len(har_entries)) + " enabled"}
                                        </span>
                                    </div>
                                    <div className="flex justify-between">
                                        <span className="text-muted-foreground">Credentials</span>
                                        <span className="font-medium">
                                            {"None" if credential_mode == "none" else ("Single (" + username + ")")}
                                        </span>
                                    </div>
                                </div>
                                {<FieldError>{error}</FieldError> if error else None}
                            </div>
                            if step == 5 else None
                        }

                    </CardContent>
                    <CardFooter className="gap-2 justify-end">
                        {
                            <Button variant="outline" onClick={goBack} disabled={creating}>
                                Back
                            </Button>
                            if step > 1 else None
                        }
                        {
                            <Button onClick={goNext} disabled={not canAdvance()}>
                                Next
                            </Button>
                            if step < 5 else
                            <Button onClick={handleCreate} disabled={creating}>
                                {
                                    (<span className="flex items-center gap-2"><Spinner className="size-4" /> Creating…</span>)
                                    if creating else "Create workspace"
                                }
                            </Button>
                        }
                    </CardFooter>
                </Card>
            </div>
        </div>;
}
