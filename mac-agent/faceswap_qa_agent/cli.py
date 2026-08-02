from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Sequence

from .config import AgentConfig
from .json_safety import JSONSafetyError, loads_bounded
from .service import AgentService


def load_token(config: AgentConfig) -> str:
    token = config.api.token_file.read_text(encoding="utf-8").strip()
    if len(token) < 32:
        raise RuntimeError("API token file is missing or invalid")
    return token


def base_url(config: AgentConfig) -> str:
    host = f"[{config.api.host}]" if ":" in config.api.host else config.api.host
    return f"http://{host}:{config.api.port}/api/v1"


def api_request(
    config: AgentConfig,
    method: str,
    path: str,
    *,
    payload: dict[str, Any] | None = None,
    idempotency_key: str | None = None,
    lease_token: str | None = None,
    timeout: float = 120,
) -> dict[str, Any]:
    data = None
    headers = {"Authorization": f"Bearer {load_token(config)}"}
    if payload is not None:
        data = json.dumps(payload, sort_keys=True).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    if lease_token:
        headers["X-Live-Lease"] = lease_token
    request = urllib.request.Request(
        base_url(config) + path,
        data=data,
        headers=headers,
        method=method,
    )
    response_limit = max(
        1024 * 1024,
        min(config.live.maximum_observation_bytes * 2, 64 * 1024 * 1024),
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(response_limit + 1)
            if len(raw) > response_limit:
                raise RuntimeError("API response exceeded the configured byte limit")
            value = loads_bounded(raw, maximum_bytes=response_limit)
            if not isinstance(value, dict):
                raise RuntimeError("API response must be a JSON object")
            return value
    except urllib.error.HTTPError as error:
        raw = error.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            detail = {"error": {"code": "http_error", "message": "error response too large"}}
        else:
            try:
                detail = loads_bounded(raw, maximum_bytes=1024 * 1024)
            except JSONSafetyError:
                detail = {
                    "error": {
                        "code": "http_error",
                        "message": raw.decode("utf-8", errors="replace"),
                    }
                }
        raise RuntimeError(json.dumps(detail, sort_keys=True)) from error


def _print(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False))


def command_serve(args: argparse.Namespace) -> int:
    config = AgentConfig.load(args.config)
    service = AgentService(config)
    service.run_forever()
    return 0


def command_health(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "GET", "/health"))
    return 0


def command_devices(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "GET", "/devices"))
    return 0


def command_submit(args: argparse.Namespace) -> int:
    labels: dict[str, str] = {}
    for value in args.label:
        if "=" not in value:
            raise ValueError(f"label must use key=value syntax: {value}")
        key, item = value.split("=", 1)
        labels[key] = item
    payload: dict[str, Any] = {
        "target": {"kind": args.target, "udid": args.udid, "name": args.name, "os": args.os},
        "only_testing": args.only_testing,
        "skip_testing": args.skip_testing,
        "max_retries": args.max_retries,
        "labels": labels,
    }
    if args.run_id:
        payload["run_id"] = args.run_id
    if args.timeout_seconds:
        payload["timeout_seconds"] = args.timeout_seconds
    result = api_request(
        AgentConfig.load(args.config),
        "POST",
        "/jobs",
        payload=payload,
        idempotency_key=args.idempotency_key,
    )
    _print(result)
    return 0


def command_jobs(args: argparse.Namespace) -> int:
    parameters = {"limit": str(args.limit)}
    if args.status:
        parameters["status"] = args.status
    path = "/jobs?" + urllib.parse.urlencode(parameters)
    _print(api_request(AgentConfig.load(args.config), "GET", path))
    return 0


def command_status(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "GET", f"/jobs/{args.job_id}"))
    return 0


def command_cancel(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "POST", f"/jobs/{args.job_id}/cancel"))
    return 0


def command_tail(args: argparse.Namespace) -> int:
    config = AgentConfig.load(args.config)
    offset = args.offset
    while True:
        query = urllib.parse.urlencode({"offset": offset, "limit": args.limit})
        result = api_request(config, "GET", f"/jobs/{args.job_id}/log?{query}")
        log = result["log"]
        sys.stdout.write(log["data"])
        sys.stdout.flush()
        offset = int(log["next_offset"])
        if not args.follow:
            return 0
        status = api_request(config, "GET", f"/jobs/{args.job_id}")["job"]["status"]
        if log["eof"] and status in {"succeeded", "failed", "cancelled"}:
            return 0
        time.sleep(args.interval)


