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
import from .correlation { CorrelationRule, CorrelationTable, apply_correlations }
import from .parameterize { ParamContext, ParamRule, apply_params }
import from ..config { parse_duration, LoadTestConfig }
import from ..core.metrics { RequestResult, normalize_path, MetricsCollector, StepResult, percentile, extract_trace_id }
import from ..bridge.auth { AuthProvider }
import from .infra_block { body_fingerprint as infra_fingerprint, load_proxies, proxy_for }
import from ..bridge.body_check { ResponseShape, baseline_shapes as baseline_shapes_from, check_body, check_shape }
import from ..bridge.topology { TopologyRouter }

def _corr_endpoint_path(url: str) -> str {
    # The raw path, not normalize_path()'s version: that rewrites id-looking
    # segments to "{id}", and a rule or baseline needs to name the real endpoint.
    import from urllib.parse { urlparse }
    return urlparse(url).path;
}

def _report_auth_failures(outcome: object) -> None {
    # Loud on purpose. A run that quietly lost half its identities still produces
    # a plausible-looking report, and nothing else in it would say why the
    # multi-user picture is thinner than requested.
    if not outcome.failures {
        return;
    }
    print(
        f"\n\033[33mWarning: {outcome.failed_count()} of {outcome.total_accounts} "
        f"account(s) failed to authenticate; continuing on the remaining "
        f"{outcome.active_accounts}. VUs were re-spread over those, so concurrency "
        f"is unchanged but identity diversity is lower than requested.\033[0m",
        file=sys.stderr,
    );
    for (username, reason) in outcome.failures {
        print(f"  {username}: {reason}", file=sys.stderr);
    }
}

