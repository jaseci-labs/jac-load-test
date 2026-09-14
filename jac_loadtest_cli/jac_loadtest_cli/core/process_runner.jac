import asyncio;
import multiprocessing;
import multiprocessing.process;
import multiprocessing.queues;
import os;
import socket;
import sys;
import time;
import aiohttp;
import from .har_parser { HarEntry }
import from ..core.engine { _has_thresholds }
import from ..core.protocols { run_all_protocols }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics {
    MetricsCollector, RequestResult, StatsSnapshot,
    histogram_percentile, histogram_total, merge_histograms
}
import from ..bridge.auth { AuthProvider }

def _resolve_hosts(url: str) -> dict[str, str] {
    import from urllib.parse { urlparse }
    hostname = urlparse(url).hostname;
    if not hostname {
        return {};
    }
    try {
        infos = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM);
        if infos {
            return {hostname: str(infos[0][4][0])};
        }
    } except socket.gaierror {
        
    }
    return {};
}

async def _pre_authenticate_all(
    config: LoadTestConfig,
    auth_provider: AuthProvider,
    total_vus: int,
) -> dict[int, str] {

    # Phase 7b — the whole pool is authenticated here, on the controller, before
    # any worker is forked, and each worker is handed only its own VU-id -> token
    # slice. Workers never touch the login endpoint, so raising --workers does not
    # multiply auth traffic. One login happens per distinct account rather than
    # per VU (see AuthProvider.authenticate_all), so a 500-VU run over 10 accounts
    # is 10 logins.
    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout));
    if config.url is None {
        return {};
    }
    async with aiohttp.ClientSession(timeout=timeout) as auth_session {
        return await auth_provider.authenticate_all(
            list(range(total_vus)), auth_session, config.url
        );
    }
}

def _merge_snapshots(snapshots: list[StatsSnapshot]) -> StatsSnapshot {
    # Cross-worker aggregate for live progress streaming and for the controller's
    # --abort-on-fail decision: each worker reports its own cumulative
    # StatsSnapshot (see metrics.snapshot_now()) and this combines the latest one
    # from each into a single reading. total_requests, rps and error_rate_pct
    # combine exactly by construction.
    #
    # Percentiles come from summing the workers' latency histograms and reading
    # the merged distribution (Phase 8d). This is a real percentile of the whole
    # fleet's traffic, accurate to one bucket (~5%, always on the high side).
    # Snapshots carrying no histogram — generate_timeseries() output, or a
    # hand-built fixture — fall back to the older request-weighted average, which
    # is not a percentile and can be badly wrong when workers see different
    # latency profiles; it is kept only so such snapshots still merge to something.
    #
    # The final report never uses either path: it recomputes exact percentiles
    # from the fully merged raw samples (compute_endpoint_stats()).
    total = sum(s.total_requests for s in snapshots);
    rps = sum(s.rps for s in snapshots);
    timestamp = max((s.timestamp for s in snapshots), default=0.0);
    histograms = [s.latency_buckets for s in snapshots if s.latency_buckets];
    merged_buckets: list[int] = merge_histograms(histograms) if histograms else [];
    if total > 0 {
        error_rate_pct = sum(s.error_rate_pct * s.total_requests for s in snapshots) / total;
        if merged_buckets {
            p50 = histogram_percentile(merged_buckets, 50);
            p95 = histogram_percentile(merged_buckets, 95);
            p99 = histogram_percentile(merged_buckets, 99);
        } else {
            p50 = sum(s.p50_ms * s.total_requests for s in snapshots) / total;
            p95 = sum(s.p95_ms * s.total_requests for s in snapshots) / total;
            p99 = sum(s.p99_ms * s.total_requests for s in snapshots) / total;
        }
    } else {
        error_rate_pct = 0.0;
        p50 = 0.0;
        p95 = 0.0;
        p99 = 0.0;
    }
    return StatsSnapshot(
        timestamp=timestamp,
        p50_ms=p50,
        p95_ms=p95,
        p99_ms=p99,
        rps=rps,
        error_rate_pct=error_rate_pct,
        total_requests=total,
        latency_buckets=merged_buckets,
    );
}

