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
    # The engine's only stop condition is iterations (N HAR replays per VU) —
    # there's no wall-clock duration concept in LoadTestConfig, so this form
    # doesn't offer one.
    has vus: int = 10,
        iterations: int = 100,
        ramp_up: int = 0,
        workers: int = 0,
        rps_cap: int = 0,
        think_time_mode: str = "none",
        think_time_scale: float = 1.0,
        timeout: int = 30,
        fail_on_error_rate: float = 0.0,
        fail_on_p95: float = 0.0,
        fail_on_p99: float = 0.0,
        abort_on_fail: bool = False,
        threshold_start_delay: int = 0,
        label: str = "",
        advanced_open: bool = False,
        threshold_open: bool = False;

    async def handleSubmit(e: any) {
        e.preventDefault();
        settings = {
            "vus": vus,
            "iterations": iterations,
            "ramp_up": ramp_up,
            "workers": workers,
            "rps": rps_cap,
            "think_time": think_time_mode,
            "think_time_scale": think_time_scale,
            "timeout": timeout,
            "fail_on_error_rate": (fail_on_error_rate if fail_on_error_rate > 0 else None),
            "fail_on_p95": (fail_on_p95 if fail_on_p95 > 0 else None),
            "fail_on_p99": (fail_on_p99 if fail_on_p99 > 0 else None),
            "abort_on_fail": abort_on_fail,
            "threshold_start_delay": threshold_start_delay,
            "label": label
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
                        <FieldLabel>Iterations per VU</FieldLabel>
                        <FieldContent>
                            <Input
                                type="number"
                                min="1"
                                value={str(iterations)}
                                onChange={lambda e: any { iterations = int(e.target.value or "1"); }}
                            />
                        </FieldContent>
                    </Field>
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
                                <FieldLabel>Worker processes (blank/0 = CPU count)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(workers)}
                                        onChange={lambda e: any { workers = int(e.target.value or "0"); }}
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
                                <FieldLabel>Think time</FieldLabel>
                                <FieldContent>
                                    <Select
                                        value={think_time_mode}
                                        onValueChange={lambda v: any { think_time_mode = v; }}
                                    >
                                        <SelectTrigger>
                                            <SelectValue />
                                        </SelectTrigger>
                                        <SelectContent>
                                            <SelectItem value="none">None</SelectItem>
                                            <SelectItem value="real">Real (as recorded)</SelectItem>
                                            <SelectItem value="scaled">Scaled</SelectItem>
                                        </SelectContent>
                                    </Select>
                                </FieldContent>
                            </Field>
                            {
                                <Field>
                                    <FieldLabel>Think time scale multiplier</FieldLabel>
                                    <FieldContent>
                                        <Input
                                            type="number"
                                            min="0"
                                            step="0.1"
                                            value={str(think_time_scale)}
                                            onChange={lambda e: any {
                                                think_time_scale = float(e.target.value or "1.0");
                                            }}
                                        />
                                    </FieldContent>
                                </Field>
                                if think_time_mode == "scaled" else None
                            }
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
                            <Field>
                                <FieldLabel>Threshold evaluation delay (s, cold-start protection)</FieldLabel>
                                <FieldContent>
                                    <Input
                                        type="number"
                                        min="0"
                                        value={str(threshold_start_delay)}
                                        onChange={lambda e: any {
                                            threshold_start_delay = int(e.target.value or "0");
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
                <FieldLabel>Label</FieldLabel>
                <FieldContent>
                    <Input
                        placeholder="e.g. baseline, after-deploy"
                        value={label}
                        onChange={lambda e: any { label = e.target.value; }}
                        required={True}
                    />
                </FieldContent>
            </Field>

            <Button type="submit" disabled={submitting or len(label.strip()) == 0} className="w-full">
                {"Starting run…" if submitting else "Start run"}
            </Button>
        </form>;
}
