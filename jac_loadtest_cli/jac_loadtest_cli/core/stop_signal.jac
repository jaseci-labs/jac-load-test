"""The cooperative stop flag every engine loop polls.

Engines only ever call is_set() and set() on it, so they accept anything that
looks like an event rather than requiring asyncio.Event: an embedder (the web
app's stop button) passes its own signal object, and worker processes pass a
multiprocessing event. This leaf module exists so engine, ws_engine,
graphql_engine, protocols and process_runner can all name that shape without
importing each other.
"""

class StopSignal(Protocol) {
    def is_set(self: StopSignal) -> bool abst;
    def set(self: StopSignal) abst;
}
