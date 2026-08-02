from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from faceswap_qa_agent.models import Artifact, JobRequest, JobStatus
from faceswap_qa_agent.store import JobStore


def request(*, retries: int = 0) -> JobRequest:
    return JobRequest.from_dict(
        {
            "target": {"kind": "simulator", "name": "iPhone"},
            "timeout_seconds": 30,
            "max_retries": retries,
        },
        maximum_timeout=60,
        maximum_retries=3,
    )


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.store = JobStore(Path(self.temporary.name) / "jobs.sqlite3")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_idempotent_create(self) -> None:
        first, created = self.store.create_job(request(), "same")
        second, second_created = self.store.create_job(request(), "same")
        self.assertTrue(created)
        self.assertFalse(second_created)
        self.assertEqual(first.id, second.id)

    def test_claim_is_fifo_and_increments_attempt(self) -> None:
        first, _ = self.store.create_job(request())
        second, _ = self.store.create_job(request())
        claimed = self.store.claim_next_job()
        self.assertIsNotNone(claimed)
        assert claimed is not None
        self.assertEqual(claimed.id, first.id)
        self.assertEqual(claimed.status, JobStatus.RUNNING)
        self.assertEqual(claimed.attempt, 1)
        self.assertEqual(self.store.queue_depth(), 1)
        self.assertEqual(self.store.list_jobs(JobStatus.QUEUED)[0].id, second.id)

    def test_cancel_queued_is_terminal(self) -> None:
        job, _ = self.store.create_job(request())
        cancelled = self.store.request_cancel(job.id)
        assert cancelled is not None
        self.assertEqual(cancelled.status, JobStatus.CANCELLED)
        self.assertIsNone(self.store.claim_next_job())

    def test_cancel_running_sets_request_then_marks_terminal(self) -> None:
        job, _ = self.store.create_job(request())
        running = self.store.claim_next_job()
        assert running is not None
        pending = self.store.request_cancel(job.id)
        assert pending is not None
        self.assertEqual(pending.status, JobStatus.RUNNING)
        self.assertTrue(self.store.is_cancel_requested(job.id))
        self.assertTrue(self.store.mark_cancelled(job.id))
        self.assertEqual(self.store.get_job(job.id).status, JobStatus.CANCELLED)  # type: ignore[union-attr]

    def test_success_records_result(self) -> None:
        job, _ = self.store.create_job(request())
        self.store.claim_next_job()
        self.assertTrue(self.store.complete_job(job.id, 0, "job/attempt/result.xcresult"))
        result = self.store.get_job(job.id)
        assert result is not None
        self.assertEqual(result.status, JobStatus.SUCCEEDED)
        self.assertEqual(result.exit_code, 0)

    def test_transient_failure_retries_once(self) -> None:
        job, _ = self.store.create_job(request(retries=1))
        self.store.claim_next_job()
        retry = self.store.fail_or_retry_job(job.id, "timeout", "late")
        assert retry is not None
        self.assertEqual(retry.status, JobStatus.QUEUED)
        second = self.store.claim_next_job()
        assert second is not None
        failed = self.store.fail_or_retry_job(job.id, "timeout", "late")
        assert failed is not None
        self.assertEqual(failed.status, JobStatus.FAILED)

    def test_nontransient_failure_does_not_retry(self) -> None:
        job, _ = self.store.create_job(request(retries=2))
        self.store.claim_next_job()
        failed = self.store.fail_or_retry_job(job.id, "provisioning_failed", "bad signing")
        assert failed is not None
        self.assertEqual(failed.status, JobStatus.FAILED)

    def test_restart_recovery_requeues_with_budget(self) -> None:
        job, _ = self.store.create_job(request(retries=1))
        self.store.claim_next_job()
        recovered = self.store.recover_running_jobs()
        self.assertEqual(len(recovered), 1)
        self.assertEqual(self.store.get_job(job.id).status, JobStatus.QUEUED)  # type: ignore[union-attr]

    def test_events_and_artifacts(self) -> None:
        job, _ = self.store.create_job(request())
        artifact = Artifact("a/result.xcresult", "xcresult", 42, "f" * 64)
        self.store.replace_artifacts(job.id, [artifact])
        stored_artifacts = self.store.get_artifacts(job.id)
        self.assertEqual(len(stored_artifacts), 1)
        self.assertEqual(stored_artifacts[0].path, artifact.path)
        self.assertEqual(stored_artifacts[0].sha256, artifact.sha256)
        self.assertEqual(stored_artifacts[0].session_trace_id, job.request.session_trace_id)
        created_event = self.store.get_events(job.id)[0]
        self.assertEqual(created_event["type"], "created")
        self.assertEqual(created_event["session_trace_id"], job.request.session_trace_id)

    def test_retention_deletes_only_expired_terminal_jobs(self) -> None:
        queued, _ = self.store.create_job(request())
        terminal, _ = self.store.create_job(request())
        self.store.claim_next_job()
        self.store.complete_job(queued.id, 0, None)
        self.store.claim_next_job()
        self.store.complete_job(terminal.id, 0, None)
        with self.store._connection() as connection:  # Controlled test-only age adjustment.
            connection.execute("UPDATE jobs SET updated_at = 0 WHERE id = ?", (terminal.id,))
        deleted = self.store.delete_expired_jobs(1)
        self.assertEqual([job.id for job in deleted], [terminal.id])
        self.assertIsNotNone(self.store.get_job(queued.id))


if __name__ == "__main__":
    unittest.main()
