"""ThemeToggle — dark/light mode button, placed in the header of every page.

Reads the shared ThemeContext (see ThemeProvider) instead of owning local
state, so every page's button reflects the exact same live value.
"""

import from react { useContext }
import from .ThemeProvider { ThemeContext }

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
