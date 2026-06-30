"""Alert and AlertDescription — shadcn-style notification banner."""

import from ...lib.utils { cn }

def:pub Alert(props: any) -> JsxElement {
    attrs: dict[str, any] = {** props};
    variant = props["variant"] or "default";
    return
        <div
            {**attrs}
            role="alert"
            data-slot="alert"
            data-variant={variant}
            className={cn(
                "relative w-full rounded-lg border px-4 py-3 text-sm",
                "data-[variant=default]:bg-muted/50 data-[variant=default]:border-border data-[variant=default]:text-foreground",
                "data-[variant=destructive]:border-destructive/50 data-[variant=destructive]:bg-destructive/10 data-[variant=destructive]:text-destructive",
                props["className"]
            )}
        />;
}

def:pub AlertDescription(props: any) -> JsxElement {
    attrs: dict[str, any] = {** props};
    return
        <p
            {**attrs}
            data-slot="alert-description"
            className={cn("text-sm leading-relaxed [&_p]:leading-relaxed", props["className"])}
        />;
}
