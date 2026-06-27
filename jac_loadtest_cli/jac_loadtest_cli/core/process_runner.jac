import asyncio;
import multiprocessing;
import multiprocessing.process;
import multiprocessing.queues;
import socket;
import aiohttp;
import from .har_parser { HarEntry }
import from ..core.engine { run_all_vus }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { MetricsCollector, RequestResult }
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
    n_creds = len(auth_provider._credentials);
    cred_indices = {i % n_creds for i in range(total_vus)};
    sem = asyncio.Semaphore(min(50, len(cred_indices)));

    async def _do_auth(cred_idx: int) -> tuple[int, str] {
        async with sem {
            async with aiohttp.ClientSession(timeout=timeout) as auth_session {
                if config.url is not None {
                    tok = await auth_provider.authenticate(cred_idx, auth_session, config.url);
                }
            }
        }
        return (cred_idx, tok);
    }

    results = list(
        await asyncio.gather(*[_do_auth(idx) for idx in cred_indices])
    );
    token_by_cred: dict[int, str] = dict(results);
    return {i: token_by_cred[i % n_creds] for i in range(total_vus)};
}

def _worker_fn(
    vu_id_offset: int,
    worker_vus: int,
    entries: list[HarEntry],
    config: LoadTestConfig,
    topology: object | None,
    token_by_vu: dict[int, str] | None,
    pre_resolved_hosts: dict[str, str],
    queue: object,
) {

    worker_config = LoadTestConfig(
        vus=worker_vus,
        duration=config.duration,
        iterations=config.iterations,
        ramp_up=config.ramp_up,
        timeout=config.timeout,
        workers=config.workers,
        mode=config.mode,
        think_time=config.think_time,
        think_time_scale=config.think_time_scale,
        rps=config.rps,
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
        credentials_file=config.credentials_file,
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
            )
        );
        queue.put(("ok", list(metrics._samples)));
    } except Exception {
        import traceback;
        queue.put(("error", traceback.format_exc()));
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
) -> MetricsCollector {

    workers = min(config.workers, config.vus);
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
                args=(vu_id_offset, worker_vus, entries, config, topology, worker_tokens, pre_resolved_hosts, queue),
            );
            p.start();
            processes.append(p);
        }

        raw_results = [queue.get() for _ in processes];

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

    for (status, payload) in raw_results {
        if status == "error" {
            if isinstance(payload, str) {
                raise RuntimeError(f"Worker process failed: {payload}");
            }
        }
    }

    merged = MetricsCollector(max_samples=config.max_samples);
    for (_status, samples) in raw_results {
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
