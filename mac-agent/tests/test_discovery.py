from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Sequence

from faceswap_qa_agent.discovery import DeviceDiscovery, DiscoveryError
from faceswap_qa_agent.models import Target, TargetKind


class FakeRunner:
    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.simctl = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                    {"name": "iPhone 16 Pro", "udid": "SIM-18", "state": "Shutdown", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
                    {"name": "iPhone 16 Pro", "udid": "SIM-17", "state": "Booted", "isAvailable": True}
                ],
            }
        }

    def run(self, arguments: Sequence[str], **kwargs) -> subprocess.CompletedProcess[str]:
        command = list(arguments)
        self.calls.append(command)
        if command[1:4] == ["devicectl", "list", "devices"]:
            output_path = Path(command[-1])
            output_path.write_text(
                json.dumps(
                    {
                        "result": {
                            "devices": [
                                {
                                    "identifier": "CORE-1",
                                    "hardwareProperties": {
                                        "udid": "00008110-TEST",
                                        "deviceType": "iPhone",
                                        "platform": "iOS",
                                        "reality": "physical",
                                    },
                                    "deviceProperties": {
                                        "name": "QA iPhone",
                                        "osVersionNumber": "18.1",
                                        "developerModeStatus": "enabled",
                                    },
                                    "connectionProperties": {
                                        "pairingState": "paired",
                                        "transportType": "wired",
                                    },
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            return subprocess.CompletedProcess(command, 0, "", "")
        if command[1:5] == ["simctl", "list", "devices", "available"]:
            return subprocess.CompletedProcess(command, 0, json.dumps(self.simctl), "")
        if command[1:3] == ["simctl", "boot"] or command[1:3] == ["simctl", "bootstatus"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        if command[1:4] == ["xctrace", "list", "devices"]:
            output = "== Devices ==\nQA iPhone (18.1) (00008110-TEST)\n== Simulators ==\n"
            return subprocess.CompletedProcess(command, 0, output, "")
        return subprocess.CompletedProcess(command, 1, "", "unexpected")


class DiscoveryTests(unittest.TestCase):
    def test_parses_devicectl_current_shape(self) -> None:
        runner = FakeRunner()
        discovery = DeviceDiscovery(runner)
        devices = discovery.list_physical_devices()
        self.assertEqual(len(devices), 1)
        self.assertTrue(devices[0].ready)
        self.assertEqual(devices[0].developer_mode, "enabled")
        self.assertEqual(devices[0].transport, "wired")

    def test_disabled_developer_mode_is_not_ready(self) -> None:
        data = {
            "devices": [
                {
                    "hardwareProperties": {"udid": "00008110-BAD", "platform": "iOS"},
                    "deviceProperties": {"name": "Locked", "developerModeStatus": "disabled"},
                    "connectionProperties": {"pairingState": "paired"},
                }
            ]
        }
        device = DeviceDiscovery.parse_devicectl_json(data)[0]
        self.assertFalse(device.ready)
        self.assertIn("developer_mode=disabled", device.readiness_reasons)

    def test_xctrace_fallback(self) -> None:
        runner = FakeRunner()

        def failing(arguments: Sequence[str], **kwargs):
            command = list(arguments)
            runner.calls.append(command)
            if command[1] == "devicectl":
                return subprocess.CompletedProcess(command, 1, "", "failure")
            return FakeRunner().run(command, **kwargs)

        runner.run = failing  # type: ignore[method-assign]
        devices = DeviceDiscovery(runner).list_physical_devices()
        self.assertEqual(devices[0].udid, "00008110-TEST")
        self.assertIn("readiness_unverified", devices[0].readiness_reasons[0])

    def test_simulator_selection_prefers_latest(self) -> None:
        discovery = DeviceDiscovery(FakeRunner())
        target = Target(TargetKind.SIMULATOR, name="iPhone 16 Pro")
        selected = discovery.resolve_simulator(target, "iPhone 16 Pro")
        self.assertEqual(selected.udid, "SIM-18")

    def test_explicit_simulator_udid(self) -> None:
        discovery = DeviceDiscovery(FakeRunner())
        target = Target(TargetKind.SIMULATOR, udid="SIM-17")
        self.assertEqual(discovery.resolve_simulator(target, "ignored").udid, "SIM-17")

    def test_multiple_cable_devices_require_udid(self) -> None:
        discovery = DeviceDiscovery(FakeRunner())
        first = discovery.list_physical_devices()[0]
        discovery.list_physical_devices = lambda: [first, first.__class__(**{**first.to_dict(), "kind": TargetKind.CABLE, "udid": "OTHER", "readiness_reasons": ()})]  # type: ignore[arg-type,method-assign]
        with self.assertRaisesRegex(DiscoveryError, "multiple"):
            discovery.resolve_cable(Target(TargetKind.CABLE))

    def test_boot_simulator_invokes_boot_and_bootstatus(self) -> None:
        runner = FakeRunner()
        discovery = DeviceDiscovery(runner)
        device = discovery.resolve_simulator(Target(TargetKind.SIMULATOR, udid="SIM-18"), "ignored")
        discovery.ensure_simulator_booted(device)
        self.assertIn(["xcrun", "simctl", "boot", "SIM-18"], runner.calls)
        self.assertIn(["xcrun", "simctl", "bootstatus", "SIM-18", "-b"], runner.calls)


if __name__ == "__main__":
    unittest.main()
