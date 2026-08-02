from __future__ import annotations

import hashlib
import hmac
import json
import re
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, cast
from urllib.parse import parse_qs, urlsplit

from .appium_manager import AppiumManagerError
from .live_control import LiveControlError
from .live_models import (
    LiveActionRequest,
    LiveSessionRequest,
    LiveSessionStatus,
    ObservationRequest,
)
from .json_safety import JSONSafetyError, loads_bounded, validate_json_complexity
from .live_store import LiveStoreError
from .live_tools import tool_catalog
from .models import JobRequest, JobStatus
from .service import AgentService
from .trace_service import TraceServiceError

UUID_PATTERN = re.compile(r"^[0-9a-fA-F-]{36}$")


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self, address: tuple[str, int], service: AgentService, token: str
    ) -> None:
        self.service = service
        self.token = token
        self.sse_slots = threading.BoundedSemaphore(service.config.live.max_sse_clients)
        super().__init__(address, AgentRequestHandler)


class AgentRequestHandler(BaseHTTPRequestHandler):
    server_version = "FaceSwapQAAgent/0.3"
    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(15)

    @property
    def agent_server(self) -> AgentHTTPServer:
        return cast(AgentHTTPServer, self.server)

    @property
    def service(self) -> AgentService:
        return self.agent_server.service

    def log_message(self, format: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        if not self._authorized():
            self._error(HTTPStatus.UNAUTHORIZED, "unauthorized", "valid bearer token required")
            return
        split = urlsplit(self.path)
        path = split.path.rstrip("/") or "/"
        query = parse_qs(split.query, keep_blank_values=True)
        try:
            if path == "/api/v1/health" and method == "GET":
                self._json(HTTPStatus.OK, self.service.health())
                return
            if path == "/api/v1/devices" and method == "GET":
                devices = [item.to_dict() for item in self.service.discovery.list_devices()]
                self._json(HTTPStatus.OK, {"devices": devices})
                return
            if path == "/api/v1/jobs" and method == "GET":
                self._list_jobs(query)
                return
            if path == "/api/v1/jobs" and method == "POST":
                self._create_job()
                return
            match = re.fullmatch(r"/api/v1/jobs/([^/]+)(?:/(cancel|log|artifacts))?", path)
            if match:
                job_id, action = match.groups()
                self._validate_uuid(job_id, "job")
                if action is None and method == "GET":
                    self._get_job(job_id)
                    return
                if action == "cancel" and method == "POST":
                    self._cancel_job(job_id)
                    return
                if action == "log" and method == "GET":
                    self._get_log(job_id, query)
                    return
                if action == "artifacts" and method == "GET":
                    self._get_artifacts(job_id)
                    return
                if action is None and method == "DELETE":
                    self._cancel_job(job_id)
                    return
            if path == "/api/v1/traces" and method == "GET":
                self._list_traces(query)
                return
            trace_match = re.fullmatch(
                r"/api/v1/traces/([^/]+)(?:/(events|analytics|recoveries|evidence(?:/download)?))?",
                path,
            )
            if trace_match:
                trace_id, action = trace_match.groups()
                self._validate_uuid(trace_id, "trace")
                if action is None and method == "GET":
                    self._get_trace(trace_id)
                    return
                if action == "events" and method == "GET":
                    self._get_trace_events(trace_id, query)
                    return
                if action == "analytics" and method == "GET":
                    self._json(
                        HTTPStatus.OK,
                        {"analytics": self.service.trace_analytics(trace_id)},
                    )
                    return
                if action == "recoveries" and method == "GET":
                    self._json(
                        HTTPStatus.OK,
                        {"recovery_episodes": self.service.trace_recoveries(trace_id)},
                    )
                    return
                if action == "evidence" and method == "GET":
                    document = self.service.trace_document(trace_id)
                    self._json(HTTPStatus.OK, {"evidence": document["evidence"]})
                    return
                if action == "evidence" and method == "POST":
                    self._json(
                        HTTPStatus.CREATED,
                        {"evidence": self.service.export_trace_evidence(trace_id)},
                    )
                    return
                if action == "evidence/download" and method == "GET":
                    self._download_trace_evidence(trace_id)
                    return
            if path == "/api/v1/recovery" and method == "GET":
                self._list_recoveries(query)
                return
            recovery_match = re.fullmatch(r"/api/v1/recovery/([^/]+)", path)
            if recovery_match and method == "GET":
                recovery_id = recovery_match.group(1)
                self._validate_uuid(recovery_id, "recovery")
                self._json(
                    HTTPStatus.OK,
                    {"recovery": self.service.recovery_document(recovery_id)},
                )
                return
            if path == "/api/v1/live/tools" and method == "GET":
                self._json(HTTPStatus.OK, tool_catalog(self.service.config))
                return
            if path == "/api/v1/live/appium" and method == "GET":
                self._json(HTTPStatus.OK, {"appium": self.service.appium_manager.state().to_dict()})
                return
            if path == "/api/v1/live/appium/start" and method == "POST":
                state = self.service.appium_manager.ensure_started()
                self._json(HTTPStatus.OK, {"appium": state.to_dict()})
                return
            if path == "/api/v1/live/sessions" and method == "GET":
                self._list_live_sessions(query)
                return
            if path == "/api/v1/live/sessions" and method == "POST":
                self._create_live_session()
                return
            live_match = re.fullmatch(
                r"/api/v1/live/sessions/([^/]+)(?:/(heartbeat|observations|actions|events|stream|artifacts))?",
                path,
            )
            if live_match:
                session_id, action = live_match.groups()
                self._validate_uuid(session_id, "live session")
                if action is None and method == "GET":
                    self._get_live_session(session_id)
                    return
                if action is None and method == "DELETE":
                    self._close_live_session(session_id)
                    return
                if action == "heartbeat" and method == "POST":
                    self._heartbeat_live_session(session_id)
                    return
                if action == "actions" and method == "POST":
                    self._live_action(session_id)
                    return
                if action == "observations" and method == "POST":
                    self._live_observation(session_id)
                    return
                if action == "events" and method == "GET":
                    self._get_live_events(session_id, query)
                    return
                if action == "stream" and method == "GET":
                    self._stream_live_events(session_id, query)
                    return
                if action == "artifacts" and method == "GET":
                    self._get_live_artifacts(session_id)
                    return
            raise RequestError(HTTPStatus.NOT_FOUND, "not_found", "route not found")
        except RequestError as error:
            self._error(error.status, error.code, str(error))
        except TraceServiceError as error:
            self._error(_trace_error_status(error.code), error.code, str(error))
        except (LiveStoreError, LiveControlError, AppiumManagerError) as error:
            status = _live_error_status(error.code)
            self._error(status, error.code, str(error))
        except ValueError as error:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_request", str(error))
        except Exception as error:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_error", str(error))

    def _authorized(self) -> bool:
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not authorization.startswith(prefix):
            return False
        supplied = authorization[len(prefix) :]
        return hmac.compare_digest(supplied, self.agent_server.token)

    def _lease_token(self) -> str:
        token = self.headers.get("X-Live-Lease", "").strip()
        if len(token) < 32 or len(token) > 256:
            raise RequestError(
                HTTPStatus.UNAUTHORIZED,
                "invalid_lease",
                "valid X-Live-Lease token required",
            )
        return token

    @staticmethod
    def _validate_uuid(value: str, label: str) -> None:
        if not UUID_PATTERN.fullmatch(value):
            raise RequestError(
                HTTPStatus.BAD_REQUEST, f"invalid_{label.replace(' ', '_')}_id", f"invalid {label} ID"
            )

    def _create_job(self) -> None:
        payload = self._read_json_body()
        request = JobRequest.from_dict(
            payload,
            default_timeout=self.service.config.limits.default_timeout_seconds,
            maximum_timeout=self.service.config.limits.maximum_timeout_seconds,
            maximum_retries=self.service.config.limits.maximum_retries,
        )
        idempotency_key = self.headers.get("Idempotency-Key")
        job, created = self.service.submit(request, idempotency_key)
        self._json(
            HTTPStatus.CREATED if created else HTTPStatus.OK,
            {"created": created, "job": self.service.job_document(job)},
        )

    def _list_jobs(self, query: dict[str, list[str]]) -> None:
        unknown = set(query) - {"status", "limit"}
        if unknown:
            raise RequestError(
                HTTPStatus.BAD_REQUEST, "invalid_query", f"unsupported query fields: {sorted(unknown)}"
            )
        status: JobStatus | None = None
        if "status" in query:
            try:
                status = JobStatus(_single(query, "status"))
            except ValueError as error:
                raise RequestError(
                    HTTPStatus.BAD_REQUEST, "invalid_status", "invalid job status"
                ) from error
        limit = _bounded_query_integer(query, "limit", 100, 1, 500)
        jobs = self.service.store.list_jobs(status, limit)
        self._json(
            HTTPStatus.OK,
            {"jobs": [self.service.job_document(job, include_events=False) for job in jobs]},
        )

    def _get_job(self, job_id: str) -> None:
        job = self.service.store.get_job(job_id)
        if job is None:
            raise RequestError(HTTPStatus.NOT_FOUND, "job_not_found", "job not found")
        self._json(HTTPStatus.OK, {"job": self.service.job_document(job)})

    def _cancel_job(self, job_id: str) -> None:
        job = self.service.cancel(job_id)
        if job is None:
            raise RequestError(HTTPStatus.NOT_FOUND, "job_not_found", "job not found")
        self._json(HTTPStatus.OK, {"job": self.service.job_document(job)})

    def _get_log(self, job_id: str, query: dict[str, list[str]]) -> None:
        unknown = set(query) - {"offset", "limit"}
        if unknown:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid_query", "invalid log query")
        job = self.service.store.get_job(job_id)
        if job is None:
            raise RequestError(HTTPStatus.NOT_FOUND, "job_not_found", "job not found")
        offset = _bounded_query_integer(query, "offset", 0, 0, 2**63 - 1)
        limit = _bounded_query_integer(query, "limit", 65536, 1, 1024 * 1024)
        self._json(HTTPStatus.OK, {"log": self.service.read_job_log(job, offset, limit)})

    def _get_artifacts(self, job_id: str) -> None:
        job = self.service.store.get_job(job_id)
        if job is None:
            raise RequestError(HTTPStatus.NOT_FOUND, "job_not_found", "job not found")
        artifacts = [item.to_dict() for item in self.service.store.get_artifacts(job_id)]
        self._json(HTTPStatus.OK, {"job_id": job_id, "artifacts": artifacts})

    def _list_traces(self, query: dict[str, list[str]]) -> None:
        unknown = set(query) - {"owner_type", "status", "since", "until", "offset", "limit"}
        if unknown:
            raise RequestError(
                HTTPStatus.BAD_REQUEST,
                "invalid_query",
                f"unsupported trace query fields: {sorted(unknown)}",
            )
        owner_type = _single(query, "owner_type") if "owner_type" in query else None
        status = _single(query, "status") if "status" in query else None
        since = _bounded_query_float(query, "since", None, 0.0, 2**53)
        until = _bounded_query_float(query, "until", None, 0.0, 2**53)
        offset = _bounded_query_integer(query, "offset", 0, 0, 10000)
        limit = _bounded_query_integer(query, "limit", 100, 1, 500)
        self._json(
            HTTPStatus.OK,
            self.service.list_traces(
                owner_type=owner_type,
                status=status,
                since=since,
                until=until,
                offset=offset,
                limit=limit,
            ),
        )

    def _get_trace(self, session_trace_id: str) -> None:
        self._json(
            HTTPStatus.OK,
            {"trace": self.service.trace_document(session_trace_id)},
        )

    def _get_trace_events(
        self,
        session_trace_id: str,
        query: dict[str, list[str]],
    ) -> None:
        unknown = set(query) - {"after", "limit"}
        if unknown:
            raise RequestError(
                HTTPStatus.BAD_REQUEST,
                "invalid_query",
                "invalid trace event query",
            )
        after = _bounded_query_integer(query, "after", 0, 0, 2**63 - 1)
        limit = _bounded_query_integer(query, "limit", 100, 1, 5000)
        self._json(
            HTTPStatus.OK,
            {
                "session_trace_id": session_trace_id.lower(),
                "events": self.service.trace_events(
                    session_trace_id,
                    after=after,
                    limit=limit,
                ),
            },
        )

    def _download_trace_evidence(self, session_trace_id: str) -> None:
        path, artifact = self.service.trace_evidence_bundle(session_trace_id)
        with path.open("rb") as handle:
            digest = hashlib.sha256()
            observed_size = 0
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                observed_size += len(chunk)
                digest.update(chunk)
            if observed_size != artifact.byte_size:
                raise TraceServiceError(
                    "artifact_size_mismatch",
                    "evidence bundle changed before download",
                )
            if digest.hexdigest() != artifact.sha256:
                raise TraceServiceError(
                    "artifact_hash_mismatch",
                    "evidence bundle changed before download",
                )
            handle.seek(0)
            self.send_response(int(HTTPStatus.OK))
            self.send_header("Content-Type", artifact.content_type or "application/gzip")
            self.send_header("Content-Length", str(artifact.byte_size))
            self.send_header("Content-Disposition", f'attachment; filename="{session_trace_id.lower()}-evidence.tar.gz"')
            self.send_header("X-Content-SHA256", artifact.sha256)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                self.wfile.write(chunk)

    def _list_recoveries(self, query: dict[str, list[str]]) -> None:
        unknown = set(query) - {
            "session_trace_id",
            "owner_type",
            "cause",
            "outcome",
            "offset",
            "limit",
        }
        if unknown:
            raise RequestError(
                HTTPStatus.BAD_REQUEST,
                "invalid_query",
                f"unsupported recovery query fields: {sorted(unknown)}",
            )
        session_trace_id = (
            _single(query, "session_trace_id")
            if "session_trace_id" in query
            else None
        )
        if session_trace_id is not None:
            self._validate_uuid(session_trace_id, "trace")
        self._json(
            HTTPStatus.OK,
            self.service.list_recoveries(
                session_trace_id=session_trace_id,
                owner_type=(
                    _single(query, "owner_type") if "owner_type" in query else None
                ),
                cause=_single(query, "cause") if "cause" in query else None,
                outcome=_single(query, "outcome") if "outcome" in query else None,
                offset=_bounded_query_integer(query, "offset", 0, 0, 10000),
                limit=_bounded_query_integer(query, "limit", 100, 1, 500),
            ),
        )

    def _create_live_session(self) -> None:
        payload = self._read_json_body()
        request = LiveSessionRequest.from_dict(
            payload,
            default_lease_seconds=self.service.config.live.default_lease_seconds,
            maximum_lease_seconds=self.service.config.live.maximum_lease_seconds,
        )
        session, lease_token, created = self.service.create_live_session(
            request, self.headers.get("Idempotency-Key")
        )
        response: dict[str, Any] = {
            "created": created,
            "session": self.service.live_control.session_document(session),
        }
        if lease_token is not None:
            response["lease_token"] = lease_token
        elif not created:
            response["lease_token_recoverable"] = False
        self._json(HTTPStatus.CREATED if created else HTTPStatus.OK, response)

    def _list_live_sessions(self, query: dict[str, list[str]]) -> None:
        unknown = set(query) - {"status", "limit"}
        if unknown:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid_query", "invalid session query")
        status: LiveSessionStatus | None = None
        if "status" in query:
            try:
                status = LiveSessionStatus(_single(query, "status"))
            except ValueError as error:
                raise RequestError(
                    HTTPStatus.BAD_REQUEST, "invalid_status", "invalid live session status"
                ) from error
        limit = _bounded_query_integer(query, "limit", 100, 1, 500)
        sessions = self.service.live_store.list_sessions(status, limit)
        self._json(
            HTTPStatus.OK,
            {
                "sessions": [
                    self.service.live_control.session_document(session) for session in sessions
                ]
            },
        )

    def _get_live_session(self, session_id: str) -> None:
        session = self.service.live_store.get_session(session_id)
        if session is None:
            raise RequestError(
                HTTPStatus.NOT_FOUND, "session_not_found", "live session not found"
            )
        self._json(
            HTTPStatus.OK,
            {"session": self.service.live_control.session_document(session)},
        )

    def _heartbeat_live_session(self, session_id: str) -> None:
        payload = self._read_json_body()
        unknown = set(payload) - {"lease_seconds"}
        if unknown or "lease_seconds" not in payload:
            raise ValueError("heartbeat requires only lease_seconds")
        seconds = payload["lease_seconds"]
        if isinstance(seconds, bool) or not isinstance(seconds, int):
            raise ValueError("lease_seconds must be an integer")
        session = self.service.live_control.heartbeat(
            session_id, self._lease_token(), seconds
        )
        self._json(HTTPStatus.OK, {"session": self.service.live_control.session_document(session)})

    def _close_live_session(self, session_id: str) -> None:
        session = self.service.close_live_session(session_id, self._lease_token())
        self._json(HTTPStatus.OK, {"session": self.service.live_control.session_document(session)})

    def _live_action(self, session_id: str) -> None:
        action = LiveActionRequest.from_dict(
            self._read_json_body(),
            maximum_text_length=self.service.config.live.maximum_action_text_length,
        )
        result = self.service.live_control.execute_action(
            session_id, self._lease_token(), action
        )
        self._json(HTTPStatus.OK, {"result": result.to_dict()})

    def _live_observation(self, session_id: str) -> None:
        request = ObservationRequest.from_dict(self._read_json_body())
        result = self.service.live_control.capture_observation(
            session_id, self._lease_token(), request
        )
        self._json(HTTPStatus.OK, {"observation": result.to_dict()})

    def _get_live_events(
        self, session_id: str, query: dict[str, list[str]]
    ) -> None:
        unknown = set(query) - {"after", "limit"}
        if unknown:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid_query", "invalid event query")
        if self.service.live_store.get_session(session_id) is None:
            raise RequestError(
                HTTPStatus.NOT_FOUND, "session_not_found", "live session not found"
            )
        after = _bounded_query_integer(query, "after", 0, 0, 2**63 - 1)
        limit = _bounded_query_integer(query, "limit", 100, 1, 1000)
        events = self.service.live_store.get_events(session_id, after=after, limit=limit)
        self._json(HTTPStatus.OK, {"events": [event.to_dict() for event in events]})

    def _get_live_artifacts(self, session_id: str) -> None:
        if self.service.live_store.get_session(session_id) is None:
            raise RequestError(
                HTTPStatus.NOT_FOUND, "session_not_found", "live session not found"
            )
        artifacts = [item.to_dict() for item in self.service.live_store.get_artifacts(session_id)]
        self._json(HTTPStatus.OK, {"session_id": session_id, "artifacts": artifacts})

    def _stream_live_events(
        self, session_id: str, query: dict[str, list[str]]
    ) -> None:
        unknown = set(query) - {"after"}
        if unknown:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid_query", "invalid stream query")
        token = self._lease_token()
        self.service.live_store.authorize_lease(session_id, token, require_active=False)
        if not self.agent_server.sse_slots.acquire(blocking=False):
            raise RequestError(
                HTTPStatus.TOO_MANY_REQUESTS,
                "stream_limit",
                "maximum live event streams reached",
            )
        after = _bounded_query_integer(query, "after", 0, 0, 2**63 - 1)
        last_event = self.headers.get("Last-Event-ID")
        if last_event:
            try:
                last_event_id = int(last_event)
                if last_event_id < 0 or last_event_id > 2**63 - 1:
                    raise ValueError("out of range")
                after = max(after, last_event_id)
            except ValueError as error:
                self.agent_server.sse_slots.release()
                raise RequestError(
                    HTTPStatus.BAD_REQUEST, "invalid_last_event_id", "Last-Event-ID must be an integer"
                ) from error
        try:
            self.send_response(int(HTTPStatus.OK))
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            retry_ms = self.service.config.live.sse_heartbeat_seconds * 1000
            self.wfile.write(f"retry: {retry_ms}\n\n".encode("ascii"))
            self.wfile.flush()
            self.connection.settimeout(None)
            heartbeat_at = time.monotonic()
            while True:
                events = self.service.live_store.get_events(
                    session_id, after=after, limit=100
                )
                for event in events:
                    payload = json.dumps(
                        event.to_dict(), sort_keys=True, separators=(",", ":")
                    )
                    message = (
                        f"id: {event.id}\n"
                        f"event: {event.category}.{event.name}\n"
                        f"data: {payload}\n\n"
                    ).encode("utf-8")
                    self.wfile.write(message)
                    after = event.id
                    heartbeat_at = time.monotonic()
                if events:
                    self.wfile.flush()
                session = self.service.live_store.get_session(session_id)
                if session is None or session.status.terminal:
                    terminal = json.dumps(
                        {
                            "session_id": session_id,
                            "status": session.status.value if session else "deleted",
                        },
                        separators=(",", ":"),
                    )
                    self.wfile.write(f"event: stream.closed\ndata: {terminal}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    break
                if time.monotonic() - heartbeat_at >= self.service.config.live.sse_heartbeat_seconds:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    heartbeat_at = time.monotonic()
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            pass
        finally:
            self.close_connection = True
            self.agent_server.sse_slots.release()

    def _read_json_body(self) -> dict[str, Any]:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise RequestError(
                HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                "unsupported_media_type",
                "Content-Type must be application/json",
            )
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise RequestError(HTTPStatus.LENGTH_REQUIRED, "length_required", "Content-Length required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise RequestError(
                HTTPStatus.BAD_REQUEST, "invalid_content_length", "invalid Content-Length"
            ) from error
        if length < 1 or length > self.service.config.limits.max_request_bytes:
            raise RequestError(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                "request_too_large",
                "request body exceeds configured limit",
            )
        try:
            body = self.rfile.read(length)
        except (TimeoutError, OSError) as error:
            raise RequestError(
                HTTPStatus.REQUEST_TIMEOUT,
                "request_timeout",
                "request body was not received before the deadline",
            ) from error
        if len(body) != length:
            raise RequestError(
                HTTPStatus.BAD_REQUEST,
                "incomplete_body",
                "request body ended before Content-Length bytes were received",
            )
        try:
            value = loads_bounded(
                body,
                maximum_bytes=self.service.config.limits.max_request_bytes,
            )
        except JSONSafetyError as error:
            code = error.code if error.code in {"json_too_deep", "json_too_complex"} else "invalid_json"
            raise RequestError(HTTPStatus.BAD_REQUEST, code, str(error)) from error
        if not isinstance(value, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid_json", "JSON body must be an object")
        _validate_json_complexity(value)
        return value

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})


class RequestError(RuntimeError):
    def __init__(self, status: HTTPStatus, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def create_http_server(service: AgentService, token: str) -> AgentHTTPServer:
    return AgentHTTPServer((service.config.api.host, service.config.api.port), service, token)


def _single(query: dict[str, list[str]], name: str) -> str:
    values = query.get(name, [])
    if len(values) != 1:
        raise ValueError(f"{name} must be provided once")
    return values[0]


def _bounded_query_integer(
    query: dict[str, list[str]], name: str, default: int, minimum: int, maximum: int
) -> int:
    if name not in query:
        return default
    try:
        value = int(_single(query, name))
    except ValueError as error:
        raise RequestError(
            HTTPStatus.BAD_REQUEST, "invalid_query", f"{name} must be an integer"
        ) from error
    if value < minimum or value > maximum:
        raise RequestError(
            HTTPStatus.BAD_REQUEST,
            "invalid_query",
            f"{name} must be between {minimum} and {maximum}",
        )
    return value


def _bounded_query_float(
    query: dict[str, list[str]],
    name: str,
    default: float | None,
    minimum: float,
    maximum: float,
) -> float | None:
    if name not in query:
        return default
    try:
        value = float(_single(query, name))
    except ValueError as error:
        raise RequestError(
            HTTPStatus.BAD_REQUEST, "invalid_query", f"{name} must be a number"
        ) from error
    if value != value or value in {float("inf"), float("-inf")}:
        raise RequestError(
            HTTPStatus.BAD_REQUEST, "invalid_query", f"{name} must be finite"
        )
    if value < minimum or value > maximum:
        raise RequestError(
            HTTPStatus.BAD_REQUEST,
            "invalid_query",
            f"{name} must be between {minimum} and {maximum}",
        )
    return value


def _validate_json_complexity(
    value: Any, *, maximum_depth: int = 32, maximum_nodes: int = 10000
) -> None:
    try:
        validate_json_complexity(
            value,
            maximum_depth=maximum_depth,
            maximum_nodes=maximum_nodes,
        )
    except JSONSafetyError as error:
        raise RequestError(HTTPStatus.BAD_REQUEST, error.code, str(error)) from error


def _trace_error_status(code: str) -> HTTPStatus:
    if code in {
        "trace_not_found",
        "owner_not_found",
        "recovery_not_found",
        "evidence_not_found",
        "artifact_missing",
    }:
        return HTTPStatus.NOT_FOUND
    if code in {
        "trace_owner_conflict",
        "trace_root_mismatch",
        "recovery_terminal",
        "recovery_conflict",
    }:
        return HTTPStatus.CONFLICT
    if code.startswith("artifact_") or code.startswith("manifest_"):
        return HTTPStatus.UNPROCESSABLE_ENTITY
    if code in {"evidence_export_failed", "recovery_store_failed"}:
        return HTTPStatus.INTERNAL_SERVER_ERROR
    return HTTPStatus.BAD_REQUEST


def _live_error_status(code: str) -> HTTPStatus:
    if code in {"session_not_found"}:
        return HTTPStatus.NOT_FOUND
    if code in {"invalid_lease", "lease_expired"}:
        return HTTPStatus.UNAUTHORIZED
    if code in {
        "device_busy",
        "invalid_transition",
        "session_not_active",
        "session_terminal",
        "port_exhausted",
    }:
        return HTTPStatus.CONFLICT
    if code in {
        "appium_missing",
        "xcuitest_driver_missing",
        "appium_plugin_missing",
        "appium_version_mismatch",
        "appium_plugin_version_mismatch",
        "xcuitest_driver_version_mismatch",
        "remotexpc_missing",
        "remotexpc_version_mismatch",
        "appium_port_in_use",
        "bidi_url_missing",
        "bidi_handshake_failed",
        "bidi_disconnected",
        "device_unavailable",
        "simulator_unavailable",
    }:
        return HTTPStatus.SERVICE_UNAVAILABLE
    return HTTPStatus.BAD_GATEWAY
