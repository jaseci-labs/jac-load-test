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
import from ..core.engine { run_all_vus }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { MetricsCollector, RequestResult, StatsSnapshot }
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

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout));
    token = "";
    async with aiohttp.ClientSession(timeout=timeout) as auth_session {
        if config.url is not None {
            token = await auth_provider.authenticate(0, auth_session, config.url);
        }
    }
    return {i: token for i in range(total_vus)};
}

def _merge_snapshots(snapshots: list[StatsSnapshot]) -> StatsSnapshot {
    # Approximate cross-worker aggregate for live progress streaming: each worker
    # reports its own exact cumulative StatsSnapshot (see engine.snapshot_now()), and
    # this combines the latest one from each worker into a single reading. total_requests,
    # rps, and error_rate_pct combine exactly; p50/p95/p99 are a request-weighted average
    # across workers rather than a true percentile of the merged sample set — good enough
    # for a live progress indicator. The authoritative final report always recomputes exact
    # percentiles from the fully merged raw samples after the run (compute_endpoint_stats()).
    total = sum(s.total_requests for s in snapshots);
    rps = sum(s.rps for s in snapshots);
    timestamp = max((s.timestamp for s in snapshots), default=0.0);
    if total > 0 {
        error_rate_pct = sum(s.error_rate_pct * s.total_requests for s in snapshots) / total;
        p50 = sum(s.p50_ms * s.total_requests for s in snapshots) / total;
        p95 = sum(s.p95_ms * s.total_requests for s in snapshots) / total;
        p99 = sum(s.p99_ms * s.total_requests for s in snapshots) / total;
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
    );
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
) {
    worker_callback = (
        (lambda snap: queue.put(("worker_snapshot", vu_id_offset, snap)))
        if stream_enabled else None
    );

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
        ramp_up=config.ramp_up,
        timeout=config.timeout,
        workers=config.workers,
        mode=config.mode,
        think_time=config.think_time,
        think_time_scale=config.think_time_scale,
        rps=worker_rps,
        include_static=config.include_static,
        login_path=config.login_path,
        csrf=config.csrf,
        fail_on_error_rate=config.fail_on_error_rate,
        fail_on_p95=config.fail_on_p95,
        fail_on_p99=config.fail_on_p99,
        abort_on_fail=config.abort_on_fail,
        threshold_start_delay=config.threshold_start_delay,
        report_format=config.report_format,
        max_samples=config.max_samples,
        debug=config.debug,
        har_file=config.har_file,
        url=config.url,
        username=config.username,
        password=config.password,
        services_map=config.services_map,
        report_out=config.report_out,
    );
    metrics = MetricsCollector(max_samples=config.max_samples);
    try {
        asyncio.run(
            run_all_vus(
                entries,
                worker_config,
                metrics,
                topology=topology,
                vu_id_offset=vu_id_offset,
                pre_authed_tokens=token_by_vu,
                pre_resolved_hosts=pre_resolved_hosts,
                stream_metrics_callback=worker_callback,
                t_start=t_start,
                stream_interval=stream_interval,
                stop_requested=stop_requested,
            )
        );
        queue.put(("ok", vu_id_offset, list(metrics._samples)));
    } except Exception {
        import traceback;
        queue.put(("error", vu_id_offset, traceback.format_exc()));
    }
}

def _compute_slices(total_vus: int, workers: int) -> list[tuple[int, int]] {
    base = total_vus // workers;
    remainder = total_vus % workers;
    slices = [];
    offset = 0;
    for i in range(workers) {
        count = base + (1 if i < remainder else 0);
        if count > 0 {
            slices.append((offset, count));
            offset += count;
        }
    }
    return slices;
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
) -> MetricsCollector {

    run_t_start = t_start if t_start is not None else time.time();
    cpu_count = os.cpu_count() or 1;
    workers = min(config.workers, config.vus, cpu_count);
    if config.workers > cpu_count {
        print(
            f"Warning: --workers {config.workers} exceeds available CPU count "
            f"({cpu_count}); capped at {workers}.",
            file=sys.stderr,
        );
    }
    slices = _compute_slices(config.vus, workers);

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

    processes = [];
    try {
        for (vu_id_offset, worker_vus) in slices {
            worker_tokens = (
                {vu_id: token_by_vu[vu_id] for vu_id in range(vu_id_offset, vu_id_offset + worker_vus)}
                if token_by_vu is not None else None
            );
            p = ctx.Process(
                target=_worker_fn,
                args=(
                    vu_id_offset, worker_vus, config.vus, entries, config, topology, worker_tokens,
                    pre_resolved_hosts, queue, run_t_start, stream_metrics_callback is not None,
                    stream_interval, stop_requested,
                ),
            );
            p.start();
            processes.append(p);
        }

        raw_results = [];
        latest_snapshot_by_worker: dict[int, StatsSnapshot] = {};
        active_workers: set[int] = {vu_id_offset for (vu_id_offset, _worker_vus) in slices};
        updated_since_flush: set[int] = set();
        pending = len(processes);
        while pending > 0 {
            msg = queue.get();
            if msg[0] == "worker_snapshot" {
                vu_id_offset = msg[1];
                latest_snapshot_by_worker[vu_id_offset] = msg[2];
                updated_since_flush.add(vu_id_offset);
            } else {
                # ("ok"|"error", vu_id_offset, payload) — that worker is done and
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
            if (
                stream_metrics_callback is not None
                and active_workers
                and updated_since_flush >= active_workers
            ) {
                stream_metrics_callback(_merge_snapshots(list(latest_snapshot_by_worker.values())));
                updated_since_flush.clear();
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

    for (status, _vu_id_offset, payload) in raw_results {
        if status == "error" {
            if isinstance(payload, str) {
                raise RuntimeError(f"Worker process failed: {payload}");
            }
        }
    }

    merged = MetricsCollector(max_samples=config.max_samples);
    for (_status, _vu_id_offset, samples) in raw_results {
        if isinstance(samples, list) {
            for result in samples {
                if isinstance(result, RequestResult) {
                    merged.record(result);
                }
            }
        }
    }

    return merged;
}
