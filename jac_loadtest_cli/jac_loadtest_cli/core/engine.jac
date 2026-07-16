import asyncio;
import signal;
import socket;
import sys;
import threading;
import time;
import aiohttp;
import from types { SimpleNamespace }
import from .har_parser { HarEntry }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { RequestResult, normalize_path, MetricsCollector, percentile }
import from ..bridge.auth { AuthProvider }
import from ..bridge.topology { TopologyRouter }

def _build_ttfb_trace_config() -> aiohttp.TraceConfig {
    # on_request_end fires once response status + headers have been parsed
    # (resp.start()), before the body is read — i.e. exactly at time-to-first-byte.
    async def on_request_end(
        session: aiohttp.ClientSession,
        trace_ctx: object,
        params: object,
    ) {
        # aiohttp wraps our trace_request_ctx in a SimpleNamespace; the object we
        # passed via `trace_request_ctx=` lives at trace_ctx.trace_request_ctx.
        trace_ctx.trace_request_ctx.first_byte_time = asyncio.get_event_loop().time();
    }

    trace_config = aiohttp.TraceConfig();
    trace_config.on_request_end.append(on_request_end);
    return trace_config;
}

obj _PreResolvedResolver {
    has _host_map: dict[str];
    has _fallback: object = None;

    def __post_init__() {
        self._fallback = aiohttp.ThreadedResolver();
    }

    async def resolve(hostname: str, port: int = 0, family: object = socket.AF_INET) -> list {
        if hostname in self._host_map {
            ip = self._host_map[hostname];
            addr_family = socket.AF_INET6 if ":" in ip else socket.AF_INET;
            return [{"hostname": hostname, "host": ip, "port": port, "family": addr_family, "proto": 0, "flags": 0}];
        }
        return await self._fallback.resolve(hostname, port, family);
    }

    async def close() {
        await self._fallback.close();
    }
}

def _has_thresholds(config: LoadTestConfig) -> bool {
    return (
        config.fail_on_error_rate is not None
        or config.fail_on_p95 is not None
        or config.fail_on_p99 is not None
    );
}

def _thresholds_breached(config: LoadTestConfig, metrics: MetricsCollector) -> bool {
    if metrics.total_count == 0 {
        return False;
    }
    if config.fail_on_error_rate is not None {
        error_rate = metrics.error_count / metrics.total_count * 100.0;
        if error_rate > config.fail_on_error_rate {
            return True;
        }
    }
    latencies = [r.latency_ms for r in metrics._samples if r.latency_valid];
    if (config.fail_on_p95 is not None or config.fail_on_p99 is not None) and not latencies {
        # Every request so far failed before a response was received (no
        # measured latency) — a dead target must not read as a passing p95/p99.
        return True;
    }
    if latencies {
        if config.fail_on_p95 is not None and percentile(latencies, 95) > config.fail_on_p95 {
            return True;
        }
        if config.fail_on_p99 is not None and percentile(latencies, 99) > config.fail_on_p99 {
            return True;
        }
    }
    return False;
}

async def _threshold_watcher(
    config: LoadTestConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
) {
    loop = asyncio.get_event_loop();
    start = loop.time();
    delay_s = parse_duration(config.threshold_start_delay);
    while not stop_requested.is_set() {
        await asyncio.sleep(1.0);
        if loop.time() - start < delay_s {
            continue;
        }
        if _thresholds_breached(config, metrics) {
            print(
                "\nThreshold breached — stopping test early (--abort-on-fail).",
                file=sys.stderr,
            );
            stop_requested.set();
            break;
        }
    }
}

async def _stream_metrics(
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    t_start: float,
    stream_metrics_callback: object,
    interval: float = 10.0,
) {
    while not stop_requested.is_set() {
        await asyncio.sleep(interval);
        stream_metrics_callback(metrics.snapshot_now(t_start));
    }
}

def _print_debug(result: RequestResult) {
    status_str = str(result.status) if result.status else (result.error_type or "ERR");
    print(
        f"  [VU {result.vu_id:3d}] {result.endpoint}  {status_str}  {result.latency_ms:.1f}ms",
        file=sys.stderr,
    );
}

