import asyncio;
import json;
import signal;
import socket;
import sys;
import threading;
import time;
import aiohttp;
import from types { SimpleNamespace }
import from .har_parser { HarEntry }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { RequestResult, normalize_path, MetricsCollector, StepResult, percentile, extract_trace_id }
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

def _breach_check(
    config: LoadTestConfig, total: int, error_rate_pct: float, latencies: list[float]
) -> bool {
    # Shared by the cumulative --abort-on-fail watcher and --step-load's
    # per-step evaluator — same threshold comparison, different sample window.
    if total == 0 {
        return False;
    }
    if config.fail_on_error_rate is not None and error_rate_pct > config.fail_on_error_rate {
        return True;
    }
    if (config.fail_on_p95 is not None or config.fail_on_p99 is not None) and not latencies {
        # Every request in this window failed before a response was received
        # (no measured latency) — a dead target must not read as a passing p95/p99.
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

def _thresholds_breached(config: LoadTestConfig, metrics: MetricsCollector) -> bool {
    if metrics.total_count == 0 {
        return False;
    }
    error_rate = metrics.error_count / metrics.total_count * 100.0;
    latencies = [r.latency_ms for r in metrics._samples if r.latency_valid];
    return _breach_check(config, metrics.total_count, error_rate, latencies);
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

async def _duration_watcher(
    duration_s: float,
    stop_requested: asyncio.Event,
) {
    await asyncio.sleep(duration_s);
    if not stop_requested.is_set() {
        print(
            f"\nDuration limit ({duration_s:.0f}s) reached — stopping test.",
            file=sys.stderr,
        );
        stop_requested.set();
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

    csrf_token_by_vu: dict[int, str | None] = {};

    if config.open_loop and config.step_load {
        raise ValueError("open_loop and step_load cannot both be enabled");
    }

    if config.duration and config.step_load {
        raise ValueError(
            "duration and step_load cannot both be enabled — step_load has its "
            "own step-based timing via step_duration/step_max_vus/fail_on_*"
        );
    }

    if config.open_loop {
        if config.rps <= 0 {
            raise ValueError(
                "open_loop mode requires config.rps to be set to a positive value "
                "(fixed arrival rate)"
            );
        }
        tasks = [
            asyncio.create_task(
                _run_open_loop(
                    entries=entries,
                    config=config,
                    metrics=metrics,
                    stop_requested=stop_requested,
                    loop=loop,
                    token_by_vu=token_by_vu,
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts or {},
                    vu_id_offset=vu_id_offset,
                )
            )
        ];
    } elif config.step_load {
        if config.step_vus <= 0 {
            raise ValueError(
                "step_load mode requires config.step_vus to be set to a positive value"
            );
        }
        tasks = [
            asyncio.create_task(
                _run_step_load(
                    entries=entries,
                    config=config,
                    metrics=metrics,
                    stop_requested=stop_requested,
                    loop=loop,
                    token_by_vu=token_by_vu,
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts or {},
                    vu_id_offset=vu_id_offset,
                    run_t_start=run_t_start,
                )
            )
        ];
    } else {
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
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts or {},
                )
            )
            for i in range(config.vus)
        ];
    }

    watcher_task: object | None = None;
    if config.abort_on_fail and _has_thresholds(config) {
        watcher_task = asyncio.create_task(
            _threshold_watcher(config, metrics, stop_requested)
        );
    }

    duration_task: object | None = None;
    if config.duration {
        duration_task = asyncio.create_task(
            _duration_watcher(parse_duration(config.duration), stop_requested)
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
        if duration_task is not None and not duration_task.done() {
            duration_task.cancel();
            try {
                await duration_task;
            } except asyncio.CancelledError {

            }
        }
        if is_main_thread {
            signal.signal(signal.SIGINT, original_sigint);
        }
    }
}

async def _run_iteration(
    session: aiohttp.ClientSession,
    vu_id: int,
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    loop: asyncio.AbstractEventLoop,
    stop_requested: asyncio.Event,
    warned_unrouted: set,
    token: str | None = None,
    csrf_token_by_vu: dict[int, str | None] | None = None,
    topology: TopologyRouter | None = None,
    rps_interval: float = 0.0,
) -> None {
    # One full walk through the recorded HAR sequence for a single logical user
    # session. Shared by both closed-loop (_run_vu, one VU calling this back to
    # back) and open-loop (_run_open_loop, many of these launched concurrently
    # on a fixed schedule) dispatch. rps_interval paces individual sub-requests
    # within the sequence and is only ever non-zero for the closed-loop caller —
    # open-loop paces at the session-arrival level instead (see _run_open_loop).
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
            csrf_token_by_vu=csrf_token_by_vu,
            topology=topology,
        );
        if result is None {
            import from urllib.parse { urlparse as _up }
            path = _up(req_entry.url).path;
            if path not in warned_unrouted {
                print(
                    f"\n\033[33mWarning: no route for '{path}' — skipping. "
                    "Add a matching prefix to --services-map or set --url as fallback.\033[0m",
                    file=sys.stderr,
                );
                warned_unrouted.add(path);
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
    csrf_token_by_vu: dict[int, str | None] | None = None,
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
    warned_unrouted: set = set();

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

            await _run_iteration(
                session=session,
                vu_id=vu_id,
                entries=entries,
                config=config,
                metrics=metrics,
                loop=loop,
                stop_requested=stop_requested,
                warned_unrouted=warned_unrouted,
                token=token,
                csrf_token_by_vu=csrf_token_by_vu,
                topology=topology,
                rps_interval=rps_interval,
            );

            iteration += 1;
        }
    }
}

async def _run_open_loop(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
    token_by_vu: dict[int, str],
    csrf_token_by_vu: dict[int, str | None],
    topology: TopologyRouter | None,
    pre_resolved_hosts: dict[str, str],
    vu_id_offset: int,
) -> None {
    # Fixed-arrival-rate dispatch: launch a new session every 1/rps seconds on a
    # schedule anchored to loop.time() (next_tick += interval, not sleep(interval)
    # after each launch), so per-tick overhead can't accumulate drift. Sessions are
    # NOT awaited before scheduling the next one — unlike _run_vu's closed loop,
    # a slow target here means concurrency grows (in-flight sessions pile up)
    # instead of the achieved rate quietly degrading below the target. --rps in
    # this mode is the session/iteration arrival rate, not a per-request cap:
    # each arrival still runs its recorded HAR sequence start-to-finish, since
    # steps within one session (e.g. login then an authenticated call) are
    # inherently dependent and can't be paced independently of each other.
    timeout = aiohttp.ClientTimeout(total=parse_duration(config.timeout));
    connector = (
        aiohttp.TCPConnector(resolver=_PreResolvedResolver(_host_map=pre_resolved_hosts), limit=0)
        if pre_resolved_hosts
        else aiohttp.TCPConnector(limit=0)
    );
    interval = 1.0 / float(config.rps);
    total_arrivals = config.vus * config.iterations if config.iterations is not None else None;
    warned_unrouted: set = set();

    async with aiohttp.ClientSession(
        connector=connector, timeout=timeout, trace_configs=[_build_ttfb_trace_config()]
    ) as session {
        tasks: list = [];
        i = 0;
        next_tick = loop.time();
        while not stop_requested.is_set() {
            if total_arrivals is not None and i >= total_arrivals {
                break;
            }

            vu_id = vu_id_offset + (i % config.vus);
            tasks.append(
                asyncio.create_task(
                    _run_iteration(
                        session=session,
                        vu_id=vu_id,
                        entries=entries,
                        config=config,
                        metrics=metrics,
                        loop=loop,
                        stop_requested=stop_requested,
                        warned_unrouted=warned_unrouted,
                        token=token_by_vu.get(vu_id),
                        csrf_token_by_vu=csrf_token_by_vu,
                        topology=topology,
                    )
                )
            );
            i += 1;

            next_tick += interval;
            sleep_for = next_tick - loop.time();
            if sleep_for > 0 {
                await asyncio.sleep(sleep_for);
            }
        }

        if tasks {
            await asyncio.gather(*tasks, return_exceptions=True);
        }
    }
}

async def _run_step_load(
    entries: list[HarEntry],
    config: LoadTestConfig,
    metrics: MetricsCollector,
    stop_requested: asyncio.Event,
    loop: asyncio.AbstractEventLoop,
    token_by_vu: dict[int, str],
    csrf_token_by_vu: dict[int, str | None],
    topology: TopologyRouter | None,
    pre_resolved_hosts: dict[str, str],
    vu_id_offset: int,
    run_t_start: float,
) -> None {
    # Ramp VU count in steps to find the capacity knee: start at config.vus,
    # hold for step_duration, evaluate THIS STEP'S OWN traffic window against
    # --fail-on-* thresholds — not the cumulative run, which would dilute a
    # breach at step 5 with four passing steps' worth of samples and hide the
    # knee entirely — then add step_vus more VUs and repeat. Stops the whole
    # run the moment a step breaches (mirrors --abort-on-fail), or holds at
    # step_max_vus once reached if nothing ever breaches.
    #
    # All VUs currently share a single authenticated token by construction
    # (see run_all_vus above — token_by_vu maps every initial VU id to the
    # same authenticate() call); VUs spawned mid-ramp beyond the original
    # config.vus reuse that same shared token rather than going unauthenticated.
    step_duration_s = parse_duration(config.step_duration);
    shared_token = next(iter(token_by_vu.values()), None);

    def _spawn(count: int, start_vu_id: int) -> list {
        return [
            asyncio.create_task(
                _run_vu(
                    vu_id=start_vu_id + i,
                    delay=0.0,
                    entries=entries,
                    config=config,
                    metrics=metrics,
                    stop_requested=stop_requested,
                    loop=loop,
                    token=token_by_vu.get(start_vu_id + i, shared_token),
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts,
                )
            )
            for i in range(count)
        ];
    }

    current_vus = config.vus;
    next_vu_id = vu_id_offset + current_vus;
    step_num = 1;
    tasks: list = _spawn(current_vus, vu_id_offset);
    step_start_s = time.time() - run_t_start;

    while not stop_requested.is_set() {
        await asyncio.sleep(step_duration_s);
        if stop_requested.is_set() {
            break;
        }
        step_end_s = time.time() - run_t_start;
        step_samples = [
            r for r in metrics._samples
            if step_start_s <= (r.timestamp - run_t_start) < step_end_s
        ];
        step_latencies = [r.latency_ms for r in step_samples if r.latency_valid];
        step_errors = sum(
            1 for r in step_samples
            if r.error_type is not None or r.status != r.expected_status
        );
        step_total = len(step_samples);
        step_error_rate = (step_errors / step_total * 100.0) if step_total else 0.0;
        breached = _breach_check(config, step_total, step_error_rate, step_latencies);

        metrics.step_results.append(StepResult(
            step=step_num,
            vus=current_vus,
            start_s=step_start_s,
            end_s=step_end_s,
            total_requests=step_total,
            error_rate_pct=step_error_rate,
            p95_ms=percentile(step_latencies, 95),
            p99_ms=percentile(step_latencies, 99),
            breached=breached,
        ));

        if breached {
            print(
                f"\nStep-load: threshold breached at {current_vus} VUs (step {step_num}) — "
                "stopping ramp and test.",
                file=sys.stderr,
            );
            stop_requested.set();
            break;
        }

        at_ceiling = config.step_max_vus > 0 and current_vus >= config.step_max_vus;
        if not at_ceiling {
            step_add = config.step_vus;
            if config.step_max_vus > 0 {
                step_add = min(step_add, config.step_max_vus - current_vus);
            }
            if step_add > 0 {
                tasks.extend(_spawn(step_add, next_vu_id));
                next_vu_id += step_add;
                current_vus += step_add;
            }
        }

        step_num += 1;
        step_start_s = step_end_s;

        if all(t.done() for t in tasks) {
            # Finite --iterations: every VU (original and ramped-in) has
            # finished its replays on its own — nothing left to ramp against.
            break;
        }
    }

    if tasks {
        await asyncio.gather(*tasks, return_exceptions=True);
    }
}

# H8 — a 200 carrying an application-level error payload (e.g. jac-scale's
# {"ok": false}) counts as success today, since only the HTTP status is ever
# compared. --assert-json adds JSON-body field checks as an extra, optional
# gate on top of the status check — applied globally to every response in the
# run (not per-endpoint), since HAR replays are commonly single-endpoint or
# share a common response envelope; a per-endpoint version is a natural but
# separate future extension.
def parse_assert_json(raw: list[str] | None) -> list[tuple[str, object]] {
    if not raw {
        return [];
    }
    assertions = [];
    for expr in raw {
        if "=" not in expr {
            raise ValueError(
                f"--assert-json '{expr}' must be in PATH=VALUE form, e.g. 'ok=true'"
            );
        }
        idx = expr.index("=");
        path = expr[:idx];
        raw_value = expr[idx + 1:];
        if not path {
            raise ValueError(f"--assert-json '{expr}' has an empty path before '='");
        }
        try {
            value = json.loads(raw_value);
        } except json.JSONDecodeError {
            # Not valid JSON on its own (e.g. `status=ok`) — compare as a
            # literal string so simple values don't need shell-quoted JSON.
            value = raw_value;
        }
        assertions.append((path, value));
    }
    return assertions;
}

def _resolve_json_path(body: object, path: str) -> tuple[bool, object] {
    cursor = body;
    for segment in path.split(".") {
        if isinstance(cursor, dict) {
            if segment not in cursor {
                return (False, None);
            }
            cursor = cursor[segment];
        } elif isinstance(cursor, list) {
            try {
                idx = int(segment);
            } except ValueError {
                return (False, None);
            }
            if idx < 0 or idx >= len(cursor) {
                return (False, None);
            }
            cursor = cursor[idx];
        } else {
            return (False, None);
        }
    }
    return (True, cursor);
}

def _check_json_assertions(body: bytes, assertions: list[tuple[str, object]]) -> str | None {
    # Returns None when every assertion passes, else a short label for
    # error_type. The label never embeds the per-request actual value —
    # only the configured path/expected, which is constant for the whole
    # run — so every request that fails the SAME assertion collapses into
    # one error_breakdown bucket instead of one bucket per distinct body.
    try {
        parsed = json.loads(body.decode("utf-8"));
    } except Exception {
        return "ASSERTION_FAILED: response body is not valid JSON";
    }
    for assertion in assertions {
        path = assertion[0];
        expected = assertion[1];
        resolved = _resolve_json_path(parsed, path);
        if not resolved[0] {
            return f"ASSERTION_FAILED: '{path}' missing from response";
        }
        if resolved[1] != expected {
            return f"ASSERTION_FAILED: '{path}' expected {expected!r}";
        }
    }
    return None;
}

async def _send_request(
    session: aiohttp.ClientSession,
    req_entry: HarEntry,
    vu_id: int,
    config: LoadTestConfig,
    loop: asyncio.AbstractEventLoop,
    token: str | None = None,
    csrf_token_by_vu: dict[int, str | None] | None = None,
    topology: TopologyRouter | None = None,
) -> RequestResult | None {
    headers = dict(req_entry.headers);
    if token {
        headers["Authorization"] = f"Bearer {token}";
    }
    if config.csrf and csrf_token_by_vu is not None and req_entry.method.upper() != "GET" {
        csrf_token = csrf_token_by_vu.get(vu_id);
        if csrf_token {
            headers["X-CSRFToken"] = csrf_token;
        }
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
            if config.csrf and csrf_token_by_vu is not None {
                for cookie_name in ("csrftoken", "_csrf") {
                    if cookie_name in resp.cookies {
                        csrf_token_by_vu[vu_id] = resp.cookies[cookie_name].value;
                        break;
                    }
                }
            }
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
            # Only worth checking JSON assertions on a response that would
            # otherwise already count as a success on status alone — a
            # status mismatch is already a failure, and layering a second,
            # unrelated failure reason on top of it would just be noise.
            assertion_error = None;
            if config.assert_json and resp.status == req_entry.expected_status {
                assertion_error = _check_json_assertions(body, parse_assert_json(config.assert_json));
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
                error_type=assertion_error,
                expected_status=req_entry.expected_status,
                response_text=response_text,
                occurrence=req_entry.occurrence,
                total_occurrences=req_entry.total_occurrences,
                trace_id=extract_trace_id(resp.headers),
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
            latency_valid=False,
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