def command_trace_index(args: argparse.Namespace) -> int:
    parameters: dict[str, str] = {
        "offset": str(args.offset),
        "limit": str(args.limit),
    }
    for name in ("owner_type", "status", "since", "until"):
        value = getattr(args, name)
        if value is not None:
            parameters[name] = str(value)
    query = urllib.parse.urlencode(parameters)
    _print(api_request(AgentConfig.load(args.config), "GET", f"/traces?{query}"))
    return 0


def command_trace(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/traces/{args.session_trace_id}",
        )
    )
    return 0


def command_trace_events(args: argparse.Namespace) -> int:
    query = urllib.parse.urlencode({"after": args.after, "limit": args.limit})
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/traces/{args.session_trace_id}/events?{query}",
        )
    )
    return 0


def command_trace_analytics(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/traces/{args.session_trace_id}/analytics",
        )
    )
    return 0


def command_trace_recoveries(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/traces/{args.session_trace_id}/recoveries",
        )
    )
    return 0


def command_trace_export(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "POST",
            f"/traces/{args.session_trace_id}/evidence",
            timeout=args.timeout,
        )
    )
    return 0


def command_trace_download(args: argparse.Namespace) -> int:
    config = AgentConfig.load(args.config)
    destination = Path(args.output).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise RuntimeError("trace download destination must not be a symlink")
    request = urllib.request.Request(
        base_url(config) + f"/traces/{args.session_trace_id}/evidence/download",
        headers={"Authorization": f"Bearer {load_token(config)}"},
        method="GET",
    )
    temporary_path: Path | None = None
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            raw_length = response.headers.get("Content-Length")
            expected_hash = response.headers.get("X-Content-SHA256", "").lower()
            if raw_length is None or not raw_length.isdigit():
                raise RuntimeError("evidence download omitted a valid Content-Length")
            expected_length = int(raw_length)
            if expected_length < 1 or expected_length > 2 * 1024 * 1024 * 1024:
                raise RuntimeError("evidence download length is outside the safe bound")
            if len(expected_hash) != 64 or any(
                character not in "0123456789abcdef" for character in expected_hash
            ):
                raise RuntimeError("evidence download omitted a valid SHA-256")
            descriptor, raw_path = tempfile.mkstemp(
                prefix=f".{destination.name}.",
                suffix=".part",
                dir=str(destination.parent),
            )
            temporary_path = Path(raw_path)
            try:
                os.fchmod(descriptor, 0o600)
                descriptor_stat = os.fstat(descriptor)
                if not stat.S_ISREG(descriptor_stat.st_mode):
                    raise RuntimeError("evidence temporary descriptor is not a regular file")
                if descriptor_stat.st_uid != os.geteuid():
                    raise RuntimeError("evidence temporary descriptor has the wrong owner")
                if stat.S_IMODE(descriptor_stat.st_mode) & 0o077:
                    raise RuntimeError("evidence temporary descriptor permissions are not private")
            except BaseException:
                os.close(descriptor)
                raise
            digest = hashlib.sha256()
            observed_length = 0
            with os.fdopen(descriptor, "wb") as handle:
                while observed_length < expected_length:
                    chunk = response.read(min(1024 * 1024, expected_length - observed_length))
                    if not chunk:
                        break
                    observed_length += len(chunk)
                    digest.update(chunk)
                    handle.write(chunk)
                if response.read(1):
                    raise RuntimeError("evidence download exceeded Content-Length")
                handle.flush()
                os.fsync(handle.fileno())
            if observed_length != expected_length:
                raise RuntimeError("evidence download ended before Content-Length bytes")
            if digest.hexdigest() != expected_hash:
                raise RuntimeError("evidence download SHA-256 mismatch")
            os.replace(temporary_path, destination)
            temporary_path = None
            destination.chmod(0o600)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    _print(
        {
            "session_trace_id": args.session_trace_id.lower(),
            "path": str(destination),
            "byte_size": destination.stat().st_size,
            "sha256": expected_hash,
        }
    )
    return 0


def command_recovery_list(args: argparse.Namespace) -> int:
    parameters: dict[str, str] = {
        "offset": str(args.offset),
        "limit": str(args.limit),
    }
    for name in ("session_trace_id", "owner_type", "cause", "outcome"):
        value = getattr(args, name)
        if value is not None:
            parameters[name] = str(value)
    query = urllib.parse.urlencode(parameters)
    _print(api_request(AgentConfig.load(args.config), "GET", f"/recovery?{query}"))
    return 0


def command_recovery_show(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/recovery/{args.recovery_id}",
        )
    )
    return 0


