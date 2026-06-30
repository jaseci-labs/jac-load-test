"""Product landing page — shown at / for unauthenticated visitors."""

import from 'react-router-dom' { useNavigate }
import from ..components.ui.button { Button }

# ── Static data ───────────────────────────────────────────────────────────────

glob _FEATURES: list = [
    {
        "num": "01",
        "title": "HAR Upload & Entry Viewer",
        "desc": "Record your browser session once and upload the .har file. Browse every captured request, toggle entries on or off, and replay at any scale — no scripting needed.",
    },
    {
        "num": "02",
        "title": "Live Metrics Dashboard",
        "desc": "RPS, p50 / p95 / p99 latency, Apdex score, and error rate stream to your browser in real time via SSE while the test runs. No polling, no page refresh.",
    },
    {
        "num": "03",
        "title": "Auth-Aware Replay",
        "desc": "Configure your target app's login endpoint and credentials once per workspace. Every virtual user authenticates independently before the replay loop — no token reuse, no expiry risk during long runs.",
    },
    {
        "num": "04",
        "title": "Threshold Enforcement",
        "desc": "Set error-rate and latency gates. The engine can abort the run on first breach or simply mark it failed — your CI pipeline reads the pass/fail status automatically.",
    },
    {
        "num": "05",
        "title": "HTML & JSON Reports",
        "desc": "Download a self-contained HTML report with Chart.js charts or a structured JSON export for your own dashboards — both generated from the same run data.",
    },
    {
        "num": "06",
        "title": "Workspace Management",
        "desc": "Organise target URLs, HAR files, auth settings, and full run histories in named workspaces. Every completed run stores its report for side-by-side comparison.",
    },
];

glob _STEPS: list = [
    {
        "step": "1",
        "title": "Create a workspace",
        "desc": "Choose monolith or microservice mode, enter your target URL, upload your HAR recording, and optionally enter the credentials used when recording.",
    },
    {
        "step": "2",
        "title": "Configure your run",
        "desc": "Set virtual users, ramp-up time, RPS cap, think-time mode, and optional p95 / error-rate thresholds — all from a single form.",
    },
    {
        "step": "3",
        "title": "Run and analyse",
        "desc": "Watch live charts as the load test runs via Server-Sent Events, then download your HTML or JSON report when it completes.",
    },
];

glob _STATS: list = [
    {"value": "2,000+", "label": "Virtual users per run"},
    {"value": "Zero", "label": "Scripting required"},
    {"value": "Real-time", "label": "SSE metric streaming"},
    {"value": "3", "label": "Report formats"},
];

glob _BAR_HEIGHTS: list = [38, 52, 45, 65, 48, 42, 60, 40, 72, 55, 47, 58, 63, 41, 53, 61, 44, 68, 50, 56];

# ── Sub-components ────────────────────────────────────────────────────────────

def _FeatureCard(props: any) -> JsxElement {
    return
        <div className="flex flex-col gap-4 rounded-2xl border border-border bg-card p-6 hover:border-primary/40 hover:shadow-lg transition-all duration-200">
            <div className="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center shrink-0">
                <span className="text-primary font-mono text-sm font-bold">{props["num"]}</span>
            </div>
            <div className="flex flex-col gap-2">
                <h3 className="font-semibold text-foreground">{props["title"]}</h3>
                <p className="text-sm text-muted-foreground leading-relaxed">{props["desc"]}</p>
            </div>
        </div>;
}

def _StepCard(props: any) -> JsxElement {
    return
        <div className="flex flex-col items-center text-center gap-4">
            <div className="w-14 h-14 rounded-full bg-primary text-primary-foreground flex items-center justify-center text-xl font-bold shadow-lg shadow-primary/30 shrink-0">
                {props["step"]}
            </div>
            <div className="flex flex-col gap-2">
                <h3 className="font-semibold text-foreground">{props["title"]}</h3>
                <p className="text-sm text-muted-foreground leading-relaxed max-w-xs">{props["desc"]}</p>
            </div>
        </div>;
}

