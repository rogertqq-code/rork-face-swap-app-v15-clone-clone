from __future__ import annotations

import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.models import JobRequest, JobStatus
from faceswap_qa_agent.service import AgentService


class IntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ios = self.root / "ios"
        self.ios.mkdir()
        (self.ios / "FaceSwapLiveAppV17.xcodeproj").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake_root = Path(__file__).parent / "fakes"
        for name in ("xcrun", "xcodebuild"):
            destination = self.bin / name
            destination.write_bytes((fake_root / name).read_bytes())
            destination.chmod(destination.stat().st_mode | stat.S_IXUSR)
        self.record = self.root / "xcodebuild-arguments.json"
        self.environment_record = self.root / "xcodebuild-environment.json"
        self.state = self.root / "transient-state"
        self.original_environment = {
            name: os.environ.get(name)
            for name in (
                "PATH",
                "FAKE_XCODEBUILD_MODE",
                "FAKE_XCODEBUILD_RECORD",
                "FAKE_XCODEBUILD_ENV_RECORD",
                "FAKE_XCODEBUILD_STATE",
            )
        }
        os.environ["PATH"] = f"{self.bin}:{os.environ.get('PATH', '')}"
        os.environ["FAKE_XCODEBUILD_RECORD"] = str(self.record)
        os.environ["FAKE_XCODEBUILD_ENV_RECORD"] = str(self.environment_record)
        os.environ["FAKE_XCODEBUILD_STATE"] = str(self.state)
        self.config_path = self.root / "config.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "api": {"host": "127.0.0.1", "port": 8765, "token_file": "state/token"},
                    "paths": {
                        "ios_root": "ios",
                        "project": "FaceSwapLiveAppV17.xcodeproj",
                        "database": "state/jobs.sqlite3",
                        "artifacts": "artifacts",
                        "logs": "logs",
                    },
                    "xcode": {
                        "scheme": "FaceSwapLiveAppV17-QA",
                        "test_plan": "FaceSwapLiveAppV17-QA",
                        "default_simulator_name": "iPhone 16 Pro",
                    },
                    "limits": {
                        "default_timeout_seconds": 10,
                        "maximum_timeout_seconds": 30,
                        "maximum_retries": 2,
                        "kill_grace_seconds": 1,
                    },
                }
            ),
            encoding="utf-8",
        )
        self.service = AgentService(AgentConfig.load(self.config_path))
        self.service.start(start_http=False)

    def tearDown(self) -> None:
        self.service.stop()
        for name, value in self.original_environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        self.temporary.cleanup()

    def submit(self, kind: str, *, retries: int = 0, timeout: int = 10):
        request = JobRequest.from_dict(
            {
                "target": {"kind": kind, "name": "iPhone 16 Pro" if kind == "simulator" else None},
                "timeout_seconds": timeout,
                "max_retries": retries,
            },
            maximum_timeout=30,
            maximum_retries=2,
        )
        return self.service.submit(request)[0]

    def wait_terminal(self, job_id: str, timeout: float = 10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            job = self.service.store.get_job(job_id)
            if job is not None and job.status.terminal:
                return job
            time.sleep(0.05)
        self.fail(f"job {job_id} did not reach a terminal state")

    def wait_evidence(self, job_id: str, timeout: float = 5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            artifacts = self.service.store.get_artifacts(job_id)
            bundles = [item for item in artifacts if item.kind == "trace-evidence-bundle"]
            if bundles:
                return bundles[0], artifacts
            time.sleep(0.05)
        self.fail(f"job {job_id} did not retain automatic trace evidence")

    def test_simulator_success_retains_xcresult_and_destination(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "success"
        job = self.wait_terminal(self.submit("simulator").id)
        self.assertEqual(job.status, JobStatus.SUCCEEDED)
        arguments = json.loads(self.record.read_text())
        self.assertIn("Simulator", arguments)
        self.assertIn("platform=iOS Simulator,id=SIMULATOR-FAKE-18", arguments)
        bundle, artifacts = self.wait_evidence(job.id)
        self.assertTrue(any(item.kind == "xcresult" and item.byte_size > 0 for item in artifacts))
        self.assertTrue(any(item.kind == "json" and item.path.endswith("trace_context.json") for item in artifacts))
        self.assertEqual(bundle.session_trace_id, job.request.session_trace_id)
        self.assertTrue((self.config_path.parent / bundle.path).is_file() or (self.service.config.paths.artifacts / bundle.path).is_file())
        self.assertTrue(all(item.session_trace_id == job.request.session_trace_id for item in artifacts))

        environment = json.loads(self.environment_record.read_text())
        self.assertEqual(environment["FACESWAP_QA_JOB_ID"], job.id)
        self.assertEqual(environment["FACESWAP_QA_RUN_ID"], job.request.run_id)
        self.assertEqual(
            environment["FACESWAP_QA_SESSION_TRACE_ID"],
            job.request.session_trace_id,
        )
        self.assertEqual(environment["FACESWAP_QA_OPERATION_TRACE_ID"], job.id)
        self.assertEqual(len(environment["FACESWAP_QA_SPAN_ID"]), 16)
        root_hex = job.request.session_trace_id.replace("-", "")
        self.assertTrue(environment["FACESWAP_QA_TRACEPARENT"].startswith(f"00-{root_hex}-"))

    def test_cable_success_uses_udid_and_provisioning(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "success"
        request = JobRequest.from_dict(
            {
                "target": {"kind": "cable", "udid": "00008110-FAKECABLE"},
                "timeout_seconds": 10,
            },
            maximum_timeout=30,
        )
        job = self.wait_terminal(self.service.submit(request)[0].id)
        self.assertEqual(job.status, JobStatus.SUCCEEDED)
        arguments = json.loads(self.record.read_text())
        self.assertIn("Cable Device", arguments)
        self.assertIn("platform=iOS,id=00008110-FAKECABLE", arguments)
        self.assertIn("-allowProvisioningUpdates", arguments)

    def test_transient_disconnect_retries_then_succeeds(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "transient_once"
        job = self.wait_terminal(self.submit("simulator", retries=1).id)
        self.assertEqual(job.status, JobStatus.SUCCEEDED)
        self.assertEqual(job.attempt, 2)
        event_types = [event["type"] for event in self.service.store.get_events(job.id)]
        self.assertIn("retry_queued", event_types)

    def test_provisioning_failure_is_not_retried(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "provisioning_failure"
        job = self.wait_terminal(self.submit("cable", retries=2).id)
        self.assertEqual(job.status, JobStatus.FAILED)
        self.assertEqual(job.attempt, 1)
        self.assertEqual(job.error_code, "provisioning_failed")

    def test_hanging_process_times_out(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "sleep"
        job = self.wait_terminal(self.submit("simulator", timeout=1).id, timeout=8)
        self.assertEqual(job.status, JobStatus.FAILED)
        self.assertEqual(job.error_code, "timeout")

    def test_running_process_is_cancelled(self) -> None:
        os.environ["FAKE_XCODEBUILD_MODE"] = "sleep"
        submitted = self.submit("simulator", timeout=20)
        deadline = time.time() + 5
        while time.time() < deadline:
            job = self.service.store.get_job(submitted.id)
            if job is not None and job.status == JobStatus.RUNNING and job.pid:
                break
            time.sleep(0.05)
        else:
            self.fail("job never began running")
        self.service.cancel(submitted.id)
        cancelled = self.wait_terminal(submitted.id)
        self.assertEqual(cancelled.status, JobStatus.CANCELLED)


if __name__ == "__main__":
    unittest.main()
