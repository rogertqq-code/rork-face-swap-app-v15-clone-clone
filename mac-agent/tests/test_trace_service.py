from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from faceswap_qa_agent.config import (
    AgentConfig,
    ApiConfig,
    LimitsConfig,
    PathsConfig,
    XcodeConfig,
)
from faceswap_qa_agent.live_store import LiveStore
from faceswap_qa_agent.models import Artifact, JobRequest
from faceswap_qa_agent.recovery import RecoveryCause, RecoveryEpisode, RecoveryOutcome
from faceswap_qa_agent.store import JobStore
from faceswap_qa_agent.trace_service import TraceService, TraceServiceError


class TraceServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        ios = root / "ios"
        ios.mkdir()
        (ios / "App.xcodeproj").mkdir()
        self.config = AgentConfig(
            api=ApiConfig("127.0.0.1", 0, root / "state" / "token"),
            paths=PathsConfig(
                ios,
                "App.xcodeproj",
                root / "state" / "jobs.sqlite3",
                root / "artifacts",
                root / "logs",
            ),
            xcode=XcodeConfig("App-QA", "App-QA", "", "iPhone"),
            limits=LimitsConfig(4096, 30, 60, 2, 168, 1),
            config_path=root / "config.json",
        )
        self.config.ensure_directories()
        self.jobs = JobStore(self.config.paths.database)
        self.live = LiveStore(self.config.paths.database)
        self.traces = TraceService(self.config, self.jobs, self.live)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _completed_job(self):
        request = JobRequest.from_dict(
            {"target": {"kind": "simulator", "name": "iPhone"}},
            default_timeout=30,
            maximum_timeout=60,
            maximum_retries=1,
        )
        job, _ = self.jobs.create_job(request)
        running = self.jobs.claim_next_job()
        self.assertIsNotNone(running)
        artifact_path = Path(job.id) / "attempt-1" / "result.xcresult"
        absolute = self.config.paths.artifacts / artifact_path
        absolute.parent.mkdir(parents=True)
        absolute.write_bytes(b"deterministic-xcresult")
        artifact = Artifact(
            path=artifact_path.as_posix(),
            kind="xcresult",
            byte_size=absolute.stat().st_size,
            sha256=hashlib.sha256(absolute.read_bytes()).hexdigest(),
            content_type="application/octet-stream",
            provenance="xcodebuild",
        )
        self.jobs.replace_artifacts(job.id, [artifact])
        self.assertTrue(self.jobs.complete_job(job.id, 0, artifact.path))
        completed = self.jobs.get_job(job.id)
        self.assertIsNotNone(completed)
        return completed

    def test_trace_document_recovery_analytics_and_deterministic_export(self) -> None:
        job = self._completed_job()
        root = job.request.session_trace_id
        started = RecoveryEpisode.start(
            owner_type="job",
            owner_id=job.id,
            session_trace_id=root,
            cause=RecoveryCause.STALE_PROCESS,
            started_at=job.created_at + 0.1,
            details={"authorization": "Bearer secret", "pid": 41},
        )
        self.traces.record_recovery(started)
        finished = started.finish(
            outcome=RecoveryOutcome.RECOVERED,
            finished_at=job.created_at + 0.2,
            details={"replacement_pid": 42},
        )
        self.traces.record_recovery(finished)

        document = self.traces.document(root)
        self.assertEqual(document["session_trace_id"], root)
        self.assertEqual(document["owner_type"], "job")
        self.assertEqual(document["recovery_episodes"][0]["outcome"], "recovered")
        self.assertEqual(
            document["analytics"]["qualification"]["status"],
            "pass",
            document["analytics"],
        )
        self.assertTrue(document["analytics"]["invariants"]["root_trace_continuity"]["passed"])
        self.assertTrue(all(event["session_trace_id"] == root for event in document["events"]))

        first = self.traces.export_evidence(root)
        first_bytes = Path(first["export"]["path"]).read_bytes()
        second = self.traces.export_evidence(root)
        second_bytes = Path(second["export"]["path"]).read_bytes()
        self.assertEqual(first_bytes, second_bytes)
        self.assertEqual(first["export"]["sha256"], second["export"]["sha256"])
        self.assertEqual(first["manifest"]["status"], "complete")
        self.assertEqual(first["manifest"]["session_trace_id"], root)
        bundle = [
            item
            for item in self.jobs.get_artifacts(job.id)
            if item.kind == "trace-evidence-bundle"
        ]
        self.assertEqual(len(bundle), 1)
        self.assertEqual(bundle[0].session_trace_id, root)
        self.assertEqual(bundle[0].redaction_state, "manifest_redacted")

    def test_indexes_recovery_lookup_and_verified_bundle(self) -> None:
        job = self._completed_job()
        root = job.request.session_trace_id
        episode = RecoveryEpisode.start(
            owner_type="job",
            owner_id=job.id,
            session_trace_id=root,
            cause=RecoveryCause.STALE_PROCESS,
            started_at=job.created_at + 0.1,
        ).finish(
            outcome=RecoveryOutcome.RECOVERED,
            finished_at=job.created_at + 0.2,
        )
        self.traces.record_recovery(episode)
        exported = self.traces.export_evidence(root)

        index = self.traces.list_traces(
            owner_type="job",
            status="succeeded",
            since=job.created_at - 1,
            until=job.updated_at + 1,
            offset=0,
            limit=1,
        )
        self.assertEqual(index["total"], 1)
        self.assertEqual(index["traces"][0]["session_trace_id"], root)
        self.assertEqual(index["traces"][0]["evidence"]["sha256"], exported["export"]["sha256"])
        self.assertIsNone(index["next_offset"])

        recoveries = self.traces.list_recoveries(
            session_trace_id=root,
            owner_type="job",
            cause="stale_process",
            outcome="recovered",
            offset=0,
            limit=1,
        )
        self.assertEqual(recoveries["total"], 1)
        self.assertEqual(
            recoveries["recovery_episodes"][0]["recovery_id"],
            episode.recovery_id,
        )
        self.assertEqual(
            self.traces.recovery(episode.recovery_id)["session_trace_id"],
            root,
        )

        path, record = self.traces.evidence_bundle(root)
        self.assertEqual(path.read_bytes(), Path(exported["export"]["path"]).read_bytes())
        self.assertEqual(record.sha256, exported["export"]["sha256"])

        target = path.with_name("evidence-real.tar.gz")
        path.rename(target)
        path.symlink_to(target.name)
        with self.assertRaises(TraceServiceError) as symlink:
            self.traces.evidence_bundle(root)
        self.assertEqual(symlink.exception.code, "artifact_symlink_rejected")

    def test_unknown_trace_is_rejected(self) -> None:
        with self.assertRaises(TraceServiceError) as context:
            self.traces.document("12345678-1234-4234-9234-1234567890ab")
        self.assertEqual(context.exception.code, "trace_not_found")
        with self.assertRaises(TraceServiceError) as recovery:
            self.traces.recovery("12345678-1234-4234-9234-1234567890ab")
        self.assertEqual(recovery.exception.code, "recovery_not_found")


if __name__ == "__main__":
    unittest.main()
