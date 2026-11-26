"""Unit tests for runner/fleet.jac — worker state travelling to the master."""

import from jac_loadtest_cli.config { LoadTestConfig }
import from jac_loadtest_cli.runner.context { RunContext }
import from jac_loadtest_cli.runner.fleet { absorb_state, merge_fleet, pack_state }
import from jac_loadtest_cli.runner.infra { Suspect }


def _ctx() -> RunContext {
    return RunContext(config=LoadTestConfig.from_dict({}), entries=[]);
}

test "pack_state produces plain lists and dicts only" {
    ctx = _ctx();
    ctx.suspects.append(Suspect(timestamp=12.5, endpoint="/a", fingerprint="abc"));
    ctx.auth_failures.append(("alice", "bad password"));
    ctx.correlation.bump("r", "captured");
    state = pack_state(ctx);
    assert state["suspects"] == [[12.5, "/a", "abc"]];
    assert state["auth_failures"] == [["alice", "bad password"]];
    assert state["correlation"]["r"]["captured"] == 1;
}

test "absorb_state rebuilds suspects, failures and correlation counts" {
    worker = _ctx();
    worker.suspects.append(Suspect(timestamp=1.0, endpoint="/a", fingerprint="f1"));
    worker.auth_failures.append(("bob", "locked"));
    worker.correlation.bump("r", "producer_runs");
    master = _ctx();
    absorb_state(master, pack_state(worker));
    assert len(master.suspects) == 1;
    assert master.suspects[0].endpoint == "/a";
    assert master.suspects[0].fingerprint == "f1";
    assert master.auth_failures == [("bob", "locked")];
    assert master.correlation.counts["r"]["producer_runs"] == 1;
}

test "merge_fleet combines every worker once" {
    w1 = _ctx();
    w1.correlation.bump("r", "captured");
    w1.auth_failures.append(("a", "x"));
    w2 = _ctx();
    w2.correlation.bump("r", "captured");
    w2.suspects.append(Suspect(timestamp=2.0, endpoint="/b", fingerprint="f2"));
    master = _ctx();
    master.fleet["worker-1"] = pack_state(w1);
    master.fleet["worker-2"] = pack_state(w2);
    merge_fleet(master);
    assert master.correlation.counts["r"]["captured"] == 2;
    assert master.auth_failures == [("a", "x")];
    assert len(master.suspects) == 1;
    # A second merge must not double-count.
    merge_fleet(master);
    assert master.correlation.counts["r"]["captured"] == 2;
}

test "a repeated message from one worker replaces rather than adds" {
    w = _ctx();
    w.correlation.bump("r", "captured");
    master = _ctx();
    master.fleet["worker-1"] = pack_state(w);
    w.correlation.bump("r", "captured");
    master.fleet["worker-1"] = pack_state(w);
    merge_fleet(master);
    assert master.correlation.counts["r"]["captured"] == 2;
}
