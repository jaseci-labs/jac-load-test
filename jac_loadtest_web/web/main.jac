"""jac-loadtest web — fullstack entry point.

sv imports wire the server-side walkers into the jac-scale HTTP router.
cl import wires the React root component into the Vite bundle.
"""

cl import from .cl.App { App }

cl def:pub app -> JsxElement {
    return <App />;
}