def _entries_have_tokens(entries: list[HarEntry]) -> bool {
    # Tokens cost nothing when absent, but building a ParamContext per iteration
    # for every run would. Checked once per iteration against the recorded
    # entries, which never change mid-run.
    import from .parameterize { has_tokens }
    for item in entries {
        if has_tokens(item.body) or has_tokens(item.url) {
            return True;
        }
        for value in item.headers.values() {
            if has_tokens(value) {
                return True;
            }
        }
    }
    return False;
}

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
        #
        # It is None for any request issued on this session that did not pass one
        # -- a mid-run re-authentication POST, for instance (Phase 7b). Those are
        # not measured requests, so there is nothing to record; without this guard
        # the callback raises inside aiohttp and the caller sees a confusing
        # AttributeError instead of whatever it was actually doing.
        request_ctx = getattr(trace_ctx, "trace_request_ctx", None);
        if request_ctx is None {
            return;
        }
        request_ctx.first_byte_time = asyncio.get_event_loop().time();
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
    correlation_rules: list[CorrelationRule] | None = None,
    param_rules: list[ParamRule] | None = None,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
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
        # Phase 7b — one token per VU, from that VU's own account. Authenticated
        # up front, before the replay loop, so login latency never lands in the
        # measured window and the auth endpoint sees one burst rather than
        # traffic mixed through the run.
        async with aiohttp.ClientSession(timeout=timeout) as auth_session {
            if config.url is not None {
                auth_outcome = await auth_provider.authenticate_all(
                    [vu_id_offset + i for i in range(config.vus)],
                    auth_session,
                    config.url,
                    tolerate_failures=config.skip_failed_accounts,
                );
                token_by_vu = auth_outcome.tokens;
                _report_auth_failures(auth_outcome);
            }
        }
    }

    # Phase 8b — per-endpoint response shapes from the recording, used to spot a
    # walker that came back empty where it previously had results. Free: the HAR
    # already carries it (HarEntry.recorded_response, added for correlation), so
    # there is no baseline run to make.
    if baseline_shapes is None and (config.body_check or config.check_shape) {
        baseline_shapes = baseline_shapes_from(entries);
    }
    if config_proxies is None {
        config_proxies = load_proxies(config.proxy_pool);
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
                    correlation_rules=correlation_rules,
                    auth_provider=auth_provider,
                    param_rules=param_rules,
                    baseline_shapes=baseline_shapes,
                    config_proxies=config_proxies,
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
                    correlation_rules=correlation_rules,
                    auth_provider=auth_provider,
                    param_rules=param_rules,
                    baseline_shapes=baseline_shapes,
                    config_proxies=config_proxies,
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
                    token_by_vu=token_by_vu,
                    auth_provider=auth_provider,
                    param_rules=param_rules,
                    baseline_shapes=baseline_shapes,
                    config_proxies=config_proxies,
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts or {},
                    correlation_rules=correlation_rules,
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
    token_by_vu: dict[int, str] | None = None,
    csrf_token_by_vu: dict[int, str | None] | None = None,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
    rps_interval: float = 0.0,
    correlation_rules: list[CorrelationRule] | None = None,
    param_rules: list[ParamRule] | None = None,
    iteration: int = 0,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
) -> None {
    # One full walk through the recorded HAR sequence for a single logical user
    # session. Shared by both closed-loop (_run_vu, one VU calling this back to
    # back) and open-loop (_run_open_loop, many of these launched concurrently
    # on a fixed schedule) dispatch. rps_interval paces individual sub-requests
    # within the sequence and is only ever non-zero for the closed-loop caller —
    # open-loop paces at the session-arrival level instead (see _run_open_loop).
    #
    # Phase 7a — the correlation table is created here, once per iteration, and
    # never shared with another VU. Per VU because the whole point is that VU 3
    # threads the ids VU 3 was given; per iteration because iteration 2 creates a
    # fresh object and must act on that one, not the one iteration 1 made.
    correlation_table = CorrelationTable(values={}) if correlation_rules else None;

    # Phase 7c — the VU's account row anchors {{account.<col>}}, so a VU's data
    # stays consistent with the identity it authenticated as.
    param_ctx: ParamContext | None = None;
    if param_rules or _entries_have_tokens(entries) {
        account_extra: dict = {};
        if auth_provider is not None {
            account_extra = dict(auth_provider.credential_for(vu_id).extra);
        }
        param_ctx = ParamContext(
            vu_id=vu_id, iteration=iteration, account=account_extra
        );
    }
    for req_entry in entries {
        if stop_requested.is_set() {
            break;
        }
        # The recording's own login call is redundant once this VU already holds
        # a token from the pre-run burst -- replaying it would just add auth
        # traffic the run is not trying to measure.
        if req_entry.is_login and token_by_vu is not None and token_by_vu.get(vu_id) is not None {
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
            token_by_vu=token_by_vu,
            csrf_token_by_vu=csrf_token_by_vu,
            topology=topology,
            auth_provider=auth_provider,
            correlation_rules=correlation_rules,
            correlation_table=correlation_table,
            param_rules=param_rules,
            param_ctx=param_ctx,
            baseline_shapes=baseline_shapes,
            config_proxies=config_proxies,
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
    token_by_vu: dict[int, str] | None = None,
    csrf_token_by_vu: dict[int, str | None] | None = None,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
    pre_resolved_hosts: dict[str, str] | None = None,
    correlation_rules: list[CorrelationRule] | None = None,
    param_rules: list[ParamRule] | None = None,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
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
                token_by_vu=token_by_vu,
                csrf_token_by_vu=csrf_token_by_vu,
                auth_provider=auth_provider,
                param_rules=param_rules,
                baseline_shapes=baseline_shapes,
                config_proxies=config_proxies,
                iteration=iteration,
                topology=topology,
                rps_interval=rps_interval,
                correlation_rules=correlation_rules,
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
    correlation_rules: list[CorrelationRule] | None = None,
    auth_provider: AuthProvider | None = None,
    param_rules: list[ParamRule] | None = None,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
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
                        token_by_vu=token_by_vu,
                        auth_provider=auth_provider,
                        param_rules=param_rules,
                        baseline_shapes=baseline_shapes,
                        config_proxies=config_proxies,
                        iteration=i,
                        csrf_token_by_vu=csrf_token_by_vu,
                        topology=topology,
                        correlation_rules=correlation_rules,
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
    correlation_rules: list[CorrelationRule] | None = None,
    auth_provider: AuthProvider | None = None,
    param_rules: list[ParamRule] | None = None,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
) -> None {
    # Ramp VU count in steps to find the capacity knee: start at config.vus,
    # hold for step_duration, evaluate THIS STEP'S OWN traffic window against
    # --fail-on-* thresholds — not the cumulative run, which would dilute a
    # breach at step 5 with four passing steps' worth of samples and hide the
    # knee entirely — then add step_vus more VUs and repeat. Stops the whole
    # run the moment a step breaches (mirrors --abort-on-fail), or holds at
    # step_max_vus once reached if nothing ever breaches.
    #
    # Only the initial config.vus VUs were authenticated before the run, so a VU
    # ramped in mid-test has no entry of its own. It reuses one of the existing
    # tokens, cycling through them in the same order the account pool assigns
    # them, so a ramp over an --accounts pool keeps spreading across identities
    # instead of piling every new VU onto one.
    step_duration_s = parse_duration(config.step_duration);
    seeded_vu_ids = sorted(token_by_vu.keys());

    def _ensure_token(vu_id: int) -> None {
        if vu_id in token_by_vu or not seeded_vu_ids {
            return;
        }
        token_by_vu[vu_id] = token_by_vu[seeded_vu_ids[vu_id % len(seeded_vu_ids)]];
    }

    def _spawn(count: int, start_vu_id: int) -> list {
        for i in range(count) {
            _ensure_token(start_vu_id + i);
        }
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
                    token_by_vu=token_by_vu,
                    auth_provider=auth_provider,
                    param_rules=param_rules,
                    baseline_shapes=baseline_shapes,
                    config_proxies=config_proxies,
                    csrf_token_by_vu=csrf_token_by_vu,
                    topology=topology,
                    pre_resolved_hosts=pre_resolved_hosts,
                    correlation_rules=correlation_rules,
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
    # Phase 8b — an assertion may be scoped to one endpoint by prefixing it with
    # that endpoint and a colon, mirroring --slo:
    #
    #   --assert-json 'ok=true'                              every response
    #   --assert-json '/walker/AddTodo:reports.0.id=*'       just that endpoint
    #
    # Returns (path, value, endpoint) triples; endpoint is "" for the global
    # form, which keeps working unchanged. `*` as the value asserts presence
    # rather than equality, which is what you usually want for an id.
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
        endpoint = "";
        if ":" in path {
            # Split on the last colon so a path may not contain one, but an
            # endpoint like "/walker/X" is unambiguous.
            (candidate, rest) = path.rsplit(":", 1);
            if candidate and rest {
                endpoint = candidate.strip();
                path = rest.strip();
            }
        }
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
        assertions.append((path, value, endpoint));
    }
    return assertions;
}

def assertions_for(assertions: list, endpoint: str) -> list {
    # The global ones plus any scoped to this endpoint.
    import from .correlation { endpoint_matches }
    return [
        item for item in assertions
        if not item[2] or endpoint_matches(item[2], endpoint)
    ];
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
        if expected == "*" {
            # Presence-only: the path resolved above, which is the whole check.
            # Ids and tokens are the usual case -- you care that one came back,
            # not what it was.
            continue;
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
    token_by_vu: dict[int, str] | None = None,
    csrf_token_by_vu: dict[int, str | None] | None = None,
    topology: TopologyRouter | None = None,
    auth_provider: AuthProvider | None = None,
    correlation_rules: list[CorrelationRule] | None = None,
    correlation_table: CorrelationTable | None = None,
    param_rules: list[ParamRule] | None = None,
    param_ctx: ParamContext | None = None,
    baseline_shapes: dict | None = None,
    config_proxies: list | None = None,
    _reauth_attempted: bool = False,
) -> RequestResult | None {
    headers = dict(req_entry.headers);
    token = token_by_vu.get(vu_id) if token_by_vu is not None else None;
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

    # Phase 7a — rewrite the request with the ids this VU actually received
    # earlier in the iteration, before anything is sent. Endpoint matching uses
    # the raw path rather than the normalized one, because normalize_path()
    # rewrites id-looking segments to "{id}" and a correlation rule needs to name
    # the real endpoint.
    request_body = req_entry.body;
    correlation_applied: list[str] = [];
    if correlation_rules and correlation_table is not None {
        import from urllib.parse { urlparse as _corr_up }
        outcome = apply_correlations(
            correlation_rules,
            correlation_table,
            _corr_up(req_entry.url).path,
            request_url,
            request_body,
        );
        if outcome.missing {
            # The producing request never handed over the value this one needs —
            # it failed, or came back in a shape the rule does not match. Sending
            # the recording's stale id instead would surface as a puzzling 404
            # blamed on the application, so fail here with the real reason.
            return RequestResult(
                endpoint=endpoint,
                service=service_name,
                status=0,
                latency_ms=0.0,
                ttfb_ms=0.0,
                bytes_received=0,
                timestamp=_time.time(),
                vu_id=vu_id,
                error_type=f"CORRELATION_MISS: {', '.join(outcome.missing)}",
                expected_status=req_entry.expected_status,
                occurrence=req_entry.occurrence,
                total_occurrences=req_entry.total_occurrences,
                latency_valid=False,
                protocol=req_entry.protocol,
            );
        }
        request_url = outcome.url;
        request_body = outcome.body;
        correlation_applied = outcome.applied;
    }

    # Phase 7c — parameterization runs after correlation, so a substituted value
    # cannot disturb the recorded ids correlation matches on, and an explicit
    # --param wins if both ever target the same field.
    if (param_rules or param_ctx is not None) and param_ctx is not None {
        import from urllib.parse { urlparse as _param_up }
        param_outcome = apply_params(
            param_rules or [],
            param_ctx,
            _param_up(req_entry.url).path,
            request_url,
            request_body,
            headers,
        );
        request_url = param_outcome.url;
        request_body = param_outcome.body;
        headers = param_outcome.headers;
        correlation_applied = correlation_applied + param_outcome.applied;
    }

    t0 = loop.time();
    ts = _time.time();
    trace_ctx = SimpleNamespace();

    try {
        async with session.request(
            method=req_entry.method,
            url=request_url,
            headers=headers,
            data=request_body,
            allow_redirects=False,
            trace_request_ctx=trace_ctx,
            proxy=proxy_for(config_proxies, vu_id) if config_proxies else None,
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
            # Phase 7b — a 401 mid-run almost always means the token expired,
            # which is the soak-test failure CONSTRAINTS.md section 1 describes:
            # the run silently degrades into 100% auth failures partway through.
            # Re-authenticate this VU once and replay the request.
            #
            # Only when 401 is not what the recording expected: a HAR that
            # deliberately exercises an auth-failure path should keep seeing its
            # 401 rather than having the tool try to fix it.
            if (
                resp.status == 401
                and req_entry.expected_status != 401
                and auth_provider is not None
                and token_by_vu is not None
                and not _reauth_attempted
                and config.url
            ) {
                try {
                    fresh = await auth_provider.refresh_for(
                        vu_id, session, config.url, token
                    );
                } except Exception as exc {
                    return RequestResult(
                        endpoint=endpoint, service=service_name, status=401,
                        latency_ms=(loop.time() - t0) * 1000,
                        ttfb_ms=(loop.time() - t0) * 1000,
                        bytes_received=len(body), timestamp=ts, vu_id=vu_id,
                        error_type=f"AUTH_EXPIRED: re-authentication failed ({exc})",
                        expected_status=req_entry.expected_status,
                        occurrence=req_entry.occurrence,
                        total_occurrences=req_entry.total_occurrences,
                        protocol=req_entry.protocol,
                    );
                }
                token_by_vu[vu_id] = fresh;
                return await _send_request(
                    session=session, req_entry=req_entry, vu_id=vu_id,
                    config=config, loop=loop, token_by_vu=token_by_vu,
                    csrf_token_by_vu=csrf_token_by_vu, topology=topology,
                    auth_provider=auth_provider,
                    correlation_rules=correlation_rules,
                    correlation_table=correlation_table,
                    param_rules=param_rules,
                    param_ctx=param_ctx,
                    baseline_shapes=baseline_shapes,
                    config_proxies=config_proxies,
                    _reauth_attempted=True,
                );
            }
            if correlation_rules and correlation_table is not None {
                import from urllib.parse { urlparse as _cap_up }
                correlation_table.capture(
                    correlation_rules, _cap_up(req_entry.url).path, body, resp.headers
                );
            }
            latency_ms = (loop.time() - t0) * 1000;
            first_byte_time = getattr(trace_ctx, "first_byte_time", None);
            ttfb_ms = (first_byte_time - t0) * 1000 if first_byte_time is not None else latency_ms;
            # Phase 8a — fingerprint a failed non-JSON body so the post-run pass
            # can spot one canned page appearing across unrelated endpoints.
            # Only on failures: a successful response is not a deny page, and
            # hashing every body would cost real throughput.
            body_hash = (
                infra_fingerprint(body)
                if resp.status != req_entry.expected_status else None
            );
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
            auth_error = None;
            if (
                resp.status == 401
                and req_entry.expected_status != 401
                and _reauth_attempted
            ) {
                # Already re-authenticated once and still refused: the token is
                # fine, the credential or the authorization is not. Naming it
                # separately keeps it out of the generic 4xx bucket, where an
                # expiring-token soak failure is easy to mistake for the
                # application rejecting requests.
                auth_error = "AUTH_EXPIRED: still 401 after re-authentication";
            }
            assertion_error = None;
            if config.assert_json and resp.status == req_entry.expected_status {
                scoped = assertions_for(
                    parse_assert_json(config.assert_json),
                    _corr_endpoint_path(req_entry.url),
                );
                if scoped {
                    assertion_error = _check_json_assertions(body, scoped);
                }
            }

            # Phase 8b — a jac-scale walker can return 200 with the failure in
            # the body, so a run reports 0% errors while nothing works. Only
            # checked when the status already matched: a status mismatch is a
            # failure on its own and stacking a second reason on it is noise.
            body_error = None;
            if (
                config.body_check
                and resp.status == req_entry.expected_status
                and assertion_error is None
                and auth_error is None
            ) {
                shape = (
                    baseline_shapes.get(_corr_endpoint_path(req_entry.url))
                    if baseline_shapes else None
                );
                body_error = check_body(body, shape);
                if body_error is None and config.check_shape {
                    body_error = check_shape(body, shape);
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
                error_type=auth_error or assertion_error or body_error,
                body_hash=body_hash,
                expected_status=req_entry.expected_status,
                response_text=response_text,
                occurrence=req_entry.occurrence,
                total_occurrences=req_entry.total_occurrences,
                trace_id=extract_trace_id(resp.headers),
                protocol=req_entry.protocol,
                correlation_applied=correlation_applied,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
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
            protocol=req_entry.protocol,
        );
    }
}
