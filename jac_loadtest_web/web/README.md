# jac-loadtest web

A Jac fullstack application — client UI and server walkers for jac-loadtest.

## Project Structure

```
web/
├── jac.toml              # Project config (npm deps, jac-shadcn theme)
├── main.jac              # App entry point — mounts <App />
├── frontend.cl.jac       # Root client component — router and routes
│
├── pages/                # Route-level page components (.cl.jac)
│   ├── Login.cl.jac
│   ├── Register.cl.jac
│   ├── WorkspaceList.cl.jac
│   ├── WorkspaceCreate.cl.jac
│   ├── WorkspaceDetail.cl.jac
│   ├── RunCreate.cl.jac
│   └── RunDetail.cl.jac
│
├── components/           # Reusable client components (.cl.jac)
│   ├── ui/               # jac-shadcn components (auto-generated, do not edit)
│   ├── WorkspaceCard.cl.jac
│   ├── RunControl.cl.jac
│   ├── HarEntryTable.cl.jac
│   ├── LatencyChart.cl.jac
│   ├── MetricsDashboard.cl.jac
│   ├── ReportViewer.cl.jac
│   └── RunSettingsForm.cl.jac
│
├── services/             # Server walkers (.sv.jac) — HTTP endpoints via jac-scale
│   ├── auth_walkers.sv.jac
│   ├── workspace_walkers.sv.jac
│   ├── run_walkers.sv.jac
│   ├── file_walkers.sv.jac
│   └── stream_walkers.sv.jac
│
├── models/               # Node / dataclass definitions (.sv.jac)
│   ├── workspace.sv.jac
│   └── run.sv.jac
│
├── lib/                  # Utility modules
│   └── utils.cl.jac      # shadcn cn() helper
│
└── styles/
    └── global.css        # Tailwind + jac-shadcn theme tokens
```

## Getting Started

Start the development server:

```bash
jac start --dev main.jac
```

## Import path rules

JAC uses dot notation (no slashes). From a file in `pages/`:
- `import from ..components.ui.button { Button }` — shadcn UI component
- `import from ..components.WorkspaceCard { WorkspaceCard }` — local component

From a file in `components/`:
- `import from .ui.card { Card }` — shadcn UI component in same dir
- `import from .LatencyChart { LatencyChart }` — sibling component

In `main.jac` only, use the `cl` prefix:
```jac
cl import from .frontend { App }
```

## Adding shadcn components

```bash
jac add --shadcn button card badge input
```

## Adding npm packages

```bash
jac add --cl some-package
```

## Validate

```bash
jac check frontend.cl.jac
jac check pages/Login.cl.jac
```