async def run_all_vus(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
    vu_id_offset: int = 0,
    pre_authed_tokens: dict[int, str] | None = None,
    pre_resolved_hosts: dict[str, str] | None = None,
    stream_metrics_callback: object | None = None,
    t_start: float | None = None,
    stream_interval: float = 10.0,
    stop_requested: object | None = None,
) {
    stop_requested = stop_requested if stop_requested is not None else asyncio.Event();
    loop = asyncio.get_event_loop();
    run_t_start = t_start if t_start is not None else time.time();

    # signal.signal() raises ValueError off the main thread (e.g. embedders like
    # the web sv walker that run this from a background thread/executor) — Ctrl-C
    # handling is a main-thread-only CLI nicety, so skip it there and rely on the
    # caller-supplied stop_requested instead.
    is_main_thread = threading.current_thread() is threading.main_thread();
    original_sigint = signal.getsignal(signal.SIGINT) if is_main_thread else None;

    def _on_second_sigint(sig: int, frame: object) {
        sys.exit(130);
    }

    def _on_first_sigint(sig: int, frame: object) {
        stop_requested.set();
        signal.signal(signal.SIGINT, _on_second_sigint);
    }

    if is_main_thread {
        signal.signal(signal.SIGINT, _on_first_sigint);
    }

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout));
    ramp_up_seconds = parse_duration(config.ramp_up);

    token_by_vu = {};
    if pre_authed_tokens is not None {
        token_by_vu = pre_authed_tokens;
    } elif auth_provider is not None {
        if not config.url {
            raise ValueError("auth_provider requires --url to be set");
        }
        token = "";
        async with aiohttp.ClientSession(timeout=timeout) as auth_session {
            if config.url is not None {
                token = await auth_provider.authenticate(vu_id_offset, auth_session, config.url);
            }
        }
        token_by_vu = {vu_id_offset + i: token for i in range(config.vus)};
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
    ];

    watcher_task: object | None = None;
    if config.abort_on_fail and _has_thresholds(config) {
        watcher_task = asyncio.create_task(
            _threshold_watcher(config, metrics, stop_requested)
        );
    }

    stream_task: object | None = None;
    if stream_metrics_callback is not None {
        stream_task = asyncio.create_task(
            _stream_metrics(metrics, stop_requested, run_t_start, stream_metrics_callback, interval=stream_interval)
        );
    }

    try {
        await asyncio.gather(*tasks);
    } finally {
        if stream_task is not None and not stream_task.done() {
            stream_task.cancel();
            try {
                await stream_task;
            } except asyncio.CancelledError {

            }
        }
        if watcher_task is not None and not watcher_task.done() {
            watcher_task.cancel();
            try {
                await watcher_task;
            } except asyncio.CancelledError {
                
            }
        }
        if is_main_thread {
            signal.signal(signal.SIGINT, original_sigint);
        }
    }
}

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
) -> None {
    if delay > 0 {
        await asyncio.sleep(delay);
    }

    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout));

    # Per-VU interval to achieve global RPS cap: vus / rps seconds between requests.
    rps_interval: float = float(config.vus) / float(config.rps) if config.rps > 0 else 0.0;

    iteration = 0;
    _warned_unrouted = set();

    connector = (
        aiohttp.TCPConnector(resolver=_PreResolvedResolver(_host_map=pre_resolved_hosts))
        if pre_resolved_hosts
        else aiohttp.TCPConnector()
    );
    async with aiohttp.ClientSession(
        connector=connector, timeout=timeout, trace_configs=[_build_ttfb_trace_config()]
    ) as session {
        while not stop_requested.is_set() {
            if config.iterations is not None and iteration >= config.iterations {
                break;
            }

            for req_entry in entries {
                if stop_requested.is_set() {
                    break;
                }
                if req_entry.is_login and token is not None {
                    continue;
                }

                if rps_interval > 0 {
                    await asyncio.sleep(rps_interval);
                }

                result = await _send_request(
                    session=session,
                    req_entry=req_entry,
                    vu_id=vu_id,
                    config=config,
                    loop=loop,
                    token=token,
                    topology=topology,
                );
                if result is None {
                    import from urllib.parse { urlparse as _up }
                    path = _up(req_entry.url).path;
                    if path not in _warned_unrouted {
                        print(
                            f"\n\033[33mWarning: no route for '{path}' — skipping. "
                            "Add a matching prefix to --services-map or set --url as fallback.\033[0m",
                            file=sys.stderr,
                        );
                        _warned_unrouted.add(path);
                    }
                    continue;
                }
                metrics.record(result);

                if config.debug {
                    _print_debug(result);
                }

                if config.think_time in ("real", "scaled") and req_entry.think_time_ms > 0 {
                    await asyncio.sleep(
                        req_entry.think_time_ms / 1000.0 * config.think_time_scale
                    );
                }
            }

            iteration += 1;
        }
    }
}

