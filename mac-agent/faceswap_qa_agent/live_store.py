from __future__ import annotations

import hmac
import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Iterable

from .config import PortRange
from .json_safety import loads_bounded
from .live_models import (
    LeaseCredential,
    LiveEvent,
    LiveSession,
    LiveSessionRequest,
    LiveSessionStatus,
    hash_lease_token,
    is_valid_live_transition,
)
from .models import Artifact, new_uuid, utc_timestamp
from .recovery import RecoveryEpisode
from .trace_context import normalize_uuid

LIVE_SCHEMA_VERSION = 2
NONTERMINAL_STATUSES = (
    LiveSessionStatus.PENDING.value,
    LiveSessionStatus.STARTING.value,
    LiveSessionStatus.ACTIVE.value,
    LiveSessionStatus.STOPPING.value,
)


class LiveStoreError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class LiveStore:
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
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS live_schema (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    version INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS live_sessions (
                    id TEXT PRIMARY KEY,
                    request_json TEXT NOT NULL,
                    session_trace_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    lease_expires_at REAL NOT NULL,
                    lease_token_hash TEXT NOT NULL,
                    idempotency_key TEXT UNIQUE,
                    device_udid TEXT,
                    device_name TEXT,
                    appium_session_id TEXT,
                    appium_pid INTEGER,
                    appium_port INTEGER,
                    wda_port INTEGER,
                    mjpeg_port INTEGER,
                    wda_url TEXT,
                    error_code TEXT,
                    error_message TEXT,
                    closed_at REAL
                );
                CREATE INDEX IF NOT EXISTS live_sessions_status_index
                    ON live_sessions(status, created_at, id);
                CREATE UNIQUE INDEX IF NOT EXISTS live_sessions_nonterminal_udid
                    ON live_sessions(device_udid)
                    WHERE status IN ('pending', 'starting', 'active', 'stopping')
                      AND device_udid IS NOT NULL;
                CREATE TABLE IF NOT EXISTS live_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    category TEXT NOT NULL,
                    name TEXT NOT NULL,
                    trace_id TEXT,
                    session_trace_id TEXT NOT NULL,
                    operation_trace_id TEXT,
                    span_id TEXT,
                    payload_json TEXT NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES live_sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS live_events_session_index
                    ON live_events(session_id, id);
                CREATE TABLE IF NOT EXISTS live_artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
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
                    UNIQUE(session_id, path),
                    FOREIGN KEY(session_id) REFERENCES live_sessions(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS recovery_episodes (
                    recovery_id TEXT PRIMARY KEY,
                    owner_type TEXT NOT NULL,
                    owner_id TEXT NOT NULL,
                    session_trace_id TEXT NOT NULL,
                    operation_trace_id TEXT NOT NULL,
                    span_id TEXT NOT NULL,
                    traceparent TEXT NOT NULL,
                    cause TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    attempt INTEGER NOT NULL,
                    details_json TEXT NOT NULL,
                    evidence_paths_json TEXT NOT NULL,
                    error_code TEXT,
                    error_message TEXT
                );
                CREATE INDEX IF NOT EXISTS recovery_trace_index
                    ON recovery_episodes(session_trace_id, started_at, recovery_id);
                CREATE TABLE IF NOT EXISTS live_ports (
                    port INTEGER PRIMARY KEY,
                    kind TEXT NOT NULL CHECK(kind IN ('wda', 'mjpeg')),
                    session_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    UNIQUE(kind, session_id),
                    FOREIGN KEY(session_id) REFERENCES live_sessions(id) ON DELETE CASCADE
                );
                """
            )
            row = connection.execute(
                "SELECT version FROM live_schema WHERE singleton = 1"
            ).fetchone()
            if row is None:
                connection.execute(
                    "INSERT INTO live_schema(singleton, version) VALUES (1, ?)",
                    (LIVE_SCHEMA_VERSION,),
                )
            else:
                version = int(row["version"])
                if version == 1:
                    self._migrate_v1_to_v2(connection)
                    connection.execute(
                        "UPDATE live_schema SET version = ? WHERE singleton = 1",
                        (LIVE_SCHEMA_VERSION,),
                    )
                elif version != LIVE_SCHEMA_VERSION:
                    raise RuntimeError(f"unsupported live schema version: {version}")
            connection.executescript(
                """
                CREATE INDEX IF NOT EXISTS live_sessions_trace_index
                    ON live_sessions(session_trace_id, created_at, id);
                CREATE INDEX IF NOT EXISTS live_events_trace_index
                    ON live_events(session_trace_id, id);
                CREATE INDEX IF NOT EXISTS live_artifacts_trace_index
                    ON live_artifacts(session_trace_id, id);
                """
            )

    @staticmethod
    def _migrate_v1_to_v2(connection: sqlite3.Connection) -> None:
        def columns(table: str) -> set[str]:
            return {
                str(row["name"])
                for row in connection.execute(f"PRAGMA table_info({table})").fetchall()
            }

        additions = {
            "live_sessions": {"session_trace_id": "TEXT"},
            "live_events": {
                "session_trace_id": "TEXT",
                "operation_trace_id": "TEXT",
                "span_id": "TEXT",
            },
            "live_artifacts": {
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
        rows = connection.execute(
            "SELECT id, request_json FROM live_sessions"
        ).fetchall()
        for row in rows:
            request = loads_bounded(row["request_json"], maximum_bytes=1024 * 1024)
            run_id = normalize_uuid(request["run_id"], "run_id")
            trace_id = normalize_uuid(
                request.get("session_trace_id") or run_id, "session_trace_id"
            )
            request["session_trace_id"] = trace_id
            connection.execute(
                "UPDATE live_sessions SET request_json = ?, session_trace_id = ? WHERE id = ?",
                (
                    json.dumps(request, sort_keys=True, separators=(",", ":")),
                    trace_id,
                    row["id"],
                ),
            )
        connection.execute(
            """
            UPDATE live_events
            SET session_trace_id = (
                    SELECT live_sessions.session_trace_id
                    FROM live_sessions WHERE live_sessions.id = live_events.session_id
                ),
                operation_trace_id = COALESCE(operation_trace_id, trace_id)
            WHERE session_trace_id IS NULL OR operation_trace_id IS NULL
            """
        )
        connection.execute(
            """
            UPDATE live_artifacts SET session_trace_id = (
                SELECT live_sessions.session_trace_id
                FROM live_sessions WHERE live_sessions.id = live_artifacts.session_id
            ) WHERE session_trace_id IS NULL
            """
        )

    @staticmethod
    def _row_to_session(row: sqlite3.Row) -> LiveSession:
        request_json = loads_bounded(
            row["request_json"], maximum_bytes=1024 * 1024
        )
        request = LiveSessionRequest.from_dict(
            request_json,
            default_lease_seconds=int(request_json["lease_seconds"]),
            maximum_lease_seconds=86400,
        )
        return LiveSession(
            id=row["id"],
            request=request,
            status=LiveSessionStatus(row["status"]),
            created_at=float(row["created_at"]),
            updated_at=float(row["updated_at"]),
            lease_expires_at=float(row["lease_expires_at"]),
            lease_token_hash=row["lease_token_hash"],
            idempotency_key=row["idempotency_key"],
            device_udid=row["device_udid"],
            device_name=row["device_name"],
            appium_session_id=row["appium_session_id"],
            appium_pid=row["appium_pid"],
            appium_port=row["appium_port"],
            wda_port=row["wda_port"],
            mjpeg_port=row["mjpeg_port"],
            wda_url=row["wda_url"],
            error_code=row["error_code"],
            error_message=row["error_message"],
            closed_at=row["closed_at"],
        )

    @staticmethod
    def _insert_event(
        connection: sqlite3.Connection,
        session_id: str,
        category: str,
        name: str,
        payload: dict[str, Any] | None = None,
        *,
        trace_id: str | None = None,
        span_id: str | None = None,
        timestamp: float | None = None,
        session_trace_id: str | None = None,
    ) -> int:
        if session_trace_id is None:
            row = connection.execute(
                "SELECT session_trace_id FROM live_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            session_trace_id = row["session_trace_id"]
        session_trace_id = normalize_uuid(session_trace_id, "session_trace_id")
        if trace_id is not None:
            trace_id = normalize_uuid(trace_id, "operation_trace_id")
        cursor = connection.execute(
            """
            INSERT INTO live_events(
                session_id, timestamp, category, name, trace_id,
                session_trace_id, operation_trace_id, span_id, payload_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                session_id,
                timestamp if timestamp is not None else utc_timestamp(),
                category,
                name,
                trace_id,
                session_trace_id,
                trace_id,
                span_id,
                json.dumps(payload or {}, sort_keys=True, separators=(",", ":")),
            ),
        )
        return int(cursor.lastrowid)

    def create_session(
        self,
        request: LiveSessionRequest,
        *,
        idempotency_key: str | None,
        wda_ports: PortRange,
        mjpeg_ports: PortRange,
    ) -> tuple[LiveSession, str | None, bool]:
        if idempotency_key is not None:
            idempotency_key = idempotency_key.strip()
            if not idempotency_key or len(idempotency_key) > 256:
                raise ValueError("Idempotency-Key must contain 1 to 256 characters")
        credential = LeaseCredential.create()
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if idempotency_key:
                existing = connection.execute(
                    "SELECT * FROM live_sessions WHERE idempotency_key = ?",
                    (idempotency_key,),
                ).fetchone()
                if existing is not None:
                    return self._row_to_session(existing), None, False
            active_job = connection.execute(
                "SELECT id, status FROM jobs WHERE status IN ('queued', 'running') LIMIT 1"
            ).fetchone()
            if active_job is not None:
                raise LiveStoreError(
                    "device_busy",
                    f"Xcode job {active_job['id']} is {active_job['status']}",
                )
            active_session = connection.execute(
                """
                SELECT id FROM live_sessions
                WHERE status IN ('pending', 'starting', 'active', 'stopping') LIMIT 1
                """
            ).fetchone()
            if active_session is not None:
                raise LiveStoreError(
                    "device_busy", f"live session {active_session['id']} owns the device queue"
                )
            session_id = new_uuid()
            wda_port = self._allocate_port(connection, "wda", wda_ports)
            mjpeg_port = self._allocate_port(connection, "mjpeg", mjpeg_ports)
            now = utc_timestamp()
            connection.execute(
                """
                INSERT INTO live_sessions(
                    id, request_json, session_trace_id, status, created_at, updated_at,
                    lease_expires_at, lease_token_hash, idempotency_key,
                    wda_port, mjpeg_port
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session_id,
                    json.dumps(request.to_dict(), sort_keys=True, separators=(",", ":")),
                    request.session_trace_id,
                    LiveSessionStatus.PENDING.value,
                    now,
                    now,
                    now + request.lease_seconds,
                    credential.token_hash,
                    idempotency_key,
                    wda_port,
                    mjpeg_port,
                ),
            )
            connection.execute(
                "INSERT INTO live_ports(port, kind, session_id, created_at) VALUES (?, 'wda', ?, ?)",
                (wda_port, session_id, now),
            )
            connection.execute(
                "INSERT INTO live_ports(port, kind, session_id, created_at) VALUES (?, 'mjpeg', ?, ?)",
                (mjpeg_port, session_id, now),
            )
            self._insert_event(
                connection,
                session_id,
                "lifecycle",
                "created",
                {
                    "status": LiveSessionStatus.PENDING.value,
                    "wda_port": wda_port,
                    "mjpeg_port": mjpeg_port,
                },
                timestamp=now,
            )
            row = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            assert row is not None
            return self._row_to_session(row), credential.token, True

    @staticmethod
    def _allocate_port(
        connection: sqlite3.Connection, kind: str, ports: PortRange
    ) -> int:
        used = {
            int(row["port"])
            for row in connection.execute(
                "SELECT port FROM live_ports WHERE kind = ?", (kind,)
            ).fetchall()
        }
        for port in ports.values():
            if port not in used:
                return port
        raise LiveStoreError("port_exhausted", f"no {kind} ports are available")

    def get_session(self, session_id: str) -> LiveSession | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            return self._row_to_session(row) if row is not None else None

    def list_sessions(
        self, status: LiveSessionStatus | None = None, limit: int = 100
    ) -> list[LiveSession]:
        limit = max(1, min(int(limit), 500))
        with self._lock, self._connection() as connection:
            if status is None:
                rows = connection.execute(
                    "SELECT * FROM live_sessions ORDER BY created_at DESC, id DESC LIMIT ?",
                    (limit,),
                ).fetchall()
            else:
                rows = connection.execute(
                    """
                    SELECT * FROM live_sessions WHERE status = ?
                    ORDER BY created_at DESC, id DESC LIMIT ?
                    """,
                    (status.value, limit),
                ).fetchall()
            return [self._row_to_session(row) for row in rows]

    def nonterminal_session(self) -> LiveSession | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT * FROM live_sessions
                WHERE status IN ('pending', 'starting', 'active', 'stopping')
                ORDER BY created_at ASC LIMIT 1
                """
            ).fetchone()
            return self._row_to_session(row) if row is not None else None

    def has_ownership(self) -> bool:
        return self.nonterminal_session() is not None

    def transition(
        self,
        session_id: str,
        target: LiveSessionStatus,
        *,
        error_code: str | None = None,
        error_message: str | None = None,
        event_name: str | None = None,
    ) -> LiveSession:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            current = LiveSessionStatus(row["status"])
            if current == target:
                return self._row_to_session(row)
            if not is_valid_live_transition(current, target):
                raise LiveStoreError(
                    "invalid_transition", f"cannot transition {current.value} to {target.value}"
                )
            now = utc_timestamp()
            closed_at = now if target.terminal else None
            connection.execute(
                """
                UPDATE live_sessions SET status = ?, updated_at = ?, error_code = ?,
                    error_message = ?, closed_at = COALESCE(?, closed_at)
                WHERE id = ?
                """,
                (target.value, now, error_code, error_message, closed_at, session_id),
            )
            self._insert_event(
                connection,
                session_id,
                "lifecycle",
                event_name or target.value,
                {
                    "from": current.value,
                    "to": target.value,
                    "error_code": error_code,
                    "error_message": error_message,
                },
                timestamp=now,
            )
            if target.terminal:
                connection.execute("DELETE FROM live_ports WHERE session_id = ?", (session_id,))
            updated = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            assert updated is not None
            return self._row_to_session(updated)

    def bind_starting(
        self,
        session_id: str,
        *,
        device_udid: str,
        device_name: str,
        appium_pid: int | None,
        appium_port: int,
        wda_url: str,
    ) -> LiveSession:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT status FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            current = LiveSessionStatus(row["status"])
            if current != LiveSessionStatus.PENDING:
                raise LiveStoreError("invalid_transition", "session is not pending")
            now = utc_timestamp()
            connection.execute(
                """
                UPDATE live_sessions SET status = ?, updated_at = ?, device_udid = ?,
                    device_name = ?, appium_pid = ?, appium_port = ?, wda_url = ?
                WHERE id = ?
                """,
                (
                    LiveSessionStatus.STARTING.value,
                    now,
                    device_udid,
                    device_name,
                    appium_pid,
                    appium_port,
                    wda_url,
                    session_id,
                ),
            )
            self._insert_event(
                connection,
                session_id,
                "lifecycle",
                "starting",
                {"device_udid": device_udid, "appium_port": appium_port, "wda_url": wda_url},
                timestamp=now,
            )
            updated = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            assert updated is not None
            return self._row_to_session(updated)

    def activate(self, session_id: str, appium_session_id: str) -> LiveSession:
        if not appium_session_id or len(appium_session_id) > 512:
            raise ValueError("invalid Appium session identifier")
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT status FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            if LiveSessionStatus(row["status"]) != LiveSessionStatus.STARTING:
                raise LiveStoreError("invalid_transition", "session is not starting")
            now = utc_timestamp()
            connection.execute(
                """
                UPDATE live_sessions SET status = ?, updated_at = ?, appium_session_id = ?
                WHERE id = ?
                """,
                (LiveSessionStatus.ACTIVE.value, now, appium_session_id, session_id),
            )
            self._insert_event(
                connection,
                session_id,
                "lifecycle",
                "active",
                {"appium_session_id": appium_session_id},
                timestamp=now,
            )
            updated = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            assert updated is not None
            return self._row_to_session(updated)

    def authorize_lease(
        self, session_id: str, token: str, *, require_active: bool = True
    ) -> LiveSession:
        if not isinstance(token, str) or len(token) < 32:
            raise LiveStoreError("invalid_lease", "valid live lease token required")
        session = self.get_session(session_id)
        if session is None:
            raise LiveStoreError("session_not_found", "live session not found")
        if not hmac.compare_digest(session.lease_token_hash, hash_lease_token(token)):
            raise LiveStoreError("invalid_lease", "valid live lease token required")
        if session.lease_expires_at <= utc_timestamp() and not session.status.terminal:
            raise LiveStoreError("lease_expired", "live session lease has expired")
        if require_active and session.status != LiveSessionStatus.ACTIVE:
            raise LiveStoreError("session_not_active", "live session is not active")
        return session

    def renew_lease(
        self,
        session_id: str,
        token: str,
        lease_seconds: int,
        *,
        maximum_lease_seconds: int,
    ) -> LiveSession:
        if lease_seconds < 30 or lease_seconds > maximum_lease_seconds:
            raise ValueError(
                f"lease_seconds must be between 30 and {maximum_lease_seconds}"
            )
        self.authorize_lease(session_id, token, require_active=False)
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            status = LiveSessionStatus(row["status"])
            if status.terminal:
                raise LiveStoreError("session_terminal", "live session is terminal")
            now = utc_timestamp()
            expires_at = now + lease_seconds
            connection.execute(
                "UPDATE live_sessions SET updated_at = ?, lease_expires_at = ? WHERE id = ?",
                (now, expires_at, session_id),
            )
            self._insert_event(
                connection,
                session_id,
                "lease",
                "renewed",
                {"lease_expires_at": expires_at},
                timestamp=now,
            )
            updated = connection.execute(
                "SELECT * FROM live_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            assert updated is not None
            return self._row_to_session(updated)

    def append_event(
        self,
        session_id: str,
        category: str,
        name: str,
        payload: dict[str, Any],
        *,
        trace_id: str | None = None,
        span_id: str | None = None,
    ) -> LiveEvent:
        if not category or len(category) > 64 or not name or len(name) > 128:
            raise ValueError("invalid live event name")
        with self._lock, self._connection() as connection:
            event_id = self._insert_event(
                connection,
                session_id,
                category,
                name,
                payload,
                trace_id=trace_id,
                span_id=span_id,
            )
            row = connection.execute(
                "SELECT * FROM live_events WHERE id = ?", (event_id,)
            ).fetchone()
            assert row is not None
            return self._row_to_event(row)

    @staticmethod
    def _row_to_event(row: sqlite3.Row) -> LiveEvent:
        return LiveEvent(
            id=int(row["id"]),
            session_id=row["session_id"],
            timestamp=float(row["timestamp"]),
            category=row["category"],
            name=row["name"],
            trace_id=row["operation_trace_id"] or row["trace_id"],
            session_trace_id=row["session_trace_id"],
            span_id=row["span_id"],
            payload=loads_bounded(
                row["payload_json"], maximum_bytes=16 * 1024 * 1024
            ),
        )

    def get_events(
        self, session_id: str, *, after: int = 0, limit: int = 100
    ) -> list[LiveEvent]:
        after = max(0, int(after))
        limit = max(1, min(int(limit), 1000))
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT * FROM live_events WHERE session_id = ? AND id > ?
                ORDER BY id ASC LIMIT ?
                """,
                (session_id, after, limit),
            ).fetchall()
            return [self._row_to_event(row) for row in rows]

    def prune_events(self, session_id: str, keep: int) -> int:
        keep = max(100, min(int(keep), 100000))
        with self._lock, self._connection() as connection:
            cursor = connection.execute(
                """
                DELETE FROM live_events
                WHERE session_id = ?
                  AND id NOT IN (
                    SELECT id FROM live_events
                    WHERE session_id = ?
                    ORDER BY id DESC LIMIT ?
                  )
                """,
                (session_id, session_id, keep),
            )
            return max(0, cursor.rowcount)

    def add_artifact(self, session_id: str, artifact: Artifact) -> None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT session_trace_id FROM live_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            if row is None:
                raise LiveStoreError("session_not_found", "live session not found")
            root = normalize_uuid(row["session_trace_id"], "session_trace_id")
            artifact_root = normalize_uuid(
                artifact.session_trace_id or root, "session_trace_id"
            )
            if artifact_root != root:
                raise LiveStoreError(
                    "trace_root_mismatch", "artifact belongs to another trace root"
                )
            connection.execute(
                """
                INSERT OR REPLACE INTO live_artifacts(
                    session_id, path, kind, byte_size, sha256, created_at,
                    session_trace_id, operation_trace_id, span_id,
                    content_type, provenance, redaction_state
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session_id,
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
                ),
            )

    def get_artifacts(self, session_id: str) -> list[Artifact]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT path, kind, byte_size, sha256, created_at,
                       session_trace_id, operation_trace_id, span_id,
                       content_type, provenance, redaction_state
                FROM live_artifacts WHERE session_id = ? ORDER BY path ASC
                """,
                (session_id,),
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

    def get_session_by_trace(self, session_trace_id: str) -> LiveSession | None:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM live_sessions WHERE session_trace_id = ?",
                (root,),
            ).fetchone()
            return self._row_to_session(row) if row is not None else None

    def get_events_by_trace(
        self, session_trace_id: str, *, after: int = 0, limit: int = 1000
    ) -> list[LiveEvent]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        after = max(0, int(after))
        limit = max(1, min(int(limit), 5000))
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT * FROM live_events
                WHERE session_trace_id = ? AND id > ?
                ORDER BY id ASC LIMIT ?
                """,
                (root, after, limit),
            ).fetchall()
            return [self._row_to_event(row) for row in rows]

    def record_recovery(self, episode: RecoveryEpisode) -> RecoveryEpisode:
        episode.validate()
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if episode.owner_type == "live_session":
                owner = connection.execute(
                    "SELECT session_trace_id FROM live_sessions WHERE id = ?",
                    (episode.owner_id,),
                ).fetchone()
            else:
                owner = connection.execute(
                    "SELECT session_trace_id FROM jobs WHERE id = ?",
                    (episode.owner_id,),
                ).fetchone()
            if owner is None:
                raise LiveStoreError("owner_not_found", "recovery owner not found")
            if normalize_uuid(owner["session_trace_id"], "session_trace_id") != episode.session_trace_id:
                raise LiveStoreError(
                    "trace_root_mismatch", "recovery belongs to another trace root"
                )
            existing = connection.execute(
                "SELECT * FROM recovery_episodes WHERE recovery_id = ?",
                (episode.recovery_id,),
            ).fetchone()
            if existing is not None:
                current = self._row_to_recovery(existing)
                if current == episode:
                    return current
                if current.outcome.terminal:
                    raise LiveStoreError(
                        "recovery_terminal", "terminal recovery cannot be changed"
                    )
                if not episode.outcome.terminal:
                    raise LiveStoreError(
                        "recovery_conflict", "observed recovery already exists"
                    )
                connection.execute(
                    """
                    UPDATE recovery_episodes SET outcome = ?, finished_at = ?,
                        details_json = ?, evidence_paths_json = ?, error_code = ?,
                        error_message = ? WHERE recovery_id = ?
                    """,
                    (
                        episode.outcome.value,
                        episode.finished_at,
                        json.dumps(episode.details, sort_keys=True, separators=(",", ":")),
                        json.dumps(list(episode.evidence_paths), separators=(",", ":")),
                        episode.error_code,
                        episode.error_message,
                        episode.recovery_id,
                    ),
                )
            else:
                connection.execute(
                    """
                    INSERT INTO recovery_episodes(
                        recovery_id, owner_type, owner_id, session_trace_id,
                        operation_trace_id, span_id, traceparent, cause, outcome,
                        started_at, finished_at, attempt, details_json,
                        evidence_paths_json, error_code, error_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        episode.recovery_id,
                        episode.owner_type,
                        episode.owner_id,
                        episode.session_trace_id,
                        episode.operation_trace_id,
                        episode.span_id,
                        episode.traceparent,
                        episode.cause.value,
                        episode.outcome.value,
                        episode.started_at,
                        episode.finished_at,
                        episode.attempt,
                        json.dumps(episode.details, sort_keys=True, separators=(",", ":")),
                        json.dumps(list(episode.evidence_paths), separators=(",", ":")),
                        episode.error_code,
                        episode.error_message,
                    ),
                )
            row = connection.execute(
                "SELECT * FROM recovery_episodes WHERE recovery_id = ?",
                (episode.recovery_id,),
            ).fetchone()
            assert row is not None
            return self._row_to_recovery(row)

    def get_recovery(self, recovery_id: str) -> RecoveryEpisode | None:
        recovery_id = normalize_uuid(recovery_id, "recovery_id")
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM recovery_episodes WHERE recovery_id = ?",
                (recovery_id,),
            ).fetchone()
            return self._row_to_recovery(row) if row is not None else None

    def list_recoveries(
        self,
        *,
        session_trace_id: str | None = None,
        owner_id: str | None = None,
        limit: int = 100,
    ) -> list[RecoveryEpisode]:
        limit = max(1, min(int(limit), 1000))
        conditions: list[str] = []
        parameters: list[Any] = []
        if session_trace_id is not None:
            conditions.append("session_trace_id = ?")
            parameters.append(normalize_uuid(session_trace_id, "session_trace_id"))
        if owner_id is not None:
            conditions.append("owner_id = ?")
            parameters.append(owner_id)
        where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
        parameters.append(limit)
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                f"""
                SELECT * FROM recovery_episodes {where}
                ORDER BY started_at DESC, recovery_id DESC LIMIT ?
                """,
                parameters,
            ).fetchall()
            return [self._row_to_recovery(row) for row in rows]

    @staticmethod
    def _row_to_recovery(row: sqlite3.Row) -> RecoveryEpisode:
        return RecoveryEpisode.from_dict(
            {
                "recovery_id": row["recovery_id"],
                "owner_type": row["owner_type"],
                "owner_id": row["owner_id"],
                "session_trace_id": row["session_trace_id"],
                "operation_trace_id": row["operation_trace_id"],
                "span_id": row["span_id"],
                "traceparent": row["traceparent"],
                "cause": row["cause"],
                "outcome": row["outcome"],
                "started_at": float(row["started_at"]),
                "finished_at": (
                    float(row["finished_at"])
                    if row["finished_at"] is not None
                    else None
                ),
                "attempt": int(row["attempt"]),
                "details": loads_bounded(
                    row["details_json"], maximum_bytes=256 * 1024
                ),
                "evidence_paths": loads_bounded(
                    row["evidence_paths_json"], maximum_bytes=256 * 1024
                ),
                "error_code": row["error_code"],
                "error_message": row["error_message"],
            }
        )

    def expire_due(self, *, now: float | None = None) -> list[LiveSession]:
        timestamp = utc_timestamp() if now is None else now
        expired: list[LiveSession] = []
        for session in self.list_sessions(limit=500):
            if session.status.terminal or session.lease_expires_at > timestamp:
                continue
            try:
                expired.append(
                    self.transition(
                        session.id,
                        LiveSessionStatus.EXPIRED,
                        error_code="lease_expired",
                        error_message="live session lease expired",
                    )
                )
            except LiveStoreError:
                continue
        return expired

    def recover_nonterminal(self) -> list[LiveSession]:
        recovered: list[LiveSession] = []
        for session in self.list_sessions(limit=500):
            if session.status.terminal:
                continue
            try:
                recovered.append(
                    self.transition(
                        session.id,
                        LiveSessionStatus.FAILED,
                        error_code="agent_restarted",
                        error_message="agent restarted during live session",
                    )
                )
            except LiveStoreError:
                continue
        return recovered

    def delete_expired_sessions(self, retention_hours: int) -> list[LiveSession]:
        cutoff = utc_timestamp() - max(1, retention_hours) * 3600
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                """
                SELECT * FROM live_sessions
                WHERE status IN ('closed', 'failed', 'expired', 'cancelled')
                  AND updated_at < ? ORDER BY updated_at ASC
                """,
                (cutoff,),
            ).fetchall()
            sessions = [self._row_to_session(row) for row in rows]
            if sessions:
                connection.executemany(
                    "DELETE FROM live_sessions WHERE id = ?",
                    [(session.id,) for session in sessions],
                )
            return sessions
