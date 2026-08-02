from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.models import JobRequest, JobStatus
from faceswap_qa_agent.service import AgentService


class ServiceLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        ios = root / "ios"
        ios.mkdir()
        (ios / "App.xcodeproj").mkdir()
        config_path = root / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "api": {"token_file": "state/token"},
                    "paths": {
                        "ios_root": "ios",
                        "project": "App.xcodeproj",
                        "database": "state/jobs.sqlite3",
                        "artifacts": "artifacts",
                        "logs": "logs",
                    },
                    "xcode": {"scheme": "App-QA", "test_plan": "App-QA"},
                    "limits": {
                        "default_timeout_seconds": 30,
                        "maximum_timeout_seconds": 60,
                        "maximum_retries": 2,
                        "retention_hours": 1,
                    },
                }
            ),
            encoding="utf-8",
        )
        self.service = AgentService(AgentConfig.load(config_path))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, retries: int = 1) -> JobRequest:
        return JobRequest.from_dict(
            {
                "target": {"kind": "simulator", "name": "iPhone"},
                "timeout_seconds": 30,
                "max_retries": retries,
            },
            maximum_timeout=60,
            maximum_retries=2,
        )

    def test_verified_stale_xcodebuild_is_terminated(self) -> None:
        command = (
            f"xcodebuild test -project {self.service.config.paths.project_path} "
            f"-scheme {self.service.config.xcode.scheme}"
        )
        completed = subprocess.CompletedProcess(["ps"], 0, command + "\n", "")
        with patch("faceswap_qa_agent.service.subprocess.run", return_value=completed), patch(
            "faceswap_qa_agent.service.os.killpg"
        ) as kill:
            self.assertTrue(self.service._terminate_verified_stale_process(123))
        kill.assert_called_once()

    def test_unrelated_reused_pid_is_not_terminated(self) -> None:
        completed = subprocess.CompletedProcess(["ps"], 0, "python unrelated.py\n", "")
        with patch("faceswap_qa_agent.service.subprocess.run", return_value=completed), patch(
            "faceswap_qa_agent.service.os.killpg"
        ) as kill:
            self.assertFalse(self.service._terminate_verified_stale_process(123))
        kill.assert_not_called()

    def test_recovery_requeues_running_job(self) -> None:
        job, _ = self.service.store.create_job(self.request())
        running = self.service.store.claim_next_job()
        assert running is not None
        self.service.store.set_pid(job.id, 123)
        with patch.object(self.service, "_terminate_verified_stale_process", return_value=True):
            self.service._recover_running_jobs()
        recovered = self.service.store.get_job(job.id)
        assert recovered is not None
        self.assertEqual(recovered.status, JobStatus.QUEUED)
        self.assertEqual(recovered.error_code, "agent_restarted")

    def test_prune_removes_terminal_artifact_directory(self) -> None:
        job, _ = self.service.store.create_job(self.request(retries=0))
        self.service.store.claim_next_job()
        self.service.store.complete_job(job.id, 0, None)
        artifact_root = self.service.config.paths.artifacts / job.id
        artifact_root.mkdir(parents=True)
        (artifact_root / "fixture").write_text("x", encoding="utf-8")
        with self.service.store._connection() as connection:
            connection.execute("UPDATE jobs SET updated_at = 0 WHERE id = ?", (job.id,))
        self.service._prune_expired()
        self.assertFalse(artifact_root.exists())
        self.assertIsNone(self.service.store.get_job(job.id))


if __name__ == "__main__":
    unittest.main()