def _snapshot_breached(config: LoadTestConfig, snap: StatsSnapshot) -> bool {
    # Merged-fleet equivalent of engine._thresholds_breached(). Same rules, but
    # reading the distribution off the merged histogram, because raw samples stay
    # inside their worker until the run ends and the controller has to decide
    # while the run is still going.
    if snap.total_requests == 0 {
        return False;
    }
    if config.fail_on_error_rate is not None and snap.error_rate_pct > config.fail_on_error_rate {
        return True;
    }
    if config.fail_on_p95 is not None or config.fail_on_p99 is not None {
        if histogram_total(snap.latency_buckets) == 0 {
            # Every request so far failed before a response was received, so there
            # is no measured latency anywhere in the fleet. A dead target must not
            # read as a passing p95/p99 (mirrors engine._breach_check()).
            return True;
        }
        if config.fail_on_p95 is not None and snap.p95_ms > config.fail_on_p95 {
            return True;
        }
        if config.fail_on_p99 is not None and snap.p99_ms > config.fail_on_p99 {
            return True;
        }
    }
    return False;
}

async def _shared_stop_bridge(shared_stops: list, local_stop: asyncio.Event, poll_s: float = 0.1) {
    # Mirrors cross-process stop signals onto a plain asyncio.Event, which is what
    # the engine actually watches. The engine checks stop_requested.is_set() once
    # per HAR entry per VU — hundreds of thousands of calls a second at scale —
    # and a multiprocessing.Event costs a lock acquisition every time. Polling at
    # 10 Hz here keeps that hot path a pure in-process check while still reacting
    # within ~100 ms of the controller's decision. (The web app's _RunStopSignal
    # solved the same problem by throttling its own is_set(); this moves the
    # throttle to one place and leaves engine semantics untouched.)
    while not local_stop.is_set() {
        for event in shared_stops {
            if event.is_set() {
                local_stop.set();
                return;
            }
        }
        await asyncio.sleep(poll_s);
    }
}

async def _worker_main(
    entries: list[HarEntry],
    worker_config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: object | None,
    vu_id_offset: int,
    token_by_vu: dict[int, str] | None,
    pre_resolved_hosts: dict[str, str],
    worker_callback: object | None,
    t_start: float,
    stream_interval: float,
    shared_stops: list,
    ws_scenarios: list,
    graphql_scenarios: list,
    correlation_rules: list,
    auth_provider: object | None,
) {
    local_stop = asyncio.Event();
    bridge_task: object | None = None;
    if shared_stops {
        bridge_task = asyncio.create_task(_shared_stop_bridge(shared_stops, local_stop));
    }
    try {
        # run_all_protocols rather than run_all_vus: a worker may now hold
        # WebSocket/GraphQL scenarios alongside its HTTP slice, and they share one
        # MetricsCollector and one stop event exactly as in single-process mode.
        # With no scenarios this is run_all_vus plus one empty task list.
        await run_all_protocols(
            entries,
            worker_config,
            metrics,
            topology=topology,
            # Passed so a worker can re-authenticate a VU after a mid-run 401.
            # It does NOT cause a second pre-run login: run_all_vus prefers
            # pre_authed_tokens, which the controller already filled in.
            auth_provider=auth_provider,
            ws_scenarios=ws_scenarios,
            graphql_scenarios=graphql_scenarios,
            stop_requested=local_stop,
            t_start=t_start,
            on_snapshot=worker_callback,
            vu_id_offset=vu_id_offset,
            pre_authed_tokens=token_by_vu,
            pre_resolved_hosts=pre_resolved_hosts,
            stream_interval=stream_interval,
            correlation_rules=correlation_rules,
        );
    } finally {
        local_stop.set();
        if bridge_task is not None and not bridge_task.done() {
            bridge_task.cancel();
            try {
                await bridge_task;
            } except asyncio.CancelledError {

            }
        }
    }
}