def _live_lease(args: argparse.Namespace) -> str:
    if getattr(args, "lease_token_file", None):
        token = Path(args.lease_token_file).expanduser().read_text(encoding="utf-8").strip()
    else:
        token = os.environ.get("FACESWAP_LIVE_LEASE", "").strip()
    if len(token) < 32:
        raise RuntimeError(
            "live lease token required via --lease-token-file or FACESWAP_LIVE_LEASE"
        )
    return token


def command_appium_status(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "GET", "/live/appium"))
    return 0


def command_appium_start(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "POST", "/live/appium/start"))
    return 0


def command_live_tools(args: argparse.Namespace) -> int:
    _print(api_request(AgentConfig.load(args.config), "GET", "/live/tools"))
    return 0


def command_live_open(args: argparse.Namespace) -> int:
    payload: dict[str, Any] = {
        "target": {"kind": args.target, "udid": args.udid, "name": args.name, "os": args.os},
        "lease_seconds": args.lease_seconds,
        "no_reset": args.no_reset,
        "auto_launch": args.auto_launch,
    }
    if args.language:
        payload["language"] = args.language
    if args.locale:
        payload["locale"] = args.locale
    _print(
        api_request(
            AgentConfig.load(args.config),
            "POST",
            "/live/sessions",
            payload=payload,
            idempotency_key=args.idempotency_key,
            timeout=args.timeout,
        )
    )
    return 0


def command_live_sessions(args: argparse.Namespace) -> int:
    parameters = {"limit": str(args.limit)}
    if args.status:
        parameters["status"] = args.status
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            "/live/sessions?" + urllib.parse.urlencode(parameters),
        )
    )
    return 0


def command_live_status(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config), "GET", f"/live/sessions/{args.session_id}"
        )
    )
    return 0


def command_live_heartbeat(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "POST",
            f"/live/sessions/{args.session_id}/heartbeat",
            payload={"lease_seconds": args.lease_seconds},
            lease_token=_live_lease(args),
        )
    )
    return 0


def command_live_action(args: argparse.Namespace) -> int:
    config = AgentConfig.load(args.config)
    try:
        parameters = loads_bounded(
            args.parameters,
            maximum_bytes=max(65536, config.live.maximum_action_text_length * 4),
        )
    except JSONSafetyError as error:
        raise ValueError(f"--parameters JSON was rejected: {error}") from error
    if not isinstance(parameters, dict):
        raise ValueError("--parameters must be a JSON object")
    _print(
        api_request(
            config,
            "POST",
            f"/live/sessions/{args.session_id}/actions",
            payload={"kind": args.kind, "parameters": parameters},
            lease_token=_live_lease(args),
            timeout=args.timeout,
        )
    )
    return 0


def command_live_observe(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "POST",
            f"/live/sessions/{args.session_id}/observations",
            payload={"kind": args.kind, "persist": args.persist},
            lease_token=_live_lease(args),
            timeout=args.timeout,
        )
    )
    return 0


def command_live_events(args: argparse.Namespace) -> int:
    query = urllib.parse.urlencode({"after": args.after, "limit": args.limit})
    _print(
        api_request(
            AgentConfig.load(args.config),
            "GET",
            f"/live/sessions/{args.session_id}/events?{query}",
        )
    )
    return 0


def command_live_stream(args: argparse.Namespace) -> int:
    config = AgentConfig.load(args.config)
    token = load_token(config)
    lease = _live_lease(args)
    after = max(0, int(args.after))
    if args.max_reconnects < -1:
        raise ValueError("max_reconnects must be -1 or greater")
    if not 0 <= args.reconnect_delay <= 60:
        raise ValueError("reconnect_delay must be between 0 and 60 seconds")
    reconnects = 0
    while True:
        query = urllib.parse.urlencode({"after": after})
        headers = {
            "Authorization": f"Bearer {token}",
            "X-Live-Lease": lease,
            "Accept": "text/event-stream",
        }
        if after:
            headers["Last-Event-ID"] = str(after)
        request = urllib.request.Request(
            base_url(config) + f"/live/sessions/{args.session_id}/stream?{query}",
            headers=headers,
            method="GET",
        )
        terminal = False
        try:
            with urllib.request.urlopen(request, timeout=None) as response:
                current_event: str | None = None
                while True:
                    raw_line = response.readline()
                    if not raw_line:
                        break
                    line = raw_line.decode("utf-8", errors="replace")
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    stripped = line.rstrip("\r\n")
                    if stripped.startswith("id:"):
                        try:
                            event_id = int(stripped[3:].strip())
                            if 0 <= event_id <= 2**63 - 1:
                                after = max(after, event_id)
                        except ValueError:
                            pass
                    elif stripped.startswith("event:"):
                        current_event = stripped[6:].strip()
                    elif not stripped:
                        if current_event == "stream.closed":
                            terminal = True
                            break
                        current_event = None
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            print(f"live stream disconnected: {error}", file=sys.stderr)
        if terminal:
            return 0
        reconnects += 1
        if args.max_reconnects >= 0 and reconnects > args.max_reconnects:
            raise RuntimeError("live stream reconnect limit exceeded")
        time.sleep(args.reconnect_delay)


