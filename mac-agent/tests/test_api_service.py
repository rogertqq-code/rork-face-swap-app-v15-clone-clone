from __future__ import annotations

import hashlib
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from faceswap_qa_agent.api import RequestError, _live_error_status, _validate_json_complexity
from faceswap_qa_agent.config import AgentConfig, ApiConfig, LimitsConfig, PathsConfig, XcodeConfig
from faceswap_qa_agent.models import Artifact, DeviceInfo, RunResult, TargetKind
from faceswap_qa_agent.recovery import RecoveryCause, RecoveryEpisode, RecoveryOutcome
from faceswap_qa_agent.service import AgentService


class StubDiscovery:
    def list_devices(self):
        return [
            DeviceInfo(
                kind=TargetKind.CABLE,
                udid="00008110-TEST",
                name="QA iPhone",
                os_version="18.1",
                device_type="iPhone",
                ready=True,
            )
        ]


class StubRunner:
    def __init__(self, block: bool = False) -> None:
        self.block = block
        self.started = threading.Event()
        self.release = threading.Event()

    def run(self, job):
        self.started.set()
        if self.block:
            self.release.wait(5)
        return RunResult(True, 0, None, None, "fixture/result.xcresult", ())


class APITests(unittest.TestCase):
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
        self.runner = StubRunner()
        self.service = AgentService(
            self.config, discovery=StubDiscovery(), runner=self.runner  # type: ignore[arg-type]
        )
        self.service.start()
        assert self.service.address is not None
        self.base = f"http://{self.service.address[0]}:{self.service.address[1]}/api/v1"

    def tearDown(self) -> None:
        self.runner.release.set()
        self.service.stop()
        self.temporary.cleanup()

    def request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        *,
        token: str | None = None,
        idempotency: str | None = None,
    ):
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"Authorization": f"Bearer {token or self.service.token}"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if idempotency:
            headers["Idempotency-Key"] = idempotency
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())

    def job_payload(self):
        return {
            "target": {"kind": "simulator", "name": "iPhone"},
            "timeout_seconds": 30,
        }

    def test_health_requires_authentication(self) -> None:
        request = urllib.request.Request(self.base + "/health")
        with self.assertRaises(urllib.error.HTTPError) as context:
            urllib.request.urlopen(request, timeout=5)
        self.assertEqual(context.exception.code, 401)
        status, payload = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(payload["worker_alive"])

    def test_devices(self) -> None:
        _, payload = self.request("GET", "/devices")
        self.assertEqual(payload["devices"][0]["udid"], "00008110-TEST")

    def test_create_is_idempotent_and_executes(self) -> None:
        status, first = self.request("POST", "/jobs", self.job_payload(), idempotency="repeat")
        self.assertEqual(status, 201)
        _, second = self.request("POST", "/jobs", self.job_payload(), idempotency="repeat")
        self.assertFalse(second["created"])
        self.assertEqual(first["job"]["id"], second["job"]["id"])
        job_id = first["job"]["id"]
        deadline = time.time() + 3
        while time.time() < deadline:
            _, document = self.request("GET", f"/jobs/{job_id}")
            if document["job"]["status"] == "succeeded":
                break
            time.sleep(0.02)
        self.assertEqual(document["job"]["status"], "succeeded")

    def test_trace_analytics_recovery_and_evidence_routes(self) -> None:
        _, created = self.request("POST", "/jobs", self.job_payload())
        job_id = created["job"]["id"]
        deadline = time.time() + 3
        while time.time() < deadline:
            job = self.service.store.get_job(job_id)
            if job is not None and job.status.terminal:
                break
            time.sleep(0.02)
        self.assertIsNotNone(job)
        assert job is not None
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
        self.service.trace_service.record_recovery(episode)

        status, trace = self.request("GET", f"/traces/{root}")
        self.assertEqual(status, 200)
        self.assertEqual(trace["trace"]["session_trace_id"], root)
        self.assertEqual(trace["trace"]["owner_type"], "job")

        _, events = self.request("GET", f"/traces/{root}/events?after=0&limit=10")
        self.assertTrue(events["events"])
        self.assertTrue(all(item["session_trace_id"] == root for item in events["events"]))
        _, analytics = self.request("GET", f"/traces/{root}/analytics")
        self.assertIn(analytics["analytics"]["qualification"]["status"], {"pass", "incomplete"})
        _, recoveries = self.request("GET", f"/traces/{root}/recoveries")
        self.assertEqual(
            recoveries["recovery_episodes"][0]["recovery_id"],
            episode.recovery_id,
        )

        _, trace_index = self.request(
            "GET",
            "/traces?owner_type=job&status=succeeded&offset=0&limit=1",
        )
        self.assertEqual(trace_index["total"], 1)
        self.assertEqual(trace_index["traces"][0]["session_trace_id"], root)
        _, recovery_index = self.request(
            "GET",
            f"/recovery?session_trace_id={root}&cause=stale_process&outcome=recovered",
        )
        self.assertEqual(recovery_index["total"], 1)
        _, recovery_detail = self.request(
            "GET", f"/recovery/{episode.recovery_id}"
        )
        self.assertEqual(recovery_detail["recovery"]["session_trace_id"], root)

        evidence_status, evidence = self.request("POST", f"/traces/{root}/evidence")
        self.assertEqual(evidence_status, 201)
        self.assertEqual(evidence["evidence"]["manifest"]["session_trace_id"], root)
        self.assertTrue(Path(evidence["evidence"]["export"]["path"]).is_file())
        _, metadata = self.request("GET", f"/traces/{root}/evidence")
        self.assertEqual(metadata["evidence"]["bundle"]["kind"], "trace-evidence-bundle")

        download_request = urllib.request.Request(
            self.base + f"/traces/{root}/evidence/download",
            headers={"Authorization": f"Bearer {self.service.token}"},
            method="GET",
        )
        with urllib.request.urlopen(download_request, timeout=5) as response:
            bundle = response.read()
            self.assertEqual(response.status, 200)
            self.assertEqual(int(response.headers["Content-Length"]), len(bundle))
            self.assertEqual(
                response.headers["X-Content-SHA256"],
                hashlib.sha256(bundle).hexdigest(),
            )
            self.assertEqual(response.headers["Cache-Control"], "no-store")

        with self.assertRaises(urllib.error.HTTPError) as invalid_filter:
            self.request("GET", "/traces?owner_type=invalid")
        self.assertEqual(invalid_filter.exception.code, 400)
        unknown = "12345678-1234-4234-9234-1234567890ab"
        with self.assertRaises(urllib.error.HTTPError) as missing:
            self.request("GET", f"/traces/{unknown}")
        self.assertEqual(missing.exception.code, 404)
        with self.assertRaises(urllib.error.HTTPError) as missing_recovery:
            self.request("GET", f"/recovery/{unknown}")
        self.assertEqual(missing_recovery.exception.code, 404)

    def test_rejects_arbitrary_command_field(self) -> None:
        payload = self.job_payload()
        payload["command"] = ["rm", "-rf", "/"]
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.request("POST", "/jobs", payload)
        self.assertEqual(context.exception.code, 400)

    def test_invalid_token(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.request("GET", "/health", token="x" * 40)
        self.assertEqual(context.exception.code, 401)

    def test_list_and_artifacts(self) -> None:
        _, created = self.request("POST", "/jobs", self.job_payload())
        job_id = created["job"]["id"]
        deadline = time.time() + 3
        while time.time() < deadline:
            job = self.service.store.get_job(job_id)
            if job is not None and job.status.terminal:
                break
            time.sleep(0.02)
        self.service.store.replace_artifacts(
            job_id, [Artifact("x/result.xcresult", "xcresult", 1, "a" * 64)]
        )
        _, listed = self.request("GET", "/jobs?limit=10")
        self.assertTrue(any(job["id"] == job_id for job in listed["jobs"]))
        _, artifacts = self.request("GET", f"/jobs/{job_id}/artifacts")
        self.assertIn(
            "xcresult",
            {item["kind"] for item in artifacts["artifacts"]},
        )

    def test_cancel_running_job(self) -> None:
        self.runner.block = True
        _, created = self.request("POST", "/jobs", self.job_payload())
        job_id = created["job"]["id"]
        self.assertTrue(self.runner.started.wait(2))
        _, cancelled = self.request("POST", f"/jobs/{job_id}/cancel")
        self.assertTrue(cancelled["job"]["cancel_requested"])
        self.runner.release.set()
        deadline = time.time() + 3
        while time.time() < deadline:
            _, document = self.request("GET", f"/jobs/{job_id}")
            if document["job"]["status"] == "cancelled":
                break
            time.sleep(0.02)
        self.assertEqual(document["job"]["status"], "cancelled")

    def test_invalid_json_and_media_type(self) -> None:
        bad_json = urllib.request.Request(
            self.base + "/jobs",
            data=b"{",
            headers={
                "Authorization": f"Bearer {self.service.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as invalid:
            urllib.request.urlopen(bad_json, timeout=5)
        self.assertEqual(invalid.exception.code, 400)

        text = urllib.request.Request(
            self.base + "/jobs",
            data=b"{}",
            headers={
                "Authorization": f"Bearer {self.service.token}",
                "Content-Type": "text/plain",
            },
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as media:
            urllib.request.urlopen(text, timeout=5)
        self.assertEqual(media.exception.code, 415)

    def test_json_complexity_and_live_runtime_error_mapping(self) -> None:
        deep: dict = {"leaf": True}
        for _ in range(40):
            deep = {"nested": deep}
        request = urllib.request.Request(
            self.base + "/jobs",
            data=json.dumps(deep).encode(),
            headers={
                "Authorization": f"Bearer {self.service.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as too_deep:
            urllib.request.urlopen(request, timeout=5)
        self.assertEqual(too_deep.exception.code, 400)
        error = json.loads(too_deep.exception.read())
        self.assertEqual(error["error"]["code"], "json_too_deep")

        with self.assertRaises(RequestError) as too_complex:
            _validate_json_complexity({"values": list(range(10001))})
        self.assertEqual(too_complex.exception.code, "json_too_complex")

        for code in (
            "appium_plugin_version_mismatch",
            "remotexpc_missing",
            "remotexpc_version_mismatch",
        ):
            self.assertEqual(int(_live_error_status(code)), 503)

    def test_oversized_body_and_invalid_query(self) -> None:
        oversized = urllib.request.Request(
            self.base + "/jobs",
            data=b"x" * (self.config.limits.max_request_bytes + 1),
            headers={
                "Authorization": f"Bearer {self.service.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as large:
            urllib.request.urlopen(oversized, timeout=5)
        self.assertEqual(large.exception.code, 413)
        with self.assertRaises(urllib.error.HTTPError) as query:
            self.request("GET", "/jobs?limit=10000")
        self.assertEqual(query.exception.code, 400)

    def test_log_endpoint_is_bounded_and_offset_aware(self) -> None:
        _, created = self.request("POST", "/jobs", self.job_payload())
        job_id = created["job"]["id"]
        log_dir = self.config.paths.artifacts / job_id / "attempt-01"
        log_dir.mkdir(parents=True, exist_ok=True)
        (log_dir / "xcodebuild.log").write_text("abcdef", encoding="utf-8")
        _, result = self.request("GET", f"/jobs/{job_id}/log?offset=2&limit=3")
        self.assertEqual(result["log"]["data"], "cde")
        self.assertEqual(result["log"]["next_offset"], 5)
        self.assertFalse(result["log"]["eof"])


if __name__ == "__main__":
    unittest.main()