def _worker_fn(
    vu_id_offset: int,
    worker_vus: int,
    total_vus: int,
    entries: list[HarEntry],
    config: LoadTestConfig,
    topology: object | None,
    token_by_vu: dict[int, str] | None,
    pre_resolved_hosts: dict[str, str],
    queue: object,
    t_start: float,
    stream_enabled: bool,
    stream_interval: float,
    stop_requested: object | None = None,
    controller_abort: object | None = None,
    controller_owns_abort: bool = False,
    ws_scenarios: list | None = None,
    graphql_scenarios: list | None = None,
    worker_max_samples: int | None = None,
    worker_index: int = 0,
    correlation_rules: list | None = None,
    auth_provider: object | None = None,
) {
    # Identity on the result queue. Distinct from vu_id_offset, which stopped
    # being unique once a worker could hold protocol scenarios and no HTTP VUs.
    wid = worker_index;
    worker_callback = (
        (lambda (snap: StatsSnapshot) { queue.put(("worker_snapshot", wid, snap)); })
        if stream_enabled else None
    );
    worker_budget = worker_max_samples if worker_max_samples is not None else config.max_samples;

    # Split the global --rps budget across workers proportionally to their VU
    # share, since engine.run_all_vus() paces each worker independently from
    # worker_config.rps — passing the unsplit global rps here would make every
    # worker deliver the full budget on its own, overshooting by ~workers x.
    worker_rps = (
        config.rps * worker_vus / total_vus if config.rps > 0 else config.rps
    );

    worker_config = LoadTestConfig(
        vus=worker_vus,
        iterations=config.iterations,
        duration=config.duration,
        ramp_up=config.ramp_up,
        timeout=config.timeout,
        workers=config.workers,
        mode=config.mode,
        think_time=config.think_time,
        think_time_scale=config.think_time_scale,
        rps=worker_rps,
        open_loop=config.open_loop,
        step_load=config.step_load,
        step_vus=config.step_vus,
        step_duration=config.step_duration,
        step_max_vus=config.step_max_vus,
        include_static=config.include_static,
        login_path=config.login_path,
        csrf=config.csrf,
        fail_on_error_rate=config.fail_on_error_rate,
        fail_on_p95=config.fail_on_p95,
        fail_on_p99=config.fail_on_p99,
        # Phase 8d — when the controller owns the decision, the worker must not
        # also run its own _threshold_watcher: that watcher only ever sees this
        # worker's VU-slice, so it would abort on a fraction of the evidence and
        # at a different moment in every process. The worker keeps watching
        # stop_requested (it always did) and the controller sets it.
        abort_on_fail=False if controller_owns_abort else config.abort_on_fail,
        threshold_start_delay=config.threshold_start_delay,
        report_format=config.report_format,
        # Phase 8d — this worker's slice of --max-samples, not the whole budget.
        # The cap used to be applied at full size here AND again when merging, so
        # `--max-samples 100000` across 4 workers retained 400k and then evicted
        # back to 100k, leaving a different window than the one asked for.
        max_samples=worker_budget,
        debug=config.debug,
        har_file=config.har_file,
        url=config.url,
        username=config.username,
        password=config.password,
        services_map=config.services_map,
        report_out=config.report_out,
        assert_json=config.assert_json,
    );
    # Either signal stops this worker: an external one supplied by the embedder
    # (the web app's stop button), or the controller's own abort event.
    shared_stops: list = [];
    if stop_requested is not None {
        shared_stops.append(stop_requested);
    }
    if controller_abort is not None {
        shared_stops.append(controller_abort);
    }

    metrics = MetricsCollector(max_samples=worker_budget);
    try {
        asyncio.run(
            _worker_main(
                entries,
                worker_config,
                metrics,
                topology=topology,
                vu_id_offset=vu_id_offset,
                token_by_vu=token_by_vu,
                pre_resolved_hosts=pre_resolved_hosts,
                worker_callback=worker_callback,
                t_start=t_start,
                stream_interval=stream_interval,
                shared_stops=shared_stops,
                ws_scenarios=ws_scenarios or [],
                graphql_scenarios=graphql_scenarios or [],
                correlation_rules=correlation_rules or [],
                auth_provider=auth_provider,
            )
        );
        queue.put(("ok", wid, list(metrics._samples), metrics.samples_evicted));
    } except Exception {
        import traceback;
        queue.put(("error", wid, traceback.format_exc(), 0));
    }
}

def _distribute(total: int, parts: int) -> list[int] {
    # Split an integer total across `parts` shares that sum back to it exactly:
    # every share gets the floor, and the first `remainder` shares get one extra.
    # Zero shares are kept so the result stays index-aligned with the worker list
    # (a worker can legitimately draw no HTTP VUs but still hold WS scenarios).
    if parts <= 0 {
        return [];
    }
    base = total // parts;
    remainder = total % parts;
    return [base + (1 if i < remainder else 0) for i in range(parts)];
}

def _compute_slices(total_vus: int, workers: int) -> list[tuple[int, int]] {
    slices = [];
    offset = 0;
    for count in _distribute(total_vus, workers) {
        if count > 0 {
            slices.append((offset, count));
            offset += count;
        }
    }
    return slices;
}

def _split_scenarios(scenarios: list, workers: int) -> list[list] {
    # Phase 8d/9 — spread each scenario's VU count across workers, so a scenario
    # asking for 50 connections opens ~12 in each of 4 processes instead of 50 in
    # every one. Returns one list per worker, holding only the scenarios that
    # worker actually draws VUs for.
    #
    # copy.copy rather than rebuilding the object field by field: WsScenarioConfig
    # and GraphQLScenarioConfig carry different fields and gain more over time, and
    # a constructor call here would silently drop any field added later. Only `vus`
    # differs per worker; the shallow-shared messages/headers are never mutated.
    import copy;
    per_worker: list[list] = [[] for _i in range(workers)];
    for scenario in scenarios {
        for (i, share) in enumerate(_distribute(scenario.vus, workers)) {
            if share > 0 {
                worker_scenario = copy.copy(scenario);
                worker_scenario.vus = share;
                per_worker[i].append(worker_scenario);
            }
        }
    }
    return per_worker;
}

