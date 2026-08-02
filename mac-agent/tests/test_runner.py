from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.models import DeviceInfo, JobRequest, TargetKind
from faceswap_qa_agent.runner import XcodeRunner
from faceswap_qa_agent.store import JobStore


class StubDiscovery:
    def __init__(self, kind: TargetKind) -> None:
        self.kind = kind
        self.booted = False

    def resolve(self, target, default_name):
        return DeviceInfo(
            kind=self.kind,
            udid="DEVICE-UDID" if self.kind == TargetKind.CABLE else "SIM-UDID",
            name="Target",
            os_version="18.0",
            device_type="iPhone" if self.kind == TargetKind.CABLE else "Simulator",
            ready=True,
            state="Booted" if self.kind == TargetKind.SIMULATOR else None,
        )

    def ensure_simulator_booted(self, device):
        self.booted = True


class FakeProcess:
    def __init__(self, command, *, stdout, exit_code=0, create_result=True, **kwargs) -> None:
        self.command = command
        self.pid = 424242
        self.exit_code = exit_code
        stdout.write("fake xcodebuild output\n")
        if create_result:
            result_path = Path(command[command.index("-resultBundlePath") + 1])
            result_path.mkdir(parents=True)
            (result_path / "Info.plist").write_text("fixture", encoding="utf-8")

    def poll(self):
        return self.exit_code

    def wait(self):
        return self.exit_code


class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        ios = self.root / "ios"
        ios.mkdir()
        (ios / "App.xcodeproj").mkdir()
        config_path = self.root / "config.json"
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
                        "kill_grace_seconds": 1,
                    },
                }
            ),
            encoding="utf-8",
        )
        self.config = AgentConfig.load(config_path)
        self.config.ensure_directories()
        self.store = JobStore(self.config.paths.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def create_running_job(self, kind: str, *, only: list[str] | None = None):
        request = JobRequest.from_dict(
            {
                "target": {"kind": kind, "name": "Target"},
                "only_testing": only or [],
                "timeout_seconds": 30,
            },
            maximum_timeout=60,
        )
        job, _ = self.store.create_job(request)
        running = self.store.claim_next_job()
        assert running is not None
        return running

    def test_simulator_command_and_success_artifacts(self) -> None:
        job = self.create_running_job("simulator", only=["UITests/Test/testFlow"])
        discovery = StubDiscovery(TargetKind.SIMULATOR)
        captured: list[list[str]] = []

        def factory(command, **kwargs):
            captured.append(command)
            return FakeProcess(command, **kwargs)

        result = XcodeRunner(
            self.config, self.store, discovery, popen_factory=factory
        ).run(job)
        self.assertTrue(result.success)
        self.assertTrue(discovery.booted)
        command = captured[0]
        self.assertIn("Simulator", command)
        self.assertIn("platform=iOS Simulator,id=SIM-UDID", command)
        self.assertIn("-only-testing:UITests/Test/testFlow", command)
        self.assertNotIn("-allowProvisioningUpdates", command)
        self.assertTrue(any(item.kind == "xcresult" for item in result.artifacts))

    def test_cable_command_allows_provisioning(self) -> None:
        job = self.create_running_job("cable")
        captured: list[list[str]] = []

        def factory(command, **kwargs):
            captured.append(command)
            return FakeProcess(command, **kwargs)

        result = XcodeRunner(
            self.config,
            self.store,
            StubDiscovery(TargetKind.CABLE),
            popen_factory=factory,
        ).run(job)
        self.assertTrue(result.success)
        self.assertIn("Cable Device", captured[0])
        self.assertIn("platform=iOS,id=DEVICE-UDID", captured[0])
        self.assertIn("-allowProvisioningUpdates", captured[0])

    def test_failure_is_classified(self) -> None:
        job = self.create_running_job("simulator")

        def factory(command, **kwargs):
            kwargs["stdout"].write("Provisioning profile does not include signing certificate\n")
            return FakeProcess(command, exit_code=65, create_result=False, **kwargs)

        result = XcodeRunner(
            self.config,
            self.store,
            StubDiscovery(TargetKind.SIMULATOR),
            popen_factory=factory,
        ).run(job)
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "provisioning_failed")

    def test_command_snapshot_is_json(self) -> None:
        job = self.create_running_job("simulator")
        result = XcodeRunner(
            self.config,
            self.store,
            StubDiscovery(TargetKind.SIMULATOR),
            popen_factory=lambda command, **kwargs: FakeProcess(command, **kwargs),
        ).run(job)
        command_artifact = next(item for item in result.artifacts if item.path.endswith("command.json"))
        command_path = self.config.paths.artifacts / command_artifact.path
        self.assertIn("xcodebuild", json.loads(command_path.read_text())["arguments"])


if __name__ == "__main__":
    unittest.main()
