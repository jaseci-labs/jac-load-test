"""WorkspaceCard — displays workspace name, mode, and run count."""

import from 'react-router-dom' { useNavigate }
import from .ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from .ui.badge { Badge }

def:pub WorkspaceCard(
    id: str,
    name: str,
    mode: str,
    run_count: int = 0
) -> JsxElement {
    navigate = useNavigate();

    return
        <Card
            className="cursor-pointer hover:ring-primary/30 hover:ring-2 transition-all"
            onClick={lambda e: any { navigate("/workspaces/" + id); }}
        >
            <CardHeader>
                <div className="flex items-center justify-between">
                    <CardTitle className="text-base">{name}</CardTitle>
                    <Badge variant="secondary">{mode}</Badge>
                </div>
                <CardDescription>
                    {str(run_count) + (" run" if run_count == 1 else " runs")}
                </CardDescription>
            </CardHeader>
        </Card>;
}
