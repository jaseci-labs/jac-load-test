"""RunControl — live metrics bar shown during an active run."""

import from .ui.card { Card, CardContent }
import from .ui.badge { Badge }
import from .ui.button { Button }
import from .ui.progress { Progress }

def:pub RunControl(
    run_id: str,
    status: str,
    elapsed_s: float = 0.0,
    active_vus: int = 0,
    rps: float = 0.0,
    error_rate: float = 0.0,
    on_stop: object = None
) -> JsxElement {
    elapsed_min = int(elapsed_s // 60);
    elapsed_sec = int(elapsed_s % 60);
    elapsed_str = str(elapsed_min) + ":" + ("0" if elapsed_sec < 10 else "") + str(elapsed_sec);

    error_variant = "destructive" if error_rate > 5.0 else ("default" if error_rate > 1.0 else "secondary");

    return
        <Card>
            <CardContent className="pt-4">
                <div className="flex flex-wrap items-center gap-6">
                    <div className="flex flex-col gap-0.5">
                        <span className="text-xs text-muted-foreground uppercase tracking-wide">
                            Elapsed
                        </span>
                        <span className="text-xl font-mono font-semibold tabular-nums">
                            {elapsed_str}
                        </span>
                    </div>
                    <div className="flex flex-col gap-0.5">
                        <span className="text-xs text-muted-foreground uppercase tracking-wide">
                            Active VUs
                        </span>
                        <span className="text-xl font-semibold">{str(active_vus)}</span>
                    </div>
                    <div className="flex flex-col gap-0.5">
                        <span className="text-xs text-muted-foreground uppercase tracking-wide">
                            RPS
                        </span>
                        <span className="text-xl font-semibold">
                            {str(round(rps, 1))}
                        </span>
                    </div>
                    <div className="flex flex-col gap-0.5">
                        <span className="text-xs text-muted-foreground uppercase tracking-wide">
                            Error rate
                        </span>
                        <Badge variant={error_variant}>
                            {str(round(error_rate, 2)) + "%"}
                        </Badge>
                    </div>
                    <div className="ml-auto">
                        <Button
                            variant="destructive"
                            onClick={on_stop}
                            disabled={status != "running"}
                        >
                            Stop run
                        </Button>
                    </div>
                </div>
            </CardContent>
        </Card>;
}