def command_live_close(args: argparse.Namespace) -> int:
    _print(
        api_request(
            AgentConfig.load(args.config),
            "DELETE",
            f"/live/sessions/{args.session_id}",
            lease_token=_live_lease(args),
        )
    )
    return 0


def _add_live_lease_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--lease-token-file",
        help="path to a mode-0600 live lease token file; otherwise uses FACESWAP_LIVE_LEASE",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="faceswap-qa-agent")
    parser.add_argument(
        "--config",
        default=str(Path.home() / ".faceswap-qa-agent" / "config.json"),
        help="path to agent configuration JSON",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    serve = subparsers.add_parser("serve", help="run the persistent service")
    serve.set_defaults(handler=command_serve)

    for name, handler in (("health", command_health), ("devices", command_devices)):
        command = subparsers.add_parser(name)
        command.set_defaults(handler=handler)

    submit = subparsers.add_parser("submit")
    submit.add_argument("--target", choices=("simulator", "cable"), required=True)
    submit.add_argument("--udid")
    submit.add_argument("--name")
    submit.add_argument("--os", default="latest")
    submit.add_argument("--run-id")
    submit.add_argument("--only-testing", action="append", default=[])
    submit.add_argument("--skip-testing", action="append", default=[])
    submit.add_argument("--timeout-seconds", type=int)
    submit.add_argument("--max-retries", type=int, default=0)
    submit.add_argument("--label", action="append", default=[])
    submit.add_argument("--idempotency-key")
    submit.set_defaults(handler=command_submit)

    jobs = subparsers.add_parser("jobs")
    jobs.add_argument("--status", choices=("queued", "running", "succeeded", "failed", "cancelled"))
    jobs.add_argument("--limit", type=int, default=100)
    jobs.set_defaults(handler=command_jobs)

    status = subparsers.add_parser("status")
    status.add_argument("job_id")
    status.set_defaults(handler=command_status)

    cancel = subparsers.add_parser("cancel")
    cancel.add_argument("job_id")
    cancel.set_defaults(handler=command_cancel)

    tail = subparsers.add_parser("tail")
    tail.add_argument("job_id")
    tail.add_argument("--offset", type=int, default=0)
    tail.add_argument("--limit", type=int, default=65536)
    tail.add_argument("--follow", action="store_true")
    tail.add_argument("--interval", type=float, default=1.0)
    tail.set_defaults(handler=command_tail)

    trace_index = subparsers.add_parser("trace-index")
    trace_index.add_argument("--owner-type", choices=("job", "live_session"))
    trace_index.add_argument("--status")
    trace_index.add_argument("--since", type=float)
    trace_index.add_argument("--until", type=float)
    trace_index.add_argument("--offset", type=int, default=0)
    trace_index.add_argument("--limit", type=int, default=100)
    trace_index.set_defaults(handler=command_trace_index)

    trace = subparsers.add_parser("trace")
    trace.add_argument("session_trace_id")
    trace.set_defaults(handler=command_trace)

    trace_events = subparsers.add_parser("trace-events")
    trace_events.add_argument("session_trace_id")
    trace_events.add_argument("--after", type=int, default=0)
    trace_events.add_argument("--limit", type=int, default=100)
    trace_events.set_defaults(handler=command_trace_events)

    trace_analytics = subparsers.add_parser("trace-analytics")
    trace_analytics.add_argument("session_trace_id")
    trace_analytics.set_defaults(handler=command_trace_analytics)

    trace_recoveries = subparsers.add_parser("trace-recoveries")
    trace_recoveries.add_argument("session_trace_id")
    trace_recoveries.set_defaults(handler=command_trace_recoveries)

    trace_export = subparsers.add_parser("trace-export")
    trace_export.add_argument("session_trace_id")
    trace_export.add_argument("--timeout", type=float, default=600)
    trace_export.set_defaults(handler=command_trace_export)

    trace_download = subparsers.add_parser("trace-download")
    trace_download.add_argument("session_trace_id")
    trace_download.add_argument("--output", required=True)
    trace_download.add_argument("--timeout", type=float, default=600)
    trace_download.set_defaults(handler=command_trace_download)

    recovery_list = subparsers.add_parser("recovery-list")
    recovery_list.add_argument("--session-trace-id")
    recovery_list.add_argument("--owner-type", choices=("job", "live_session"))
    recovery_list.add_argument("--cause")
    recovery_list.add_argument("--outcome")
    recovery_list.add_argument("--offset", type=int, default=0)
    recovery_list.add_argument("--limit", type=int, default=100)
    recovery_list.set_defaults(handler=command_recovery_list)

    recovery_show = subparsers.add_parser("recovery-show")
    recovery_show.add_argument("recovery_id")
    recovery_show.set_defaults(handler=command_recovery_show)

    appium_status = subparsers.add_parser("appium-status")
    appium_status.set_defaults(handler=command_appium_status)
    appium_start = subparsers.add_parser("appium-start")
    appium_start.set_defaults(handler=command_appium_start)
    live_tools = subparsers.add_parser("live-tools")
    live_tools.set_defaults(handler=command_live_tools)

    live_open = subparsers.add_parser("live-open")
    live_open.add_argument("--target", choices=("simulator", "cable"), required=True)
    live_open.add_argument("--udid")
    live_open.add_argument("--name")
    live_open.add_argument("--os", default="latest")
    live_open.add_argument("--lease-seconds", type=int, default=600)
    live_open.add_argument("--no-reset", action=argparse.BooleanOptionalAction, default=True)
    live_open.add_argument("--auto-launch", action=argparse.BooleanOptionalAction, default=True)
    live_open.add_argument("--language")
    live_open.add_argument("--locale")
    live_open.add_argument("--idempotency-key")
    live_open.add_argument("--timeout", type=float, default=600)
    live_open.set_defaults(handler=command_live_open)

    live_sessions = subparsers.add_parser("live-sessions")
    live_sessions.add_argument(
        "--status",
        choices=("pending", "starting", "active", "stopping", "closed", "failed", "expired", "cancelled"),
    )
    live_sessions.add_argument("--limit", type=int, default=100)
    live_sessions.set_defaults(handler=command_live_sessions)

    live_status = subparsers.add_parser("live-status")
    live_status.add_argument("session_id")
    live_status.set_defaults(handler=command_live_status)

    live_heartbeat = subparsers.add_parser("live-heartbeat")
    live_heartbeat.add_argument("session_id")
    live_heartbeat.add_argument("--lease-seconds", type=int, default=600)
    _add_live_lease_argument(live_heartbeat)
    live_heartbeat.set_defaults(handler=command_live_heartbeat)

    live_action = subparsers.add_parser("live-action")
    live_action.add_argument("session_id")
    live_action.add_argument("--kind", required=True)
    live_action.add_argument("--parameters", default="{}")
    live_action.add_argument("--timeout", type=float, default=240)
    _add_live_lease_argument(live_action)
    live_action.set_defaults(handler=command_live_action)

    live_observe = subparsers.add_parser("live-observe")
    live_observe.add_argument("session_id")
    live_observe.add_argument(
        "--kind",
        choices=("screenshot", "source_xml", "source_json", "contexts", "orientation", "window_rect", "device_info", "battery_info", "combined"),
        default="combined",
    )
    live_observe.add_argument("--persist", action=argparse.BooleanOptionalAction, default=True)
    live_observe.add_argument("--timeout", type=float, default=240)
    _add_live_lease_argument(live_observe)
    live_observe.set_defaults(handler=command_live_observe)

    live_events = subparsers.add_parser("live-events")
    live_events.add_argument("session_id")
    live_events.add_argument("--after", type=int, default=0)
    live_events.add_argument("--limit", type=int, default=100)
    live_events.set_defaults(handler=command_live_events)

    live_stream = subparsers.add_parser("live-stream")
    live_stream.add_argument("session_id")
    live_stream.add_argument("--after", type=int, default=0)
    live_stream.add_argument(
        "--max-reconnects",
        type=int,
        default=-1,
        help="maximum reconnects after EOF or transport failure; -1 retries until terminal",
    )
    live_stream.add_argument("--reconnect-delay", type=float, default=1.0)
    _add_live_lease_argument(live_stream)
    live_stream.set_defaults(handler=command_live_stream)

    live_close = subparsers.add_parser("live-close")
    live_close.add_argument("session_id")
    _add_live_lease_argument(live_close)
    live_close.set_defaults(handler=command_live_close)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
