"""Dark/light theme persistence — single source of truth for the `dark` class
on <html> and its `localStorage["theme"]` backing value.
"""

def:pub applyTheme(is_dark: bool) {
    if is_dark {
        document.documentElement.classList.add("dark");
    } else {
        document.documentElement.classList.remove("dark");
    }
}

def:pub initTheme() -> bool {
    saved = localStorage.getItem("theme");
    if saved == "dark" {
        applyTheme(True);
        return True;
    } elif saved == "light" {
        applyTheme(False);
        return False;
    } else {
        prefers_dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        applyTheme(prefers_dark);
        return prefers_dark;
    }
}

def:pub persistTheme(is_dark: bool) {
    applyTheme(is_dark);
    localStorage.setItem("theme", "dark" if is_dark else "light");
}