def run_multiprocess(
    entries: list[HarEntry],
    config: LoadTestConfig,
    topology: object | None,
    auth_provider: AuthProvider | None,
    stream_metrics_callback: object | None = None,
    t_start: float | None = None,
    stream_interval: float = 10.0,
    stop_requested: object | None = None,
    ws_scenarios: list | None = None,
    graphql_scenarios: list | None = None,
    correlation_rules: list | None = None,
) -> MetricsCollector {

    run_t_start = t_start if t_start is not None else time.time();
    ws_scenarios = ws_scenarios or [];
    graphql_scenarios = graphql_scenarios or [];
    cpu_count = os.cpu_count() or 1;
    # Worker count is capped by how many VUs there are to spread, which now
    # includes protocol-scenario VUs: a scenario-only run has config.vus VUs of
    # HTTP work (possibly none) but can still hold hundreds of connections worth
    # spreading across processes.
    scenario_vus = (
        sum(sc.vus for sc in ws_scenarios) + sum(sc.vus for sc in graphql_scenarios)
    );
    schedulable_vus = max(config.vus + scenario_vus, 1);
    workers = min(config.workers, schedulable_vus, cpu_count);
    if config.workers > cpu_count {
        print(
            f"Warning: --workers {config.workers} exceeds available CPU count "
            f"({cpu_count}); capped at {workers}.",
            file=sys.stderr,
        );
    }

    # Index-aligned per-worker plan. A worker can draw zero HTTP VUs and still own
    # scenario VUs (or the reverse), so the three splits are computed independently
    # and workers with no work at all are dropped at spawn time.
    http_counts = _distribute(config.vus, workers);
    ws_by_worker = _split_scenarios(ws_scenarios, workers);
    graphql_by_worker = _split_scenarios(graphql_scenarios, workers);
    # --max-samples is one budget for the run, so give each worker a share of it
    # rather than the whole number; the merge then keeps everything it receives
    # instead of evicting a second time. Weighted by the VUs a worker actually
    # drives, since that is what governs how many samples it produces. Floored at
    # 1 because MetricsCollector treats max_samples=0 as "retain nothing".
    worker_loads = [
        http_counts[i] + sum(sc.vus for sc in ws_by_worker[i]) + sum(sc.vus for sc in graphql_by_worker[i])
        for i in range(workers)
    ];
    total_load = sum(worker_loads) or 1;
    sample_budgets = [
        max(1, config.max_samples * load // total_load) for load in worker_loads
    ];

    slices = [];
    offset = 0;
    for i in range(workers) {
        if http_counts[i] > 0 or ws_by_worker[i] or graphql_by_worker[i] {
            slices.append((offset, http_counts[i], i));
        }
        offset += http_counts[i];
    }

    # Phase 8d — the --abort-on-fail decision belongs to the controller, which is
    # the only place that can see the whole fleet's traffic. Workers stream their
    # running numbers up regardless of whether an embedder asked for a live
    # callback, because the decision needs them either way.
    controller_owns_abort = config.abort_on_fail and _has_thresholds(config);
    stream_enabled = stream_metrics_callback is not None or controller_owns_abort;
    # engine._threshold_watcher checks once a second in single-process mode, so
    # workers must report at least that often for the multiprocess abort to be
    # equally prompt. The embedder's callback still fires at its own, slower
    # interval — see the flush gate in the drain loop below.
    worker_stream_interval = (
        min(stream_interval, 1.0) if controller_owns_abort else stream_interval
    );
    threshold_delay_s = parse_duration(config.threshold_start_delay);

    pre_resolved_hosts = _resolve_hosts(config.url) if config.url else {};

    token_by_vu = None;
    if auth_provider is not None {
        if not config.url {
            raise ValueError("auth_provider requires --url to be set");
        }
        token_by_vu = asyncio.run(_pre_authenticate_all(config, auth_provider, config.vus));
    }

    ctx = multiprocessing.get_context("spawn");
    queue = ctx.Queue();
    # Set by the controller when the merged reading breaches; every worker polls
    # it through _shared_stop_bridge. spawn-context so it survives the process
    # boundary — the same primitive the web stop button already relies on.
    controller_abort = ctx.Event() if controller_owns_abort else None;

    processes = [];
    try {
        for (vu_id_offset, worker_vus, widx) in slices {
            worker_tokens = (
                {vu_id: token_by_vu[vu_id] for vu_id in range(vu_id_offset, vu_id_offset + worker_vus)}
                if token_by_vu is not None else None
            );
            p = ctx.Process(
                target=_worker_fn,
                args=(
                    vu_id_offset, worker_vus, config.vus, entries, config, topology, worker_tokens,
                    pre_resolved_hosts, queue, run_t_start, stream_enabled,
                    worker_stream_interval, stop_requested, controller_abort, controller_owns_abort,
                    ws_by_worker[widx], graphql_by_worker[widx], sample_budgets[widx], widx,
                    correlation_rules or [], auth_provider,
                ),
            );
            p.start();
            processes.append(p);
        }

        raw_results = [];
        latest_snapshot_by_worker: dict[int, StatsSnapshot] = {};
        # Keyed by worker index, not VU offset: a worker holding only protocol
        # scenarios draws no HTTP VUs, so several workers can share one offset and
        # it is no longer a unique identity.
        active_workers: set[int] = {widx for (_off, _vus, widx) in slices};
        updated_since_flush: set[int] = set();
        last_callback_at = run_t_start;
        aborted = False;
        pending = len(processes);
        while pending > 0 {
            msg = queue.get();
            if msg[0] == "worker_snapshot" {
                widx = msg[1];
                latest_snapshot_by_worker[widx] = msg[2];
                updated_since_flush.add(widx);
            } else {
                # ("ok"|"error", worker_index, payload) — that worker is done and
                # will send no further snapshots, so stop waiting on it.
                active_workers.discard(msg[1]);
                updated_since_flush.discard(msg[1]);
                raw_results.append(msg);
                pending -= 1;
            }
            # Fire once every still-active worker has a fresh snapshot since the
            # last flush, instead of once per individual worker tick — otherwise
            # N workers ticking independently can invoke the callback up to N
            # times in quick succession, each mostly re-sending the other
            # workers' unchanged data.
            if active_workers and updated_since_flush >= active_workers {
                merged_snapshot = _merge_snapshots(list(latest_snapshot_by_worker.values()));
                updated_since_flush.clear();

                if (
                    controller_abort is not None
                    and not aborted
                    and (time.time() - run_t_start) >= threshold_delay_s
                    and _snapshot_breached(config, merged_snapshot)
                ) {
                    print(
                        "\nThreshold breached — stopping test early (--abort-on-fail).",
                        file=sys.stderr,
                    );
                    controller_abort.set();
                    aborted = True;
                }

                # Workers may be reporting once a second to feed the check above;
                # the embedder asked for --stream-interval, so gate on elapsed
                # time rather than forwarding every reading.
                if stream_metrics_callback is not None {
                    now = time.time();
                    if now - last_callback_at >= stream_interval {
                        stream_metrics_callback(merged_snapshot);
                        last_callback_at = now;
                    }
                }
            }
        }

        for p in processes {
            p.join();
        }

    } finally {
        for p in processes {
            if p.is_alive() {
                p.terminate();
            }
        }
    }

    for msg in raw_results {
        if msg[0] == "error" {
            payload = msg[2];
            if isinstance(payload, str) {
                raise RuntimeError(f"Worker process failed: {payload}");
            }
        }
    }

    return _merge_worker_results(raw_results, config.max_samples);
}

def _merge_worker_results(raw_results: list, max_samples: int) -> MetricsCollector {
    # Each worker was given a share of --max-samples rather than the whole budget
    # (Phase 8d), so the shares already sum to roughly max_samples and what arrives
    # here fits. The cap is still set on the merged collector as a backstop -- the
    # per-worker floor of 1 can overshoot slightly when the budget is smaller than
    # the worker count -- but in the normal case it evicts nothing, so the retained
    # window is the one the user asked for instead of being trimmed twice. Any
    # eviction a worker did do is still carried across, since those samples never
    # reached this process and would otherwise go uncounted.
    merged = MetricsCollector(max_samples=max_samples);
    worker_samples_evicted = 0;
    for msg in raw_results {
        samples = msg[2];
        if len(msg) > 3 {
            worker_samples_evicted += msg[3];
        }
        if isinstance(samples, list) {
            for result in samples {
                if isinstance(result, RequestResult) {
                    merged.record(result);
                }
            }
        }
    }
    merged.samples_evicted += worker_samples_evicted;
    return merged;
}