def _StatCard(props: any) -> JsxElement {
    return
        <div className="flex flex-col items-center gap-1">
            <span className="text-3xl md:text-4xl font-extrabold text-primary">{props["value"]}</span>
            <span className="text-sm text-muted-foreground">{props["label"]}</span>
        </div>;
}

def _DashboardMockup(props: any) -> JsxElement {
    return
        <div className="relative w-full max-w-2xl mx-auto rounded-2xl border border-border bg-card shadow-2xl overflow-hidden">
            <div className="flex items-center gap-2 px-4 py-3 border-b border-border bg-muted/40">
                <div className="flex gap-1.5">
                    <div className="w-3 h-3 rounded-full bg-red-400/70" />
                    <div className="w-3 h-3 rounded-full bg-yellow-400/70" />
                    <div className="w-3 h-3 rounded-full bg-green-400/70" />
                </div>
                <div className="flex-1 mx-4 rounded-md bg-background/70 px-3 py-1 text-xs text-muted-foreground font-mono truncate">
                    loadtest.myapp.com/workspaces/checkout/runs/42
                </div>
            </div>
            <div className="p-5 flex flex-col gap-4">
                <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                        <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
                        <span className="text-sm font-semibold text-foreground">RUNNING — 38s elapsed</span>
                    </div>
                    <span className="text-xs font-medium text-muted-foreground bg-muted px-2 py-0.5 rounded-full">50 VUs</span>
                </div>
                <div className="grid grid-cols-4 gap-2">
                    <div className="rounded-xl bg-background border border-border p-3 flex flex-col gap-1">
                        <span className="text-xs text-muted-foreground">RPS</span>
                        <span className="text-xl font-bold text-primary">847</span>
                    </div>
                    <div className="rounded-xl bg-background border border-border p-3 flex flex-col gap-1">
                        <span className="text-xs text-muted-foreground">p95</span>
                        <span className="text-xl font-bold text-foreground">124ms</span>
                    </div>
                    <div className="rounded-xl bg-background border border-border p-3 flex flex-col gap-1">
                        <span className="text-xs text-muted-foreground">Apdex</span>
                        <span className="text-xl font-bold text-green-600 dark:text-green-400">0.96</span>
                    </div>
                    <div className="rounded-xl bg-background border border-border p-3 flex flex-col gap-1">
                        <span className="text-xs text-muted-foreground">Errors</span>
                        <span className="text-xl font-bold text-foreground">0.2%</span>
                    </div>
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="text-xs font-medium text-muted-foreground">RPS over time</span>
                    <div className="flex items-end gap-px h-12 w-full">
                        {[
                            <div
                                key={str(i)}
                                className="flex-1 rounded-t-sm bg-primary/50 hover:bg-primary/80 transition-colors"
                                style={{"height": str(_BAR_HEIGHTS[i]) + "%"}}
                            />
                            for i in range(len(_BAR_HEIGHTS))
                        ]}
                    </div>
                </div>
                <div className="rounded-xl border border-border overflow-hidden">
                    <div className="grid grid-cols-4 px-3 py-2 bg-muted/40 text-xs font-medium text-muted-foreground">
                        <span className="col-span-2">Endpoint</span>
                        <span className="text-right">p95</span>
                        <span className="text-right">Errors</span>
                    </div>
                    <div className="grid grid-cols-4 px-3 py-2 border-t border-border text-xs">
                        <span className="col-span-2 font-mono text-foreground truncate">POST /walker/search</span>
                        <span className="text-right text-foreground">98ms</span>
                        <span className="text-right text-green-600 dark:text-green-400">0%</span>
                    </div>
                    <div className="grid grid-cols-4 px-3 py-2 border-t border-border text-xs">
                        <span className="col-span-2 font-mono text-foreground truncate">POST /walker/create_item</span>
                        <span className="text-right text-foreground">156ms</span>
                        <span className="text-right text-yellow-600 dark:text-yellow-400">0.4%</span>
                    </div>
                    <div className="grid grid-cols-4 px-3 py-2 border-t border-border text-xs">
                        <span className="col-span-2 font-mono text-foreground truncate">GET /walker/list_items</span>
                        <span className="text-right text-foreground">44ms</span>
                        <span className="text-right text-green-600 dark:text-green-400">0%</span>
                    </div>
                </div>
            </div>
        </div>;
}

