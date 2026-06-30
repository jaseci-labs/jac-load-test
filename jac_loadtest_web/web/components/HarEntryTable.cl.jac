"""HarEntryTable — HAR entries with per-row enable/disable toggles."""

import from .ui.table { Table, TableHeader, TableBody, TableHead, TableRow, TableCell }
import from .ui.switch { Switch }
import from .ui.badge { Badge }
import from .ui.alert { Alert, AlertDescription }

def:pub HarEntryTable(
    entries: list,
    on_toggle: object
) -> JsxElement {
    has_security_warning = any(
        any(h.get("name", "").lower() in ["authorization", "cookie"] for h in e.get("headers", []))
        for e in entries
    );

    if len(entries) == 0 {
        return
            <div className="text-muted-foreground text-sm text-center py-12">
                No HAR entries. Upload a HAR file or record traffic via the proxy.
            </div>;
    }

    return
        <div className="flex flex-col gap-4">
            {
                <Alert>
                    <AlertDescription>
                        Security warning: some requests contain Authorization or Cookie headers.
                        Review before running load tests against production.
                    </AlertDescription>
                </Alert>
                if has_security_warning else None
            }
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead className="w-12">On</TableHead>
                        <TableHead className="w-20">Method</TableHead>
                        <TableHead>Path</TableHead>
                        <TableHead className="w-24">Status</TableHead>
                        <TableHead className="w-32">MIME type</TableHead>
                        <TableHead className="w-28 text-right">Response time</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {[
                        <TableRow key={str(idx)} data-state={"active" if entry.get("enabled", True) else "inactive"}>
                            <TableCell>
                                <Switch
                                    checked={entry.get("enabled", True)}
                                    onCheckedChange={lambda checked: any {
                                        on_toggle(idx, checked);
                                    }}
                                />
                            </TableCell>
                            <TableCell>
                                <Badge variant="outline" className="font-mono text-xs">
                                    {entry.get("method", "GET")}
                                </Badge>
                            </TableCell>
                            <TableCell className="font-mono text-xs truncate max-w-xs">
                                {entry.get("path", entry.get("url", ""))}
                            </TableCell>
                            <TableCell>{str(entry.get("status", ""))}</TableCell>
                            <TableCell className="text-xs text-muted-foreground">
                                {entry.get("mime_type", entry.get("mimeType", ""))}
                            </TableCell>
                            <TableCell className="text-right font-mono text-xs">
                                {str(round(entry.get("time", 0))) + " ms"}
                            </TableCell>
                        </TableRow>
                        for (idx, entry) in enumerate(entries)
                    ]}
                </TableBody>
            </Table>
        </div>;
}
