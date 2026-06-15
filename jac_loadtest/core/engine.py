"""asyncio VU pool: ramp-up, duration/iteration control, graceful shutdown.

core/ has zero knowledge of jac-scale internals.
"""
from __future__ import annotations

import asyncio
import signal
import socket
import sys
from typing import TYPE_CHECKING

import aiohttp
from aiohttp.abc import AbstractResolver as _AbstractResolver

from jac_loadtest.config import parse_duration
from jac_loadtest.core.metrics import RequestResult, normalize_path

if TYPE_CHECKING:
    from jac_loadtest.core.har_parser import HarEntry
    from jac_loadtest.core.metrics import MetricsCollector
    from jac_loadtest.config import LoadTestConfig
    from jac_loadtest.bridge.topology import TopologyRouter
    from jac_loadtest.bridge.auth import AuthProvider


class _PreResolvedResolver(_AbstractResolver):
    """Resolver that returns a pre-resolved IP for known hostnames, falling back to
    system DNS for anything else. Injected into each worker's TCPConnector so workers
    never issue their own DNS lookups for the target host."""

    def __init__(self, host_map: dict[str, str]) -> None:
        self._host_map = host_map
        self._fallback = aiohttp.ThreadedResolver()

    async def resolve(  # type: ignore[override]
        self, hostname: str, port: int = 0, family: socket.AddressFamily = socket.AF_INET
    ) -> list[dict]:
        if hostname in self._host_map:
            ip = self._host_map[hostname]
            addr_family = socket.AF_INET6 if ":" in ip else socket.AF_INET
            return [{"hostname": hostname, "host": ip, "port": port, "family": addr_family, "proto": 0, "flags": 0}]
        return await self._fallback.resolve(hostname, port, family)  # type: ignore[return-value]

    async def close(self) -> None:
        await self._fallback.close()


async def run_all_vus(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
    vu_id_offset: int = 0,
    pre_authed_tokens: dict[int, str] | None = None,
    pre_resolved_hosts: dict[str, str] | None = None,
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

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout))
    ramp_up_seconds = parse_duration(config.ramp_up)

    # Use pre-computed tokens when provided (multi-process path: auth ran in main process).
    # Otherwise authenticate here (single-process path).
    token_by_vu: dict[int, str] = {}
    if pre_authed_tokens is not None:
        token_by_vu = pre_authed_tokens
    elif auth_provider is not None:
        if not config.url:
            raise ValueError("auth_provider requires --url to be set")
        n_creds = len(auth_provider._credentials)
        # Unique credential indices needed by this worker's VU slice.
        cred_indices = {(vu_id_offset + i) % n_creds for i in range(config.vus)}
        sem = asyncio.Semaphore(min(50, len(cred_indices)))

        async def _do_auth(cred_idx: int) -> tuple[int, str]:
            async with sem:
                async with aiohttp.ClientSession(timeout=timeout) as auth_session:
                    if config.url is not None:
                        tok = await auth_provider.authenticate(cred_idx, auth_session, config.url)
            return cred_idx, tok

        auth_results: list[tuple[int, str]] = list(
            await asyncio.gather(*[_do_auth(idx) for idx in cred_indices])
        )
        token_by_cred = dict(auth_results)
        token_by_vu = {
            vu_id_offset + i: token_by_cred[(vu_id_offset + i) % n_creds]
            for i in range(config.vus)
        }

    tasks = [
        asyncio.create_task(
            _run_vu(
                vu_id=vu_id_offset + i,
                delay=(i / config.vus) * ramp_up_seconds if config.vus > 1 else 0.0,
                entries=entries,
                config=config,
                metrics=metrics,
                stop_requested=stop_requested,
                loop=loop,
                token=token_by_vu.get(vu_id_offset + i),
                topology=topology,
                pre_resolved_hosts=pre_resolved_hosts or {},
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
    token: str | None = None,
    topology: TopologyRouter | None = None,
    pre_resolved_hosts: dict[str, str] | None = None,
) -> None:
    """Single virtual user: wait ramp delay, then replay HAR entries with a pre-fetched token."""
    if delay > 0:
        await asyncio.sleep(delay)

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout))
   
    iteration = 0
    # Warn once per unrouted path within this VU to avoid spam across iterations.
    _warned_unrouted: set[str] = set()

    connector = (
        aiohttp.TCPConnector(resolver=_PreResolvedResolver(pre_resolved_hosts))
        if pre_resolved_hosts
        else aiohttp.TCPConnector()
    )
    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        while not stop_requested.is_set():
            if config.iterations is not None and iteration >= config.iterations:
                break

            for entry in entries:
                if stop_requested.is_set():
                    break
                # Skip the HAR-recorded login; auth is handled by pre-fetched token.
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

    if topology is not None:
        try:
            request_url, service_name = topology.resolve(entry.url)
        except ValueError:
            return None  # caller warns and skips
    else:
        request_url, service_name = entry.url, "monolith"

    import time as _time
    endpoint = normalize_path(entry.url)
    t0 = loop.time()   # high-res clock for latency measurement only
    ts = _time.time()  # wall-clock for cross-process timestamp comparison

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
                timestamp=ts,
                vu_id=vu_id,
                error_type=None,
                occurrence=entry.occurrence,
                total_occurrences=entry.total_occurrences,
            )

    except asyncio.TimeoutError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=parse_duration(config.timeout) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="TIMEOUT",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except aiohttp.ClientConnectorDNSError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="DNS_ERROR",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except aiohttp.ClientSSLError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="SSL_ERROR",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except aiohttp.ClientConnectorError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="CONNECTION_REFUSED",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except aiohttp.ServerDisconnectedError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="SERVER_DISCONNECTED",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except aiohttp.ClientOSError:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="CONNECTION_RESET",
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )

    except Exception as e:
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type=str(e).upper() or type(e).__name__.upper(),
            occurrence=entry.occurrence,
            total_occurrences=entry.total_occurrences,
        )
