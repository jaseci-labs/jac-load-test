"""asyncio VU pool: ramp-up, duration/iteration control, graceful shutdown.

core/ has zero knowledge of jac-scale internals.
"""
from __future__ import annotations

import asyncio
import signal
import sys
from typing import TYPE_CHECKING

import aiohttp

from jac_loadtest.config import parse_duration
from jac_loadtest.core.metrics import RequestResult, normalize_path

if TYPE_CHECKING:
    from jac_loadtest.core.har_parser import HarEntry
    from jac_loadtest.core.metrics import MetricsCollector
    from jac_loadtest.config import LoadTestConfig
    from jac_loadtest.bridge.topology import TopologyRouter
    from jac_loadtest.bridge.auth import AuthProvider


async def run_all_vus(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
) -> None:
    """Spawn N virtual user coroutines and run until duration/iterations/stop signal."""
    stop_requested = asyncio.Event()
    loop = asyncio.get_event_loop()

    original_sigint = signal.getsignal(signal.SIGINT)

    def _on_second_sigint(sig: int, frame: object) -> None:
        sys.exit(130)

    def _on_first_sigint(sig: int, frame: object) -> None:
        stop_requested.set()
        signal.signal(signal.SIGINT, _on_second_sigint)

    signal.signal(signal.SIGINT, _on_first_sigint)

    ramp_up_seconds = parse_duration(config.ramp_up)

    tasks = [
        asyncio.create_task(
            _run_vu(
                vu_id=i,
                delay=(i / config.vus) * ramp_up_seconds if config.vus > 1 else 0.0,
                entries=entries,
                config=config,
                metrics=metrics,
                stop_requested=stop_requested,
                loop=loop,
                auth_provider=auth_provider,
                topology=topology,
            )
        )
        for i in range(config.vus)
    ]

    try:
        await asyncio.gather(*tasks)
    finally:
        signal.signal(signal.SIGINT, original_sigint)


async def _run_vu(
    vu_id: int,
    delay: float,
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
    auth_provider: AuthProvider | None = None,
    topology: TopologyRouter | None = None,
) -> None:
    """Single virtual user: wait ramp delay, authenticate, then replay HAR entries."""
    if delay > 0:
        await asyncio.sleep(delay)

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout))
    duration_seconds = parse_duration(config.duration)
    t_start = loop.time()
    iteration = 0
    # Warn once per unrouted path within this VU to avoid spam across iterations.
    _warned_unrouted: set[str] = set()

    async with aiohttp.ClientSession(timeout=timeout) as session:
        # Authenticate once before entering the request loop.
        token: str | None = None
        if auth_provider is not None:
            if not config.url:
                raise ValueError("auth_provider requires --url to be set")
            token = await auth_provider.authenticate(vu_id, session, config.url)

        while not stop_requested.is_set():
            if loop.time() - t_start >= duration_seconds:
                break
            if config.iterations is not None and iteration >= config.iterations:
                break

            for entry in entries:
                if stop_requested.is_set():
                    break
                # Skip the HAR-recorded login; auth is handled by the pre-loop step.
                if entry.is_login and token is not None:
                    continue
                result = await _send_request(
                    session=session,
                    entry=entry,
                    vu_id=vu_id,
                    config=config,
                    loop=loop,
                    token=token,
                    topology=topology,
                )
                if result is None:
                    # topology.resolve() found no route (e.g. /static/* fetch entries
                    # that look like API calls but have no matching service prefix).
                    from urllib.parse import urlparse as _up
                    path = _up(entry.url).path
                    if path not in _warned_unrouted:
                        print(
                            f"\n\033[33mWarning: no route for '{path}' — skipping. "
                            "Add a matching prefix to --services-map or set --url as fallback.\033[0m",
                            file=sys.stderr,
                        )
                        _warned_unrouted.add(path)
                    continue
                metrics.record(result)
                if config.think_time == "real" and entry.think_time_ms > 0:
                    await asyncio.sleep(
                        entry.think_time_ms / 1000.0 * config.think_time_scale
                    )

            iteration += 1


async def _send_request(
    session: aiohttp.ClientSession,
    entry: HarEntry,
    vu_id: int,
    config: LoadTestConfig,
    loop: asyncio.AbstractEventLoop,
    token: str | None = None,
    topology: TopologyRouter | None = None,
) -> RequestResult | None:
    """Send one HTTP request and return a RequestResult, or None if no route exists."""
    headers = dict(entry.headers)
    if token:
        headers["Authorization"] = f"Bearer {token}"

    # Resolve the final request URL and service label via topology.
    # topology=None means monolith mode: use entry.url as-is, label "monolith".
    if topology is not None:
        try:
            request_url, service_name = topology.resolve(entry.url)
        except ValueError:
            return None  # caller warns and skips
    else:
        request_url, service_name = entry.url, "monolith"

    # Endpoint identifier for metrics uses the original entry URL (path only, normalized).
    endpoint = normalize_path(entry.url)
    t0 = loop.time()

    try:
        async with session.request(
            method=entry.method,
            url=request_url,
            headers=headers,
            data=entry.body,
            allow_redirects=False,
        ) as resp:
            body = await resp.read()
            latency_ms = (loop.time() - t0) * 1000
            return RequestResult(
                endpoint=endpoint,
                service=service_name,
                status=resp.status,
                latency_ms=latency_ms,
                bytes_received=len(body),
                timestamp=t0,
                vu_id=vu_id,
                error_type=None,
            )

    except asyncio.TimeoutError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=parse_duration(config.timeout) * 1000,
            bytes_received=0,
            timestamp=t0,
            vu_id=vu_id,
            error_type="TIMEOUT",
        )

    except aiohttp.ClientConnectorError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            bytes_received=0,
            timestamp=t0,
            vu_id=vu_id,
            error_type="CONNECTION_REFUSED",
        )
