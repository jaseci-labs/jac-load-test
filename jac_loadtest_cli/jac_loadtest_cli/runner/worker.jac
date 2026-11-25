"""A Locust worker process for multi-process runs (--workers N).

Started by environment.jac as `python -c "import jaclang; ... worker_main(dir)"`.
Reads <dir>/config.json and <dir>/master.json, builds the same RunContext the
master has, and joins the master's runner. It exits when the master quits.
"""

import os;
import sys;
import json;
import from locust.env { Environment }
import from ..config { parse_duration }
import from .configio { load_config }
import from .context { set_context }
import from .environment { build_context, prepare_user_class }
import from .users { HarUser }

def worker_main(workdir: str) -> int {
    cfg = load_config(os.path.join(workdir, "config.json"));
    master = json.load(open(os.path.join(workdir, "master.json")));
    ctx = build_context(cfg);
    ctx.worker_count = int(master["workers"]);
    set_context(ctx);
    prepare_user_class(cfg);
    env = Environment(user_classes=[HarUser], host=master["host_url"]);
    runner = env.create_worker_runner(master["bind_host"], int(master["port"]));
    runner.greenlet.join();
    return 0;
}