# ── Main page ─────────────────────────────────────────────────────────────────

def:pub Landing() -> JsxElement {
    has isDark: bool = False;

    navigate = useNavigate();

    can with entry {
        saved = localStorage.getItem("theme");
        if saved == "dark" {
            isDark = True;
            document.documentElement.classList.add("dark");
        } elif saved == "light" {
            isDark = False;
            document.documentElement.classList.remove("dark");
        } else {
            prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
            isDark = prefersDark;
            if prefersDark {
                document.documentElement.classList.add("dark");
            }
        }
    }

    def toggleDark() {
        isDark = not isDark;
        if isDark {
            document.documentElement.classList.add("dark");
            localStorage.setItem("theme", "dark");
        } else {
            document.documentElement.classList.remove("dark");
            localStorage.setItem("theme", "light");
        }
    }

    return
        <div className="min-h-screen bg-background text-foreground antialiased">

            <nav className="fixed top-0 inset-x-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur-md">
                <div className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
                    <div className="flex items-center gap-2.5">
                        <div className="w-7 h-7 rounded-lg bg-primary flex items-center justify-center shrink-0">
                            <span className="text-primary-foreground text-[10px] font-extrabold tracking-tight">JL</span>
                        </div>
                        <span className="font-semibold text-foreground tracking-tight">jac-loadtest</span>
                    </div>
                    <div className="flex items-center gap-1">
                        <button
                            onClick={lambda e: any { toggleDark(); }}
                            className="w-8 h-8 rounded-lg hover:bg-muted flex items-center justify-center text-muted-foreground hover:text-foreground transition-colors text-base"
                            aria-label="Toggle colour theme"
                        >
                            {"🌙" if not isDark else "☀️"}
                        </button>
                        <Button
                            variant="ghost"
                            size="sm"
                            onClick={lambda e: any { navigate("/login"); }}
                        >
                            Sign in
                        </Button>
                        <Button
                            size="sm"
                            onClick={lambda e: any { navigate("/register"); }}
                            className="ml-1"
                        >
                            Get started
                        </Button>
                    </div>
                </div>
            </nav>

            <section className="relative pt-36 pb-20 px-6 overflow-hidden">
                <div className="absolute -top-32 left-1/2 -translate-x-1/2 w-[700px] h-[500px] rounded-full bg-primary/10 blur-3xl pointer-events-none" />
                <div className="absolute top-20 -right-20 w-72 h-72 rounded-full bg-primary/5 blur-2xl pointer-events-none" />
                <div className="relative max-w-6xl mx-auto flex flex-col items-center text-center gap-8">
                    <div className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary/8 px-4 py-1.5 text-sm font-medium text-primary">
                        <span className="w-1.5 h-1.5 rounded-full bg-primary animate-pulse" />
                        Phase 6 Web UI — Now in active development
                    </div>
                    <h1 className="text-5xl md:text-6xl font-extrabold tracking-tight text-foreground max-w-3xl leading-[1.1]">
                        {"Load test your jac-scale apps "}
                        <span className="text-primary">right from your browser</span>
                    </h1>
                    <p className="text-lg md:text-xl text-muted-foreground max-w-2xl leading-relaxed">
                        Upload a HAR recording, set your virtual users, and watch real-time metrics stream in as your test runs. No CLI, no scripting, no guesswork.
                    </p>
                    <div className="flex items-center gap-3 flex-wrap justify-center">
                        <Button
                            size="lg"
                            onClick={lambda e: any { navigate("/register"); }}
                            className="px-8 shadow-lg shadow-primary/25"
                        >
                            Get started free
                        </Button>
                        <Button
                            variant="outline"
                            size="lg"
                            onClick={lambda e: any { navigate("/login"); }}
                            className="px-8"
                        >
                            Sign in
                        </Button>
                    </div>
                    <div className="w-full mt-4">
                        <_DashboardMockup props={None} />
                    </div>
                </div>
            </section>

            <section className="border-y border-border bg-muted/30 py-12 px-6">
                <div className="max-w-5xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-10">
                    {[
                        <_StatCard key={s["value"]} value={s["value"]} label={s["label"]} />
                        for s in _STATS
                    ]}
                </div>
            </section>

            <section className="py-24 px-6">
                <div className="max-w-6xl mx-auto flex flex-col gap-14">
                    <div className="flex flex-col items-center text-center gap-4">
                        <h2 className="text-3xl md:text-4xl font-bold text-foreground tracking-tight">
                            Everything you need to test at scale
                        </h2>
                        <p className="text-muted-foreground max-w-xl text-lg">
                            Built for jac-scale apps. Designed for teams that move fast.
                        </p>
                    </div>
                    <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-4">
                        {[
                            <_FeatureCard
                                key={f["num"]}
                                num={f["num"]}
                                title={f["title"]}
                                desc={f["desc"]}
                            />
                            for f in _FEATURES
                        ]}
                    </div>
                </div>
            </section>

            <section className="py-24 px-6 bg-muted/20 border-y border-border">
                <div className="max-w-6xl mx-auto flex flex-col gap-16">
                    <div className="flex flex-col items-center text-center gap-4">
                        <h2 className="text-3xl md:text-4xl font-bold text-foreground tracking-tight">
                            Up and running in three steps
                        </h2>
                        <p className="text-muted-foreground max-w-xl text-lg">
                            From HAR file to live charts in under five minutes.
                        </p>
                    </div>
                    <div className="relative grid md:grid-cols-3 gap-12">
                        <div className="hidden md:block absolute top-7 left-[calc(16.67%+28px)] right-[calc(16.67%+28px)] h-px bg-border" />
                        {[
                            <_StepCard
                                key={s["step"]}
                                step={s["step"]}
                                title={s["title"]}
                                desc={s["desc"]}
                            />
                            for s in _STEPS
                        ]}
                    </div>
                </div>
            </section>

            <section className="py-24 px-6">
                <div className="max-w-3xl mx-auto rounded-3xl bg-primary px-10 py-16 flex flex-col items-center text-center gap-6 shadow-2xl shadow-primary/30">
                    <h2 className="text-3xl md:text-4xl font-extrabold text-primary-foreground tracking-tight">
                        Ready to test your app at scale?
                    </h2>
                    <p className="text-primary-foreground/75 text-lg leading-relaxed max-w-xl">
                        Create a free account and run your first load test in minutes. No CLI, no local setup.
                    </p>
                    <div className="flex items-center gap-3 flex-wrap justify-center">
                        <button
                            onClick={lambda e: any { navigate("/register"); }}
                            className="rounded-xl bg-primary-foreground text-primary px-8 py-3 font-semibold text-sm hover:bg-primary-foreground/90 transition-colors shadow-sm"
                        >
                            Create free account
                        </button>
                        <button
                            onClick={lambda e: any { navigate("/login"); }}
                            className="rounded-xl border border-primary-foreground/30 text-primary-foreground px-8 py-3 font-semibold text-sm hover:bg-primary-foreground/10 transition-colors"
                        >
                            Sign in
                        </button>
                    </div>
                </div>
            </section>

            <footer className="border-t border-border py-10 px-6">
                <div className="max-w-6xl mx-auto flex flex-col md:flex-row items-center justify-between gap-6 text-sm">
                    <div className="flex items-center gap-2.5">
                        <div className="w-6 h-6 rounded-md bg-primary flex items-center justify-center shrink-0">
                            <span className="text-primary-foreground text-[9px] font-extrabold">JL</span>
                        </div>
                        <span className="font-semibold text-foreground">jac-loadtest</span>
                        <span className="text-muted-foreground">— HAR-based load testing for the Jaseci ecosystem</span>
                    </div>
                    <div className="flex items-center gap-6 text-muted-foreground">
                        <a href="/login" className="hover:text-primary transition-colors">Sign in</a>
                        <a href="/register" className="hover:text-primary transition-colors">Register</a>
                    </div>
                </div>
            </footer>

        </div>;
}
