from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path

from faceswap_qa_agent.live_models import LiveSessionRequest
from faceswap_qa_agent.live_store import LIVE_SCHEMA_VERSION, LiveStore
from faceswap_qa_agent.models import JobRequest
from faceswap_qa_agent.store import SCHEMA_VERSION, JobStore


class SchemaMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_job_schema_v1_migrates_trace_events_and_artifacts(self) -> None:
        path = self.root / "jobs-v1.sqlite3"
        run_id = str(uuid.uuid4())
        request = JobRequest.from_dict(
            {
                "run_id": run_id,
                "target": {"kind": "simulator", "name": "iPhone"},
            },
            default_timeout=30,
            maximum_timeout=60,
            maximum_retries=1,
        ).to_dict()
        request.pop("session_trace_id", None)
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                PRAGMA user_version = 1;
                CREATE TABLE jobs (
                    id TEXT PRIMARY KEY, status TEXT NOT NULL,
                    request_json TEXT NOT NULL, created_at REAL NOT NULL,
                    updated_at REAL NOT NULL, attempt INTEGER NOT NULL DEFAULT 0,
                    pid INTEGER, exit_code INTEGER, error_code TEXT,
                    error_message TEXT, cancel_requested INTEGER NOT NULL DEFAULT 0,
                    idempotency_key TEXT UNIQUE, result_path TEXT
                );
                CREATE TABLE events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL,
                    timestamp REAL NOT NULL, event_type TEXT NOT NULL,
                    details_json TEXT NOT NULL
                );
                CREATE TABLE artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL,
                    path TEXT NOT NULL, kind TEXT NOT NULL, byte_size INTEGER NOT NULL,
                    sha256 TEXT NOT NULL, created_at REAL NOT NULL,
                    UNIQUE(job_id, path)
                );
                """
            )
            connection.execute(
                "INSERT INTO jobs VALUES (?, 'succeeded', ?, 1, 2, 1, NULL, 0, NULL, NULL, 0, NULL, NULL)",
                ("legacy-job", json.dumps(request)),
            )
            connection.execute(
                "INSERT INTO events(job_id, timestamp, event_type, details_json) VALUES (?, 1.5, 'created', '{}')",
                ("legacy-job",),
            )
            connection.execute(
                "INSERT INTO artifacts(job_id, path, kind, byte_size, sha256, created_at) VALUES (?, 'legacy.xcresult', 'xcresult', 1, ?, 1.6)",
                ("legacy-job", "a" * 64),
            )

        store = JobStore(path)
        job = store.get_job("legacy-job")
        self.assertIsNotNone(job)
        assert job is not None
        self.assertEqual(job.request.session_trace_id, run_id)
        self.assertEqual(store.get_events(job.id)[0]["session_trace_id"], run_id)
        self.assertEqual(store.get_artifacts(job.id)[0].session_trace_id, run_id)
        with sqlite3.connect(path) as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
        reopened = JobStore(path)
        self.assertEqual(reopened.get_job("legacy-job").request.session_trace_id, run_id)  # type: ignore[union-attr]

    def test_live_schema_v1_migrates_trace_events_and_artifacts(self) -> None:
        path = self.root / "live-v1.sqlite3"
        run_id = str(uuid.uuid4())
        request = LiveSessionRequest.from_dict(
            {
                "run_id": run_id,
                "target": {"kind": "simulator", "name": "iPhone"},
                "lease_seconds": 60,
            },
            default_lease_seconds=60,
            maximum_lease_seconds=600,
        ).to_dict()
        request.pop("session_trace_id", None)
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                CREATE TABLE live_schema (singleton INTEGER PRIMARY KEY, version INTEGER NOT NULL);
                INSERT INTO live_schema VALUES (1, 1);
                CREATE TABLE live_sessions (
                    id TEXT PRIMARY KEY, request_json TEXT NOT NULL, status TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    lease_expires_at REAL NOT NULL, lease_token_hash TEXT NOT NULL,
                    idempotency_key TEXT UNIQUE, device_udid TEXT, device_name TEXT,
                    appium_session_id TEXT, appium_pid INTEGER, appium_port INTEGER,
                    wda_port INTEGER, mjpeg_port INTEGER, wda_url TEXT,
                    error_code TEXT, error_message TEXT, closed_at REAL
                );
                CREATE TABLE live_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                    timestamp REAL NOT NULL, category TEXT NOT NULL,
                    name TEXT NOT NULL, trace_id TEXT, payload_json TEXT NOT NULL
                );
                CREATE TABLE live_artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                    path TEXT NOT NULL, kind TEXT NOT NULL, byte_size INTEGER NOT NULL,
                    sha256 TEXT NOT NULL, created_at REAL NOT NULL,
                    UNIQUE(session_id, path)
                );
                CREATE TABLE live_ports (
                    port INTEGER PRIMARY KEY, kind TEXT NOT NULL,
                    session_id TEXT NOT NULL, created_at REAL NOT NULL,
                    UNIQUE(kind, session_id)
                );
                """
            )
            connection.execute(
                """
                INSERT INTO live_sessions(
                    id, request_json, status, created_at, updated_at,
                    lease_expires_at, lease_token_hash, closed_at
                ) VALUES (?, ?, 'closed', 1, 2, 2, ?, 2)
                """,
                ("legacy-live", json.dumps(request), "b" * 64),
            )
            operation = str(uuid.uuid4())
            connection.execute(
                "INSERT INTO live_events(session_id, timestamp, category, name, trace_id, payload_json) VALUES (?, 1.5, 'action', 'completed', ?, '{}')",
                ("legacy-live", operation),
            )
            connection.execute(
                "INSERT INTO live_artifacts(session_id, path, kind, byte_size, sha256, created_at) VALUES (?, 'live/legacy.png', 'screenshot', 1, ?, 1.6)",
                ("legacy-live", "c" * 64),
            )

        store = LiveStore(path)
        session = store.get_session("legacy-live")
        self.assertIsNotNone(session)
        assert session is not None
        self.assertEqual(session.request.session_trace_id, run_id)
        event = store.get_events(session.id)[0]
        self.assertEqual(event.session_trace_id, run_id)
        self.assertEqual(event.trace_id, operation)
        self.assertEqual(store.get_artifacts(session.id)[0].session_trace_id, run_id)
        with sqlite3.connect(path) as connection:
            version = connection.execute(
                "SELECT version FROM live_schema WHERE singleton = 1"
            ).fetchone()[0]
            self.assertEqual(version, LIVE_SCHEMA_VERSION)
        reopened = LiveStore(path)
        self.assertEqual(reopened.get_session("legacy-live").request.session_trace_id, run_id)  # type: ignore[union-attr]


if __name__ == "__main__":
    unittest.main()
