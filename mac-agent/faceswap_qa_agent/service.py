from __future__ import annotations

import os
import secrets
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from .appium_manager import AppiumManager
from .config import AgentConfig
from .discovery import DeviceDiscovery
from .live_control import LiveControlManager
from .live_models import LiveSession, LiveSessionRequest
from .live_store import LiveStore
from .models import Job, JobRequest, JobStatus
from .runner import XcodeRunner
from .store import JobStore
from .trace_service import TraceService


class AgentService:
    def __init__(
        self,
        config: AgentConfig,
        *,
        store: JobStore | None = None,
        discovery: DeviceDiscovery | None = None,
        runner: XcodeRunner | None = None,
        live_store: LiveStore | None = None,
        appium_manager: AppiumManager | None = None,
        live_control: LiveControlManager | None = None,
        trace_service: TraceService | None = None,
    ) -> None:
        self.config = config
        self.config.ensure_directories()
        self.store = store or JobStore(config.paths.database)
        self.discovery = discovery or DeviceDiscovery(environment=self._command_environment())
        self.runner = runner or XcodeRunner(config, self.store, self.discovery)
        self.live_store = live_store or LiveStore(config.paths.database)
        self.appium_manager = appium_manager or AppiumManager(config)
        self.live_control = live_control or LiveControlManager(
            config, self.live_store, self.discovery, self.appium_manager
        )
        self.trace_service = trace_service or TraceService(
            config, self.store, self.live_store
        )
        set_terminal_callback = getattr(
            self.live_control, "set_terminal_callback", None
        )
        if callable(set_terminal_callback):
            set_terminal_callback(self._export_terminal_live_evidence)
        self.token = self.load_or_create_token()
        self._stop_event = threading.Event()
        self._wake_event = threading.Event()
        self._worker: threading.Thread | None = None
        self._http_thread: threading.Thread | None = None
        self._http_server: Any = None
        self._started_at = time.time()
        self._lifecycle_lock = threading.RLock()

    def _command_environment(self) -> dict[str, str] | None:
        environment = os.environ.copy()
        environment.update(self.config.environment())
        return environment

    def load_or_create_token(self) -> str:
        path = self.config.api.token_file
        if path.exists():
            token = path.read_text(encoding="utf-8").strip()
            if len(token) < 32:
                raise RuntimeError("API token file contains an invalid token")
            os.chmod(path, 0o600)
            return token
        token = secrets.token_urlsafe(32)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(token + "\n")
        return token

    def start(self, *, start_http: bool = True) -> None:
        with self._lifecycle_lock:
            if self._worker and self._worker.is_alive():
                return
            self._recover_running_jobs()
            self.live_control.start()
            self._stop_event.clear()
            self._worker = threading.Thread(
                target=self._worker_loop, name="faceswap-qa-worker", daemon=True
            )
            self._worker.start()
            if start_http:
                from .api import create_http_server

                self._http_server = create_http_server(self, self.token)
                self._http_thread = threading.Thread(
                    target=self._http_server.serve_forever,
                    name="faceswap-qa-http",
                    daemon=True,
                )
                self._http_thread.start()

    def stop(self) -> None:
        with self._lifecycle_lock:
            self._stop_event.set()
            self._wake_event.set()
            active = self.store.active_job_id()
            if active:
                self.store.request_cancel(active)
            if self._http_server is not None:
                self._http_server.shutdown()
                self._http_server.server_close()
            self.live_control.stop(stop_appium=True)
            if self._http_thread is not None:
                self._http_thread.join(timeout=10)
            if self._worker is not None:
                self._worker.join(timeout=self.config.limits.kill_grace_seconds + 10)
            self._http_server = None
            self._http_thread = None
            self._worker = None

    @property
    def address(self) -> tuple[str, int] | None:
        if self._http_server is None:
            return None
        host, port = self._http_server.server_address[:2]
        return str(host), int(port)

    def run_forever(self) -> None:
        self.start()
        previous: dict[int, Any] = {}

        def stop_handler(signum: int, frame: Any) -> None:
            self._stop_event.set()
            self._wake_event.set()

        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, stop_handler)
        try:
            while not self._stop_event.wait(0.5):
                pass
        finally:
            self.stop()
            for signum, handler in previous.items():
                signal.signal(signum, handler)

    def submit(
        self, request: JobRequest, idempotency_key: str | None = None
    ) -> tuple[Job, bool]:
        job, created = self.store.create_job(request, idempotency_key)
        if created:
            self._wake_event.set()
        return job, created

    def cancel(self, job_id: str) -> Job | None:
        job = self.store.request_cancel(job_id)
        if job is not None:
            self._wake_event.set()
        return job

    def health(self) -> dict[str, Any]:
        return {
            "status": "ok" if not self._stop_event.is_set() else "stopping",
            "version": "0.3.0",
            "uptime_seconds": max(0, int(time.time() - self._started_at)),
            "queue_depth": self.store.queue_depth(),
            "active_job_id": self.store.active_job_id(),
            "active_live_session_id": (
                self.live_store.nonterminal_session().id
                if self.live_store.nonterminal_session() is not None
                else None
            ),
            "appium": self.appium_manager.state().to_dict(),
            "worker_alive": bool(self._worker and self._worker.is_alive()),
        }

    def create_live_session(
        self, request: LiveSessionRequest, idempotency_key: str | None = None
    ) -> tuple[LiveSession, str | None, bool]:
        session, lease_token, created = self.live_control.create_session(
            request, idempotency_key
        )
        return session, lease_token, created

    def close_live_session(self, session_id: str, lease_token: str) -> LiveSession:
        session = self.live_control.close_session(session_id, lease_token)
        self._wake_event.set()
        return session

    def job_document(self, job: Job, *, include_events: bool = True) -> dict[str, Any]:
        document = job.to_dict()
        document["artifacts"] = [item.to_dict() for item in self.store.get_artifacts(job.id)]
        if include_events:
            document["events"] = self.store.get_events(job.id, limit=500)
        return document

    def list_traces(
        self,
        *,
        owner_type: str | None = None,
        status: str | None = None,
        since: float | None = None,
        until: float | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        return self.trace_service.list_traces(
            owner_type=owner_type,
            status=status,
            since=since,
            until=until,
            offset=offset,
            limit=limit,
        )

    def trace_document(self, session_trace_id: str) -> dict[str, Any]:
        return self.trace_service.document(session_trace_id)

    def trace_events(
        self,
        session_trace_id: str,
        *,
        after: int = 0,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        return self.trace_service.events(
            session_trace_id,
            after=after,
            limit=limit,
        )

    def trace_analytics(self, session_trace_id: str) -> dict[str, Any]:
        return self.trace_service.analytics(session_trace_id)

    def trace_recoveries(self, session_trace_id: str) -> list[dict[str, Any]]:
        return self.trace_service.recoveries(session_trace_id)

    def list_recoveries(
        self,
        *,
        session_trace_id: str | None = None,
        owner_type: str | None = None,
        cause: str | None = None,
        outcome: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        return self.trace_service.list_recoveries(
            session_trace_id=session_trace_id,
            owner_type=owner_type,
            cause=cause,
            outcome=outcome,
            offset=offset,
            limit=limit,
        )

    def recovery_document(self, recovery_id: str) -> dict[str, Any]:
        return self.trace_service.recovery(recovery_id)

    def trace_evidence_bundle(self, session_trace_id: str):
        return self.trace_service.evidence_bundle(session_trace_id)

    def export_trace_evidence(self, session_trace_id: str) -> dict[str, Any]:
        return self.trace_service.export_evidence(session_trace_id)

    def read_job_log(self, job: Job, offset: int, limit: int) -> dict[str, Any]:
        offset = max(0, offset)
        limit = max(1, min(limit, 1024 * 1024))
        root = (self.config.paths.artifacts / job.id).resolve()
        try:
            root.relative_to(self.config.paths.artifacts.resolve())
        except ValueError as error:
            raise RuntimeError("job log path escaped artifact root") from error
        candidates = sorted(root.glob("attempt-*/xcodebuild.log")) if root.exists() else []
        if not candidates:
            return {"data": "", "offset": offset, "next_offset": offset, "eof": True}
        path = candidates[-1]
        size = path.stat().st_size
        offset = min(offset, size)
        with path.open("rb") as handle:
            handle.seek(offset)
            content = handle.read(limit)
        return {
            "data": content.decode("utf-8", errors="replace"),
            "offset": offset,
            "next_offset": offset + len(content),
            "eof": offset + len(content) >= size,
            "attempt": path.parent.name,
        }

    def _export_terminal_live_evidence(self, session: LiveSession) -> None:
        try:
            self.trace_service.export_evidence(session.request.session_trace_id)
        except Exception as error:
            self.live_store.append_event(
                session.id,
                "evidence",
                "terminal_export_failed",
                {
                    "error_code": getattr(error, "code", "evidence_export_failed"),
                    "message": str(error)[:1024],
                },
            )

    def _export_terminal_job_evidence(self, job: Job) -> None:
        try:
            self.trace_service.export_evidence(job.request.session_trace_id)
        except Exception as error:
            self.store.append_event(
                job.id,
                "evidence_export_failed",
                {
                    "error_code": getattr(error, "code", "evidence_export_failed"),
                    "message": str(error)[:1024],
                },
            )

    def _worker_loop(self) -> None:
        last_retention = 0.0
        while not self._stop_event.is_set():
            job = self.store.claim_next_job()
            if job is None:
                now = time.monotonic()
                if now - last_retention >= 300:
                    self._prune_expired()
                    last_retention = now
                self._wake_event.wait(0.5)
                self._wake_event.clear()
                continue
            try:
                result = self.runner.run(job)
                self.store.replace_artifacts(job.id, result.artifacts)
                if self.store.is_cancel_requested(job.id) or result.error_code == "cancelled":
                    self.store.mark_cancelled(job.id, result.error_message or "cancelled")
                elif result.success:
                    self.store.complete_job(job.id, result.exit_code or 0, result.result_path)
                else:
                    updated = self.store.fail_or_retry_job(
                        job.id,
                        result.error_code or "runner_error",
                        result.error_message or "runner failed",
                        result_path=result.result_path,
                    )
                    if updated is not None and updated.status == JobStatus.QUEUED:
                        self._wake_event.set()
            except Exception as error:  # Keep the persistent worker alive and persist failure.
                self.store.fail_or_retry_job(job.id, "worker_error", str(error), transient=False)
            latest = self.store.get_job(job.id)
            if latest is not None and latest.status.terminal:
                self._export_terminal_job_evidence(latest)

    def _recover_running_jobs(self) -> None:
        for job in self.store.running_jobs():
            if job.pid:
                self._terminate_verified_stale_process(job.pid)
        self.store.recover_running_jobs()

    def _terminate_verified_stale_process(self, pid: int) -> bool:
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        command = result.stdout.strip()
        expected_markers = (
            "xcodebuild",
            self.config.xcode.scheme,
            str(self.config.paths.project_path),
        )
        if result.returncode != 0 or not all(marker in command for marker in expected_markers):
            return False
        try:
            os.killpg(pid, signal.SIGTERM)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def _prune_expired(self) -> None:
        expired = self.store.delete_expired_jobs(self.config.limits.retention_hours)
        for job in expired:
            root = (self.config.paths.artifacts / job.id).resolve()
            try:
                root.relative_to(self.config.paths.artifacts.resolve())
            except ValueError:
                continue
            if root.exists() and root.is_dir() and not root.is_symlink():
                import shutil

                shutil.rmtree(root)
        expired_sessions = self.live_store.delete_expired_sessions(
            self.config.limits.retention_hours
        )
        for session in expired_sessions:
            root = (self.config.paths.artifacts / "live" / session.id).resolve()
            try:
                root.relative_to(self.config.paths.artifacts.resolve())
            except ValueError:
                continue
            if root.exists() and root.is_dir() and not root.is_symlink():
                import shutil

                shutil.rmtree(root)
