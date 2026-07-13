"""ThemeProvider — single source of truth for dark/light theme state.

Mounted ONCE at the true app root (see frontend.cl.jac). Every <ThemeToggle/>
across the app reads this SAME live value via context — a plain hook here
would give each page's own toggle instance its own independent isDark state,
re-derived on that page's own mount timing (see jac-cl-organization: "a
custom hook does NOT share state between two consumers").
"""

import from react { createContext }
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
