"""Multi-process coordinator: splits VUs across worker processes, merges metrics.

Each worker gets its own asyncio event loop and a contiguous slice of VU IDs.
Results are returned via a multiprocessing.Queue and merged into one MetricsCollector.
"""
from __future__ import annotations

import asyncio
import dataclasses
import multiprocessing
import multiprocessing.process
import multiprocessing.queues
import socket

from jac_loadtest.core.har_parser import HarEntry
from jac_loadtest.core.metrics import MetricsCollector, RequestResult
from jac_loadtest.config import LoadTestConfig
from jac_loadtest.bridge.topology import TopologyRouter
from jac_loadtest.bridge.auth import AuthProvider

# Result payload sent from each worker: ("ok", samples) | ("error", msg)
WorkerResult = tuple[str, list[RequestResult] | str]


def _resolve_hosts(url: str) -> dict[str, str]:
    """Resolve the target URL's hostname to an IP in the main process.

    Returns a {hostname: ip} mapping that workers inject into their connector's
    resolver so they skip DNS lookups entirely — eliminating the per-worker DNS
    thundering herd when many workers start simultaneously.
    """
    from urllib.parse import urlparse
    hostname = urlparse(url).hostname
    if not hostname:
        return {}
    try:
        infos = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        if infos:
            return {hostname: str(infos[0][4][0])}
    except socket.gaierror:
        pass
    return {}


async def _pre_authenticate_all(
    config: LoadTestConfig,
    auth_provider: AuthProvider,
    total_vus: int,
) -> dict[int, str]:
    """Authenticate all credentials once in the main process before spawning workers.

    Returns a token_by_vu mapping covering VU IDs 0..total_vus-1.
    Running auth centrally means workers receive tokens directly and never touch the
    auth endpoint, eliminating the per-worker auth burst at startup.
    """
    import aiohttp
    from jac_loadtest.config import parse_duration

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout))
    n_creds = len(auth_provider._credentials)
    cred_indices = {i % n_creds for i in range(total_vus)}
    sem = asyncio.Semaphore(min(50, len(cred_indices)))

    async def _do_auth(cred_idx: int) -> tuple[int, str]:
        async with sem:
            async with aiohttp.ClientSession(timeout=timeout) as auth_session:
                if config.url is not None:
                    tok = await auth_provider.authenticate(cred_idx, auth_session, config.url)
        return cred_idx, tok

    results: list[tuple[int, str]] = list(
        await asyncio.gather(*[_do_auth(idx) for idx in cred_indices])
    )
    token_by_cred = dict(results)
    return {i: token_by_cred[i % n_creds] for i in range(total_vus)}


def _worker_fn(
    vu_id_offset: int,
    worker_vus: int,
    entries: list[HarEntry],
    config: LoadTestConfig,
    topology: TopologyRouter | None,
    token_by_vu: dict[int, str] | None,
    pre_resolved_hosts: dict[str, str],
    queue: multiprocessing.queues.Queue[WorkerResult],
) -> None:
    """Entry point for each worker process. Must be a module-level function for pickling."""
    from jac_loadtest.core.engine import run_all_vus

    worker_config = dataclasses.replace(config, vus=worker_vus)
    metrics = MetricsCollector(max_samples=config.max_samples)
    try:
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
        )
        queue.put(("ok", list(metrics._samples)))
    except Exception:
        import traceback
        queue.put(("error", traceback.format_exc()))


def _compute_slices(total_vus: int, workers: int) -> list[tuple[int, int]]:
    """Return [(vu_id_offset, worker_vu_count), ...] distributing VUs as evenly as possible."""
    base = total_vus // workers
    remainder = total_vus % workers
    slices: list[tuple[int, int]] = []
    offset = 0
    for i in range(workers):
        count = base + (1 if i < remainder else 0)
        if count > 0:
            slices.append((offset, count))
            offset += count
    return slices


def run_multiprocess(
    entries: list[HarEntry],
    config: LoadTestConfig,
    topology: TopologyRouter | None,
    auth_provider: AuthProvider | None,
) -> MetricsCollector:
    """Spawn worker processes, collect their samples, and return a merged MetricsCollector.

    Worker count is capped at config.vus so we never spawn idle processes.
    Uses the 'spawn' start method for asyncio compatibility (no fork-inherited event loops).
    Auth is performed once in the main process so workers receive tokens directly,
    avoiding the per-worker auth burst at startup.
    """
    workers = min(config.workers, config.vus)
    slices = _compute_slices(config.vus, workers)

    # Resolve the target hostname once here so workers skip DNS entirely.
    # Without this, all workers resolve DNS simultaneously on their first request,
    # causing a thundering herd that overwhelms the DNS resolver.
    pre_resolved_hosts: dict[str, str] = _resolve_hosts(config.url) if config.url else {}

    # Authenticate all credentials once here before spawning any workers.
    # This collapses N*workers simultaneous auth storms into a single controlled burst.
    token_by_vu: dict[int, str] | None = None
    if auth_provider is not None:
        if not config.url:
            raise ValueError("auth_provider requires --url to be set")
        token_by_vu = asyncio.run(_pre_authenticate_all(config, auth_provider, config.vus))

    ctx = multiprocessing.get_context("spawn")
    queue: multiprocessing.queues.Queue[WorkerResult] = ctx.Queue()

    processes: list[multiprocessing.process.BaseProcess] = []
    try:
        for vu_id_offset, worker_vus in slices:
            worker_tokens = (
                {vu_id: token_by_vu[vu_id] for vu_id in range(vu_id_offset, vu_id_offset + worker_vus)}
                if token_by_vu is not None else None
            )
            p = ctx.Process(
                target=_worker_fn,
                args=(vu_id_offset, worker_vus, entries, config, topology, worker_tokens, pre_resolved_hosts, queue),
            )
            p.start()
            processes.append(p)

        # Collect exactly one result per worker.
        raw_results: list[WorkerResult] = [queue.get() for _ in processes]

        for p in processes:
            p.join()

    finally:
        # Terminate any workers still alive (e.g. after KeyboardInterrupt).
        for p in processes:
            if p.is_alive():
                p.terminate()

    # Surface the first error found across workers.
    for status, payload in raw_results:
        if status == "error":
            assert isinstance(payload, str)
            raise RuntimeError(f"Worker process failed: {payload}")

    merged = MetricsCollector(max_samples=config.max_samples)
    for _status, samples in raw_results:
        assert isinstance(samples, list)
        for result in samples:
            merged.record(result)

    return merged
