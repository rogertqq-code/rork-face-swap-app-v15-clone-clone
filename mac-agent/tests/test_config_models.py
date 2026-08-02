from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.models import (
    DeviceInfo,
    JobRequest,
    JobStatus,
    TargetKind,
    is_valid_transition,
)


class ConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_config(self, overrides: dict | None = None) -> Path:
        data = {
            "api": {"host": "127.0.0.1", "port": 8765, "token_file": "state/token"},
            "paths": {
                "ios_root": "ios",
                "project": "App.xcodeproj",
                "database": "state/jobs.sqlite3",
                "artifacts": "artifacts",
                "logs": "logs",
            },
            "xcode": {"scheme": "QA", "test_plan": "QA", "default_simulator_name": "iPhone"},
            "limits": {"default_timeout_seconds": 30, "maximum_timeout_seconds": 60},
        }
        if overrides:
            for section, values in overrides.items():
                if isinstance(values, dict):
                    data.setdefault(section, {}).update(values)
                else:
                    data[section] = values
        path = self.root / "config.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_load_resolves_paths_and_creates_directories(self) -> None:
        config = AgentConfig.load(self.write_config())
        self.assertEqual(config.paths.ios_root, self.root / "ios")
        self.assertEqual(config.paths.project_path, self.root / "ios" / "App.xcodeproj")
        config.ensure_directories()
        self.assertTrue(config.paths.artifacts.is_dir())
        self.assertTrue(config.paths.database.parent.is_dir())

    def test_rejects_non_loopback_host(self) -> None:
        with self.assertRaisesRegex(ValueError, "loopback"):
            AgentConfig.load(self.write_config({"api": {"host": "0.0.0.0"}}))

    def test_rejects_project_path(self) -> None:
        with self.assertRaisesRegex(ValueError, "basename"):
            AgentConfig.load(self.write_config({"paths": {"project": "../App.xcodeproj"}}))

    def test_preinstalled_wda_requires_explicit_bundle_identity(self) -> None:
        with self.assertRaisesRegex(ValueError, "updated_bundle_id"):
            AgentConfig.load(
                self.write_config({"wda": {"use_preinstalled": True}})
            )
        config = AgentConfig.load(
            self.write_config(
                {
                    "wda": {
                        "use_preinstalled": True,
                        "updated_bundle_id": "com.example.WebDriverAgentRunner",
                    },
                    "appium": {"remotexpc_version": "5.13.2"},
                }
            )
        )
        self.assertTrue(config.wda.use_preinstalled)
        self.assertEqual(
            config.wda.updated_bundle_id, "com.example.WebDriverAgentRunner"
        )
        self.assertEqual(config.appium.remotexpc_version, "5.13.2")
        self.assertEqual(config.public_dict()["appium"]["remotexpc_version"], "5.13.2")

    def test_rejects_timeout_inversion(self) -> None:
        with self.assertRaises(ValueError):
            AgentConfig.load(
                self.write_config(
                    {"limits": {"default_timeout_seconds": 100, "maximum_timeout_seconds": 60}}
                )
            )


class ModelTests(unittest.TestCase):
    def valid_payload(self) -> dict:
        return {
            "target": {"kind": "simulator", "name": "iPhone", "os": "latest"},
            "only_testing": ["Target/TestClass/testMethod"],
            "skip_testing": [],
            "timeout_seconds": 30,
            "max_retries": 1,
            "labels": {"source": "unit"},
        }

    def test_request_generates_uuid_and_round_trips(self) -> None:
        request = JobRequest.from_dict(self.valid_payload(), maximum_timeout=60, maximum_retries=2)
        restored = JobRequest.from_dict(request.to_dict(), maximum_timeout=60, maximum_retries=2)
        self.assertEqual(restored, request)
        self.assertEqual(request.target.kind, TargetKind.SIMULATOR)

    def test_rejects_unknown_fields(self) -> None:
        payload = self.valid_payload()
        payload["command"] = "rm -rf"
        with self.assertRaisesRegex(ValueError, "unsupported"):
            JobRequest.from_dict(payload)

    def test_rejects_invalid_test_identifier(self) -> None:
        payload = self.valid_payload()
        payload["only_testing"] = ["Target/Test;touch /tmp/x"]
        with self.assertRaisesRegex(ValueError, "invalid test identifier"):
            JobRequest.from_dict(payload)

    def test_rejects_retry_over_limit(self) -> None:
        payload = self.valid_payload()
        payload["max_retries"] = 3
        with self.assertRaisesRegex(ValueError, "between"):
            JobRequest.from_dict(payload, maximum_retries=2)

    def test_transition_contract(self) -> None:
        self.assertTrue(is_valid_transition(JobStatus.QUEUED, JobStatus.RUNNING))
        self.assertTrue(is_valid_transition(JobStatus.RUNNING, JobStatus.QUEUED))
        self.assertFalse(is_valid_transition(JobStatus.SUCCEEDED, JobStatus.RUNNING))

    def test_device_serialization(self) -> None:
        device = DeviceInfo(
            kind=TargetKind.CABLE,
            udid="00008110-TEST",
            name="QA iPhone",
            os_version="18.1",
            device_type="iPhone",
            ready=False,
            readiness_reasons=("developer_mode=disabled",),
        )
        self.assertEqual(device.to_dict()["readiness_reasons"], ["developer_mode=disabled"])


if __name__ == "__main__":
    unittest.main()
