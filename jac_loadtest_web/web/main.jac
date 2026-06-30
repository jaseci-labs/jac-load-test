"""jac-loadtest web — fullstack entry point.

sv imports wire the server-side walkers into the jac-scale HTTP router.
cl import wires the React root component into the Vite bundle.
"""

cl import from .frontend { App }
cl import ".styles.global.css";

cl def:pub app -> JsxElement {
    return <App />;
}
