from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Iterable

from .json_safety import loads_bounded
from .models import Artifact, Job, JobRequest, JobStatus, TRANSIENT_ERROR_CODES, new_uuid, utc_timestamp
from .trace_context import normalize_uuid

SCHEMA_VERSION = 2


class JobStore:
    def __init__(self, database_path: str | Path) -> None:
        self.database_path = Path(database_path).expanduser().resolve()
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connection(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=30.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 30000")
        return connection

    def _initialize(self) -> None:
        with self._lock, self._connection() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = NORMAL")
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version not in {0, 1, SCHEMA_VERSION}:
                raise RuntimeError(f"unsupported database schema version: {version}")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    session_trace_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    pid INTEGER,
                    exit_code INTEGER,
                    error_code TEXT,
                    error_message TEXT,
                    cancel_requested INTEGER NOT NULL DEFAULT 0,
                    idempotency_key TEXT UNIQUE,
                    result_path TEXT
                );
                CREATE INDEX IF NOT EXISTS jobs_queue_index
                    ON jobs(status, created_at, id);
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    session_trace_id TEXT NOT NULL,
                    operation_trace_id TEXT,
                    span_id TEXT,
                    FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS events_job_index
                    ON events(job_id, id);
                CREATE TABLE IF NOT EXISTS artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    session_trace_id TEXT NOT NULL,
                    operation_trace_id TEXT,
                    span_id TEXT,
                    content_type TEXT,
                    provenance TEXT NOT NULL DEFAULT 'agent',
                    redaction_state TEXT NOT NULL DEFAULT 'not_applicable',
                    UNIQUE(job_id, path),
                    FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
                );
                """
            )
            if version == 1:
                self._migrate_v1_to_v2(connection)
            connection.executescript(
                """
                CREATE INDEX IF NOT EXISTS jobs_trace_index
                    ON jobs(session_trace_id, created_at, id);
                CREATE INDEX IF NOT EXISTS events_trace_index
                    ON events(session_trace_id, id);
                CREATE INDEX IF NOT EXISTS artifacts_trace_index
                    ON artifacts(session_trace_id, id);
                """
            )
            connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    @staticmethod
    def _migrate_v1_to_v2(connection: sqlite3.Connection) -> None:
        def columns(table: str) -> set[str]:
            return {
                str(row["name"])
                for row in connection.execute(f"PRAGMA table_info({table})").fetchall()
            }

        additions = {
            "jobs": {"session_trace_id": "TEXT"},
            "events": {
                "session_trace_id": "TEXT",
                "operation_trace_id": "TEXT",
                "span_id": "TEXT",
            },
            "artifacts": {
                "session_trace_id": "TEXT",
                "operation_trace_id": "TEXT",
                "span_id": "TEXT",
                "content_type": "TEXT",
                "provenance": "TEXT NOT NULL DEFAULT 'agent'",
                "redaction_state": "TEXT NOT NULL DEFAULT 'not_applicable'",
            },
        }
        for table, fields in additions.items():
            existing = columns(table)
            for name, declaration in fields.items():
                if name not in existing:
                    connection.execute(
                        f"ALTER TABLE {table} ADD COLUMN {name} {declaration}"
                    )

        rows = connection.execute("SELECT id, request_json FROM jobs").fetchall()
        for row in rows:
            request = loads_bounded(row["request_json"], maximum_bytes=1024 * 1024)
            run_id = normalize_uuid(request["run_id"], "run_id")
            trace_id = normalize_uuid(
                request.get("session_trace_id") or run_id, "session_trace_id"
            )
            request["session_trace_id"] = trace_id
            connection.execute(
                "UPDATE jobs SET request_json = ?, session_trace_id = ? WHERE id = ?",
                (
                    json.dumps(request, sort_keys=True, separators=(",", ":")),
                    trace_id,
                    row["id"],
                ),
            )
        connection.execute(
            """
            UPDATE events SET session_trace_id = (
                SELECT jobs.session_trace_id FROM jobs WHERE jobs.id = events.job_id
            ) WHERE session_trace_id IS NULL
            """
        )
        connection.execute(
            """
            UPDATE artifacts SET session_trace_id = (
                SELECT jobs.session_trace_id FROM jobs WHERE jobs.id = artifacts.job_id
            ) WHERE session_trace_id IS NULL
            """
        )

    @staticmethod
    def _row_to_job(row: sqlite3.Row) -> Job:
        request = JobRequest.from_dict(
            loads_bounded(row["request_json"], maximum_bytes=1024 * 1024),
            maximum_timeout=86400,
            maximum_retries=10,
        )
        return Job(
            id=row["id"],
            status=JobStatus(row["status"]),
            request=request,
            created_at=float(row["created_at"]),
            updated_at=float(row["updated_at"]),
            attempt=int(row["attempt"]),
            pid=row["pid"],
            exit_code=row["exit_code"],
            error_code=row["error_code"],
            error_message=row["error_message"],
            cancel_requested=bool(row["cancel_requested"]),
            idempotency_key=row["idempotency_key"],
            result_path=row["result_path"],
        )

    @staticmethod
    def _insert_event(
        connection: sqlite3.Connection,
        job_id: str,
        event_type: str,
        details: dict[str, Any] | None = None,
        *,
        timestamp: float | None = None,
        session_trace_id: str | None = None,
        operation_trace_id: str | None = None,
        span_id: str | None = None,
    ) -> None:
        if session_trace_id is None:
            row = connection.execute(
                "SELECT session_trace_id FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
            if row is None:
                raise ValueError("job does not exist")
            session_trace_id = row["session_trace_id"]
        session_trace_id = normalize_uuid(session_trace_id, "session_trace_id")
        if operation_trace_id is not None:
            operation_trace_id = normalize_uuid(
                operation_trace_id, "operation_trace_id"
            )
        connection.execute(
            """
            INSERT INTO events(
                job_id, timestamp, event_type, details_json,
                session_trace_id, operation_trace_id, span_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                job_id,
                timestamp if timestamp is not None else utc_timestamp(),
                event_type,
                json.dumps(details or {}, sort_keys=True, separators=(",", ":")),
                session_trace_id,
                operation_trace_id,
                span_id,
            ),
        )

    def create_job(
        self, request: JobRequest, idempotency_key: str | None = None
    ) -> tuple[Job, bool]:
        if idempotency_key is not None:
            idempotency_key = idempotency_key.strip()
            if not idempotency_key or len(idempotency_key) > 256:
                raise ValueError("Idempotency-Key must contain 1 to 256 characters")
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if idempotency_key:
                row = connection.execute(
                    "SELECT * FROM jobs WHERE idempotency_key = ?", (idempotency_key,)
                ).fetchone()
                if row is not None:
                    return self._row_to_job(row), False
            job_id = new_uuid()
            now = utc_timestamp()
            connection.execute(
                """
                INSERT INTO jobs(
                    id, status, request_json, session_trace_id,
                    created_at, updated_at, idempotency_key
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    JobStatus.QUEUED.value,
                    json.dumps(request.to_dict(), sort_keys=True, separators=(",", ":")),
                    request.session_trace_id,
                    now,
                    now,
                    idempotency_key,
                ),
            )
            self._insert_event(
                connection,
                job_id,
                "created",
                {"status": JobStatus.QUEUED.value},
                timestamp=now,
            )
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            assert row is not None
            return self._row_to_job(row), True

    def get_job(self, job_id: str) -> Job | None:
        with self._lock, self._connection() as connection:
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            return self._row_to_job(row) if row is not None else None

    def get_job_by_trace(self, session_trace_id: str) -> Job | None:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM jobs WHERE session_trace_id = ?",
                (root,),
            ).fetchone()
            return self._row_to_job(row) if row is not None else None

    def list_jobs(self, status: JobStatus | None = None, limit: int = 100) -> list[Job]:
        limit = max(1, min(int(limit), 500))
        with self._lock, self._connection() as connection:
            if status is None:
                rows = connection.execute(
                    "SELECT * FROM jobs ORDER BY created_at DESC, id DESC LIMIT ?", (limit,)
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM jobs WHERE status = ? ORDER BY created_at DESC, id DESC LIMIT ?",
                    (status.value, limit),
                ).fetchall()
            return [self._row_to_job(row) for row in rows]

    def running_jobs(self) -> list[Job]:
        return self.list_jobs(JobStatus.RUNNING, limit=500)

    def claim_next_job(self) -> Job | None:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            live_table = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'live_sessions'"
            ).fetchone()
            if live_table is not None:
                live_owner = connection.execute(
                    """
                    SELECT id FROM live_sessions
                    WHERE status IN ('pending', 'starting', 'active', 'stopping') LIMIT 1
                    """
                ).fetchone()
                if live_owner is not None:
                    return None
            row = connection.execute(
                """
                SELECT * FROM jobs
                WHERE status = ? AND cancel_requested = 0
                ORDER BY created_at ASC, id ASC LIMIT 1
                """,
                (JobStatus.QUEUED.value,),
            ).fetchone()
            if row is None:
                return None
            now = utc_timestamp()
            changed = connection.execute(
                """
                UPDATE jobs
                SET status = ?, updated_at = ?, attempt = attempt + 1,
                    pid = NULL, exit_code = NULL
                WHERE id = ? AND status = ?
                """,
                (JobStatus.RUNNING.value, now, row["id"], JobStatus.QUEUED.value),
            ).rowcount
            if changed != 1:
                return None
            self._insert_event(
                connection,
                row["id"],
                "claimed",
                {"status": JobStatus.RUNNING.value, "attempt": int(row["attempt"]) + 1},
                timestamp=now,
            )
            claimed = connection.execute(
                "SELECT * FROM jobs WHERE id = ?", (row["id"],)
            ).fetchone()
            assert claimed is not None
            return self._row_to_job(claimed)

    def set_pid(self, job_id: str, pid: int | None) -> bool:
        with self._lock, self._connection() as connection:
            changed = connection.execute(
                "UPDATE jobs SET pid = ?, updated_at = ? WHERE id = ? AND status = ?",
                (pid, utc_timestamp(), job_id, JobStatus.RUNNING.value),
            ).rowcount
            return changed == 1

    def request_cancel(self, job_id: str) -> Job | None:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if row is None:
                return None
            status = JobStatus(row["status"])
            if status.terminal:
                return self._row_to_job(row)
            now = utc_timestamp()
            if status == JobStatus.QUEUED:
                connection.execute(
                    """
                    UPDATE jobs SET status = ?, cancel_requested = 1, updated_at = ?
                    WHERE id = ?
                    """,
                    (JobStatus.CANCELLED.value, now, job_id),
                )
                event_type = "cancelled"
            else:
                connection.execute(
                    "UPDATE jobs SET cancel_requested = 1, updated_at = ? WHERE id = ?",
                    (now, job_id),
                )
                event_type = "cancel_requested"
            self._insert_event(connection, job_id, event_type, timestamp=now)
            updated = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            assert updated is not None
            return self._row_to_job(updated)

    def is_cancel_requested(self, job_id: str) -> bool:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT cancel_requested FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
            return bool(row[0]) if row is not None else True

    def mark_cancelled(self, job_id: str, message: str = "cancelled") -> bool:
        return self._finish(
            job_id,
            JobStatus.CANCELLED,
            exit_code=None,
            error_code="cancelled",
            error_message=message,
            result_path=None,
        )

    def complete_job(self, job_id: str, exit_code: int, result_path: str | None) -> bool:
        status = JobStatus.SUCCEEDED if exit_code == 0 else JobStatus.FAILED
        return self._finish(
            job_id,
            status,
            exit_code=exit_code,
            error_code=None if exit_code == 0 else "xcodebuild_failed",
            error_message=None if exit_code == 0 else f"xcodebuild exited with code {exit_code}",
            result_path=result_path,
        )

    def _finish(
        self,
        job_id: str,
        status: JobStatus,
        *,
        exit_code: int | None,
        error_code: str | None,
        error_message: str | None,
        result_path: str | None,
    ) -> bool:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = connection.execute(
                "SELECT status FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
            if current is None or JobStatus(current["status"]) != JobStatus.RUNNING:
                return False
            now = utc_timestamp()
            connection.execute(
                """
                UPDATE jobs
                SET status = ?, updated_at = ?, pid = NULL, exit_code = ?,
                    error_code = ?, error_message = ?, result_path = ?
                WHERE id = ?
                """,
                (
                    status.value,
                    now,
                    exit_code,
                    error_code,
                    error_message,
                    result_path,
                    job_id,
                ),
            )
            self._insert_event(
                connection,
                job_id,
                "finished",
                {"status": status.value, "exit_code": exit_code, "error_code": error_code},
                timestamp=now,
            )
            return True

    def fail_or_retry_job(
        self,
        job_id: str,
        error_code: str,
        error_message: str,
        *,
        result_path: str | None = None,
        transient: bool | None = None,
    ) -> Job | None:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if row is None or JobStatus(row["status"]) != JobStatus.RUNNING:
                return None
            job = self._row_to_job(row)
            is_transient = error_code in TRANSIENT_ERROR_CODES if transient is None else transient
            retry = is_transient and job.attempt <= job.request.max_retries and not job.cancel_requested
            status = JobStatus.QUEUED if retry else JobStatus.FAILED
            now = utc_timestamp()
            connection.execute(
                """
                UPDATE jobs
                SET status = ?, updated_at = ?, pid = NULL, exit_code = NULL,
                    error_code = ?, error_message = ?, result_path = ?
                WHERE id = ?
                """,
                (status.value, now, error_code, error_message, result_path, job_id),
            )
            self._insert_event(
                connection,
                job_id,
                "retry_queued" if retry else "failed",
                {
                    "status": status.value,
                    "attempt": job.attempt,
                    "error_code": error_code,
                    "error_message": error_message,
                },
                timestamp=now,
            )
            updated = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            assert updated is not None
            return self._row_to_job(updated)

    def recover_running_jobs(self) -> list[Job]:
        recovered: list[Job] = []
        for job in self.running_jobs():
            updated = self.fail_or_retry_job(
                job.id,
                "agent_restarted",
                "agent restarted while the job was running",
                transient=True,
            )
            if updated is not None:
                recovered.append(updated)
        return recovered

    def append_event(
        self,
        job_id: str,
        event_type: str,
        details: dict[str, Any],
        *,
        operation_trace_id: str | None = None,
        span_id: str | None = None,
    ) -> None:
        with self._lock, self._connection() as connection:
            self._insert_event(
                connection,
                job_id,
                event_type,
                details,
                operation_trace_id=operation_trace_id,
                span_id=span_id,
            )

    def get_events(self, job_id: str, offset: int = 0, limit: int = 100) -> list[dict[str, Any]]:
        offset = max(0, int(offset))
        limit = max(1, min(int(limit), 1000))
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT id, timestamp, event_type, details_json,
                       session_trace_id, operation_trace_id, span_id FROM events
                WHERE job_id = ? AND id > ? ORDER BY id ASC LIMIT ?
                """,
                (job_id, offset, limit),
            ).fetchall()
            return [
                {
                    "id": int(row["id"]),
                    "timestamp": float(row["timestamp"]),
                    "type": row["event_type"],
                    "session_trace_id": row["session_trace_id"],
                    "trace_id": row["operation_trace_id"],
                    "operation_trace_id": row["operation_trace_id"],
                    "span_id": row["span_id"],
                    "details": loads_bounded(
                        row["details_json"], maximum_bytes=16 * 1024 * 1024
                    ),
                }
                for row in rows
            ]

    def replace_artifacts(self, job_id: str, artifacts: Iterable[Artifact]) -> None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT session_trace_id FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
            if row is None:
                raise ValueError("job does not exist")
            root = normalize_uuid(row["session_trace_id"], "session_trace_id")
            records: list[tuple[Any, ...]] = []
            for artifact in artifacts:
                artifact_root = artifact.session_trace_id or root
                if normalize_uuid(artifact_root, "session_trace_id") != root:
                    raise ValueError("artifact session trace does not match job")
                records.append(
                    (
                        job_id,
                        artifact.path,
                        artifact.kind,
                        artifact.byte_size,
                        artifact.sha256,
                        artifact.created_at,
                        root,
                        artifact.operation_trace_id,
                        artifact.span_id,
                        artifact.content_type,
                        artifact.provenance,
                        artifact.redaction_state,
                    )
                )
            connection.execute("DELETE FROM artifacts WHERE job_id = ?", (job_id,))
            connection.executemany(
                """
                INSERT INTO artifacts(
                    job_id, path, kind, byte_size, sha256, created_at,
                    session_trace_id, operation_trace_id, span_id,
                    content_type, provenance, redaction_state
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                records,
            )

    def get_artifacts(self, job_id: str) -> list[Artifact]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT path, kind, byte_size, sha256, created_at,
                       session_trace_id, operation_trace_id, span_id,
                       content_type, provenance, redaction_state
                FROM artifacts WHERE job_id = ? ORDER BY path ASC
                """,
                (job_id,),
            ).fetchall()
            return [
                Artifact(
                    path=row["path"],
                    kind=row["kind"],
                    byte_size=int(row["byte_size"]),
                    sha256=row["sha256"],
                    created_at=float(row["created_at"]),
                    session_trace_id=row["session_trace_id"],
                    operation_trace_id=row["operation_trace_id"],
                    span_id=row["span_id"],
                    content_type=row["content_type"],
                    provenance=row["provenance"],
                    redaction_state=row["redaction_state"],
                )
                for row in rows
            ]

    def queue_depth(self) -> int:
        with self._lock, self._connection() as connection:
            return int(
                connection.execute(
                    "SELECT COUNT(*) FROM jobs WHERE status = ?", (JobStatus.QUEUED.value,)
                ).fetchone()[0]
            )

    def active_job_id(self) -> str | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT id FROM jobs WHERE status = ? ORDER BY updated_at DESC LIMIT 1",
                (JobStatus.RUNNING.value,),
            ).fetchone()
            return row["id"] if row is not None else None

    def delete_expired_jobs(self, retention_hours: int) -> list[Job]:
        cutoff = utc_timestamp() - max(1, retention_hours) * 3600
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                """
                SELECT * FROM jobs
                WHERE status IN (?, ?, ?) AND updated_at < ?
                ORDER BY updated_at ASC
                """,
                (
                    JobStatus.SUCCEEDED.value,
                    JobStatus.FAILED.value,
                    JobStatus.CANCELLED.value,
                    cutoff,
                ),
            ).fetchall()
            jobs = [self._row_to_job(row) for row in rows]
            if jobs:
                connection.executemany("DELETE FROM jobs WHERE id = ?", [(job.id,) for job in jobs])
            return jobs
