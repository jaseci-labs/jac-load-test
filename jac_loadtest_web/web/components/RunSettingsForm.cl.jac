"""RunSettingsForm — VUs, stop condition, advanced options, thresholds."""

import from .ui.card { Card, CardHeader, CardTitle, CardContent, CardFooter }
import from .ui.button { Button }
import from .ui.input { Input }
import from .ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from .ui.field { Field, FieldLabel, FieldContent }
import from .ui.collapsible { Collapsible, CollapsibleTrigger, CollapsibleContent }
import from .ui.separator { Separator }
import from .ui.switch { Switch }

def:pub RunSettingsForm(
    on_submit: object,
    submitting: bool = False
) -> JsxElement {
    has vus: int = 10,
        stop_mode: str = "duration",
        duration: str = "60",
        iterations: int = 100,
        ramp_up: int = 0,
        rps_cap: int = 0,
        think_time: float = 0.0,
        timeout: int = 30,
        fail_on_error_rate: float = 0.0,
        fail_on_p95: float = 0.0,
        fail_on_p99: float = 0.0,
        abort_on_fail: bool = False,
        label: str = "",
        advanced_open: bool = False,
        threshold_open: bool = False;

    async def handleSubmit(e: any) {
        e.preventDefault();
        settings = {
            "vus": vus,
            "duration": (duration if stop_mode == "duration" else None),
            "iterations": (iterations if stop_mode == "iterations" else None),
            "ramp_up": ramp_up,
            "rps": rps_cap,
            "think_time": think_time,
            "timeout": timeout,
            "fail_on_error_rate": (fail_on_error_rate if fail_on_error_rate > 0 else None),
            "fail_on_p95": (fail_on_p95 if fail_on_p95 > 0 else None),
            "fail_on_p99": (fail_on_p99 if fail_on_p99 > 0 else None),
            "abort_on_fail": abort_on_fail,
            "label": (label if label else None)
        };
        await on_submit(settings);
    }

    return
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <Card>
                <CardHeader>
                    <CardTitle className="text-sm">Load settings</CardTitle>
                </CardHeader>
                <CardContent className="flex flex-col gap-4">
                    <Field>
                        <FieldLabel>Virtual users (VUs)</FieldLabel>
                        <FieldContent>
                            <Input
                                type="number"
                                min="1"
                                value={str(vus)}
                                onChange={lambda e: any { vus = int(e.target.value or "1"); }}
                                required={True}
                            />
                        </FieldContent>
                    </Field>

                    <Field>
                        <FieldLabel>Stop condition</FieldLabel>
                        <FieldContent>
                            <Select
                                value={stop_mode}
                                onValueChange={lambda v: any { stop_mode = v; }}
                            >
                                <SelectTrigger>
                                    <SelectValue />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="duration">Duration (seconds)</SelectItem>
                                    <SelectItem value="iterations">Iterations</SelectItem>
                                </SelectContent>
                            </Select>
                        </FieldContent>
                    </Field>

                    {
                        <Field>
                            <FieldLabel>Duration (s)</FieldLabel>
                            <FieldContent>
                                <Input
                                    type="number"
                                    min="1"
                                    value={duration}
                                    onChange={lambda e: any { duration = e.target.value; }}
                                />
                            </FieldContent>
                        </Field>
                        if stop_mode == "duration" else
                        <Field>
                            <FieldLabel>Iterations</FieldLabel>
                            <FieldContent>
                                <Input
                                    type="number"
                                    min="1"
                                    value={str(iterations)}
                                    onChange={lambda e: any { iterations = int(e.target.value or "1"); }}
                                />
                            </FieldContent>
                        </Field>
                    }
                </CardContent>
            </Card>

            <Collapsible
                open={advanced_open}
                onOpenChange={lambda v: any { advanced_open = v; }}
            >
                <CollapsibleTrigger asChild={True}>
                    <button
                        type="button"
                        className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground w-full py-1"
                    >
                        <span>{"▼" if advanced_open else "▶"}</span>
                        <span>Advanced options</span>
                    </button>
                </CollapsibleTrigger>
                <CollapsibleContent>
                    <Card className="mt-2">
                        <CardContent className="pt-4 flex flex-col gap-4">
                            <Field>
                                <FieldLabel>Ramp-up (s)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(ramp_up)}
                                        onChange={lambda e: any { ramp_up = int(e.target.value or "0"); }}
                                    />
                                </FieldContent>
                            </Field>
                            <Field>
                                <FieldLabel>RPS cap (0 = unlimited)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(rps_cap)}
                                        onChange={lambda e: any { rps_cap = int(e.target.value or "0"); }}
                                    />
                                </FieldContent>
                            </Field>
                            <Field>
                                <FieldLabel>Think time (s)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        step="0.1"
                                        value={str(think_time)}
                                        onChange={lambda e: any { think_time = float(e.target.value or "0"); }}
                                    />
                                </FieldContent>
                            </Field>
                            <Field>
                                <FieldLabel>Request timeout (s)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="1"
                                        value={str(timeout)}
                                        onChange={lambda e: any { timeout = int(e.target.value or "30"); }}
                                    />
                                </FieldContent>
                            </Field>
                        </CardContent>
                    </Card>
                </CollapsibleContent>
            </Collapsible>

            <Collapsible
                open={threshold_open}
                onOpenChange={lambda v: any { threshold_open = v; }}
            >
                <CollapsibleTrigger asChild={True}>
                    <button
                        type="button"
                        className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground w-full py-1"
                    >
                        <span>{"▼" if threshold_open else "▶"}</span>
                        <span>Thresholds</span>
                    </button>
                </CollapsibleTrigger>
                <CollapsibleContent>
                    <Card className="mt-2">
                        <CardContent className="pt-4 flex flex-col gap-4">
                            <Field>
                                <FieldLabel>Fail if error rate exceeds (%, 0 = off)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        max="100"
                                        step="0.1"
                                        value={str(fail_on_error_rate)}
                                        onChange={lambda e: any {
                                            fail_on_error_rate = float(e.target.value or "0");
                                        }}
                                    />
                                </FieldContent>
                            </Field>
                            <Field>
                                <FieldLabel>Fail if p95 exceeds (ms, 0 = off)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(fail_on_p95)}
                                        onChange={lambda e: any {
                                            fail_on_p95 = float(e.target.value or "0");
                                        }}
                                    />
                                </FieldContent>
                            </Field>
                            <Field>
                                <FieldLabel>Fail if p99 exceeds (ms, 0 = off)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(fail_on_p99)}
                                        onChange={lambda e: any {
                                            fail_on_p99 = float(e.target.value or "0");
                                        }}
                                    />
                                </FieldContent>
                            </Field>
                            <div className="flex items-center gap-3">
                                <Switch
                                    checked={abort_on_fail}
                                    onCheckedChange={lambda v: any { abort_on_fail = v; }}
                                />
                                <span className="text-sm">Abort run when threshold exceeded</span>
                            </div>
                        </CardContent>
                    </Card>
                </CollapsibleContent>
            </Collapsible>

            <Field>
                <FieldLabel>Label (optional)</FieldLabel>
                <FieldContent>
                    <Input
                        placeholder="e.g. baseline, after-deploy"
                        value={label}
                        onChange={lambda e: any { label = e.target.value; }}
                    />
                </FieldContent>
            </Field>

            <Button type="submit" disabled={submitting} className="w-full">
                {"Starting run…" if submitting else "Start run"}
            </Button>
        </form>;
}
