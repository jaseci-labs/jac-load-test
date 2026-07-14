"""ThemeProvider / ThemeToggle — single source of truth for dark/light theme state.

ThemeProvider is mounted ONCE at the true app root (see frontend.cl.jac). Every
ThemeToggle across the app reads this SAME live value via context — a plain hook
would give each page's own toggle instance its own independent isDark state,
re-derived on that page's own mount timing (see jac-cl-organization: "a custom
hook does NOT share state between two consumers").

ThemeProvider and ThemeToggle must live in this ONE file: `glob` in a .cl.jac
compiles to a module-local JS variable with no `export` statement (see
jac-cl-js-interop), so a context glob is invisible to any other file that tries
to `import` it — the working precedent for this pattern in the codebase
(components/ui/sidebar.cl.jac's SidebarContext) also keeps its provider and every
consumer in a single file for exactly this reason.
"""

import from react { createContext, useContext }
import from ..lib.theme { initTheme, persistTheme }

glob ThemeContext: any = createContext(None);

def:pub ThemeProvider(children: any = None) -> JsxElement {
    has isDark: bool = False;

    can with entry {
        isDark = initTheme();
    }

    def toggle() {
        isDark = not isDark;
        persistTheme(isDark);
    }

    value = {
        "isDark": isDark,
        "toggle": toggle,
    };

    return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

def:pub ThemeToggle(className: str = "") -> JsxElement {
    ctx: any = useContext(ThemeContext);
    isDark = ctx.isDark;
    toggle = ctx.toggle;

    return
        <button
            onClick={lambda e: any { toggle(); }}
            className={"w-8 h-8 rounded-lg hover:bg-muted flex items-center justify-center text-muted-foreground hover:text-foreground transition-colors text-base " + className}
            aria-label="Toggle colour theme"
        >
            {"🌙" if isDark else "☀️"}
        </button>;
}