async def _send_request(
    session: aiohttp.ClientSession,
    req_entry: HarEntry,
    vu_id: int,
    config: LoadTestConfig,
    loop: asyncio.AbstractEventLoop,
    token: str | None = None,
    topology: TopologyRouter | None = None,
) -> RequestResult | None {
    headers = dict(req_entry.headers);
    if token {
        headers["Authorization"] = f"Bearer {token}";
    }

    if topology is not None {
        try {
            resolve_result = topology.resolve(req_entry.url);
            request_url = resolve_result[0];
            service_name = resolve_result[1];
        } except ValueError {
            return None;
        }
    } else {
        request_url = req_entry.url;
        service_name = "monolith";
    }

    import time as _time;
    endpoint = normalize_path(req_entry.url);
    t0 = loop.time();
    ts = _time.time();
    trace_ctx = SimpleNamespace();

    try {
        async with session.request(
            method=req_entry.method,
            url=request_url,
            headers=headers,
            data=req_entry.body,
            allow_redirects=False,
            trace_request_ctx=trace_ctx,
        ) as resp {
            body = await resp.read();
            latency_ms = (loop.time() - t0) * 1000;
            first_byte_time = getattr(trace_ctx, "first_byte_time", None);
            ttfb_ms = (first_byte_time - t0) * 1000 if first_byte_time is not None else latency_ms;
            response_text = None;
            if resp.status != req_entry.expected_status {
                try {
                    response_text = body.decode("utf-8", errors="replace")[:500].strip();
                } except Exception {
                    response_text = repr(body[:200]);
                }
            }
            return RequestResult(
                endpoint=endpoint,
                service=service_name,
                status=resp.status,
                latency_ms=latency_ms,
                ttfb_ms=ttfb_ms,
                bytes_received=len(body),
                timestamp=ts,
                vu_id=vu_id,
                error_type=None,
                expected_status=req_entry.expected_status,
                response_text=response_text,
                occurrence=req_entry.occurrence,
                total_occurrences=req_entry.total_occurrences,
            );
        }
    } except asyncio.TimeoutError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=parse_duration(config.timeout) * 1000,
            ttfb_ms=parse_duration(config.timeout) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="TIMEOUT",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
        );
    } except aiohttp.ClientConnectorDNSError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            ttfb_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="DNS_ERROR",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
            latency_valid=False,
        );
    } except aiohttp.ClientSSLError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            ttfb_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="SSL_ERROR",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
            latency_valid=False,
        );
    } except aiohttp.ClientConnectorError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=0.0,
            ttfb_ms=0.0,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="CONNECTION_REFUSED",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
            latency_valid=False,
        );
    } except aiohttp.ServerDisconnectedError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            ttfb_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="SERVER_DISCONNECTED",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
        );
    } except aiohttp.ClientOSError {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            ttfb_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type="CONNECTION_RESET",
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
        );
    } except Exception as e {
        return RequestResult(
            endpoint=endpoint,
            service=service_name,
            status=0,
            latency_ms=(loop.time() - t0) * 1000,
            ttfb_ms=(loop.time() - t0) * 1000,
            bytes_received=0,
            timestamp=ts,
            vu_id=vu_id,
            error_type=str(e).upper() or type(e).__name__.upper(),
            occurrence=req_entry.occurrence,
            total_occurrences=req_entry.total_occurrences,
        );
    }
}
