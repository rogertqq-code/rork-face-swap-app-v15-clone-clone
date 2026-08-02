from __future__ import annotations

import json
import subprocess
import tempfile
import threading
import unittest
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from faceswap_qa_agent.appium_manager import AppiumManager, AppiumManagerError
from faceswap_qa_agent.config import (
    AgentConfig,
    ApiConfig,
    LimitsConfig,
    PathsConfig,
    WDAConfig,
    XcodeConfig,
)
from faceswap_qa_agent.live_models import LiveSessionRequest
from faceswap_qa_agent.mjpeg import JPEGStreamParser, LatestFrameBuffer, jpeg_dimensions
from faceswap_qa_agent.models import DeviceInfo, Target, TargetKind
from faceswap_qa_agent.webdriver import (
    WebDriverClient,
    WebDriverError,
    build_xcuitest_capabilities,
)


class FakeWebDriverHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests: list[tuple[str, str, object]] = []

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/status":
            self._json(200, {"value": {"ready": True}})
        elif self.path == "/session/SESSION/screenshot":
            self._json(200, {"value": "YWJj"})
        elif self.path == "/session/SESSION/source":
            self._json(200, {"value": "<App/>"})
        elif self.path == "/session/SESSION/bad":
            self._json(
                404,
                {"value": {"error": "no such element", "message": "missing"}},
            )
        else:
            self._json(404, {"value": {"error": "unknown command", "message": self.path}})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        type(self).requests.append(("POST", self.path, payload))
        if self.path == "/session":
            self._json(
                200,
                {"value": {"sessionId": "SESSION", "capabilities": {"platformName": "iOS"}}},
            )
        elif self.path == "/session/SESSION/element":
            self._json(200, {"value": {"element-6066-11e4-a52e-4f735466cecf": "E1"}})
        else:
            self._json(200, {"value": None})

    def do_DELETE(self) -> None:
        self._json(200, {"value": None})

    def _json(self, status: int, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class AppiumWebDriverMJPEGTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        ios = root / "ios"
        ios.mkdir()
        (ios / "App.xcodeproj").mkdir()
        self.config = AgentConfig(
            api=ApiConfig("127.0.0.1", 8765, root / "token"),
            paths=PathsConfig(ios, "App.xcodeproj", root / "db.sqlite", root / "artifacts", root / "logs"),
            xcode=XcodeConfig("QA", "QA", "", "iPhone 16 Pro"),
            limits=LimitsConfig(1024 * 1024, 60, 600, 2, 168, 5),
            config_path=root / "config.json",
            wda=WDAConfig(xcode_org_id="TEAM123456"),
        )
        appium_home = root / "appium-home"
        remotexpc = appium_home / "node_modules" / "appium-ios-remotexpc"
        remotexpc.mkdir(parents=True)
        (remotexpc / "package.json").write_text(
            json.dumps({"name": "appium-ios-remotexpc", "version": "5.13.2"}),
            encoding="utf-8",
        )
        self.config = replace(
            self.config, appium=replace(self.config.appium, home=appium_home)
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_appium_command_and_pinned_installation(self) -> None:
        def runner(arguments, **kwargs):
            if "--version" in arguments:
                return subprocess.CompletedProcess(arguments, 0, "3.6.0\n", "")
            if "driver" in arguments:
                return subprocess.CompletedProcess(
                    arguments, 0, json.dumps({"xcuitest": {"version": "12.1.4"}}), ""
                )
            return subprocess.CompletedProcess(
                arguments, 0, json.dumps({"faceswap-live": {"version": "1.0.0"}}), ""
            )

        manager = AppiumManager(self.config, command_runner=runner)
        command = manager.build_command()
        self.assertEqual(command[0:2], ["appium", "server"])
        self.assertIn("faceswap-live", command)
        self.assertEqual(manager.verify_installation()["xcuitest"], "12.1.4")
        environment = manager._environment()
        self.assertEqual(environment["FACESWAP_LIVE_ENABLED"], "1")
        self.assertEqual(environment["FACESWAP_QA_BUNDLE_ID"], self.config.live.bundle_id)

    def test_plugin_version_mismatch_is_terminal(self) -> None:
        def runner(arguments, **kwargs):
            if "--version" in arguments:
                return subprocess.CompletedProcess(arguments, 0, "3.6.0\n", "")
            if "driver" in arguments:
                return subprocess.CompletedProcess(
                    arguments, 0, json.dumps({"xcuitest": {"version": "12.1.4"}}), ""
                )
            return subprocess.CompletedProcess(
                arguments, 0, json.dumps({"faceswap-live": {"version": "0.9.0"}}), ""
            )

        with self.assertRaises(AppiumManagerError) as context:
            AppiumManager(self.config, command_runner=runner).verify_installation()
        self.assertEqual(context.exception.code, "appium_plugin_version_mismatch")

    def test_remotexpc_version_mismatch_is_terminal(self) -> None:
        package = (
            self.config.appium.home
            / "node_modules"
            / "appium-ios-remotexpc"
            / "package.json"
        )
        package.write_text(json.dumps({"version": "5.0.0"}), encoding="utf-8")

        def runner(arguments, **kwargs):
            if "--version" in arguments:
                return subprocess.CompletedProcess(arguments, 0, "3.6.0\n", "")
            if "driver" in arguments:
                return subprocess.CompletedProcess(
                    arguments, 0, json.dumps({"xcuitest": {"version": "12.1.4"}}), ""
                )
            return subprocess.CompletedProcess(
                arguments, 0, json.dumps({"faceswap-live": {"version": "1.0.0"}}), ""
            )

        with self.assertRaises(AppiumManagerError) as context:
            AppiumManager(self.config, command_runner=runner).verify_installation()
        self.assertEqual(context.exception.code, "remotexpc_version_mismatch")

    def test_appium_version_mismatch_is_terminal(self) -> None:
        def runner(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, 0, "3.5.0\n", "")

        manager = AppiumManager(self.config, command_runner=runner)
        with self.assertRaises(AppiumManagerError) as context:
            manager.verify_installation()
        self.assertEqual(context.exception.code, "appium_version_mismatch")

    def test_pid_record_is_private_and_round_trips(self) -> None:
        manager = AppiumManager(self.config)
        manager._write_pid(4321)
        self.assertEqual(manager._read_pid(), 4321)
        self.assertEqual(manager.pid_path.stat().st_mode & 0o777, 0o600)
        manager._remove_pid()
        self.assertIsNone(manager._read_pid())

    def test_healthy_unmanaged_server_is_rejected(self) -> None:
        manager = AppiumManager(self.config)
        with mock.patch.object(manager, "is_healthy", return_value=True):
            with self.assertRaises(AppiumManagerError) as context:
                manager.ensure_started()
        self.assertEqual(context.exception.code, "appium_port_in_use")

    def test_startup_log_requires_loaded_driver_and_plugin(self) -> None:
        manager = AppiumManager(self.config)
        log = self.config.paths.logs / "appium-server.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(
            "FaceSwapLivePlugin has been successfully loaded\n"
            "XCUITestDriver has been successfully loaded\n"
        )
        manager._validate_current_startup_log(log)
        log.write_text(
            "FaceSwapLivePlugin has been successfully loaded\n"
            "Could not load driver 'xcuitest'\n"
        )
        with self.assertRaises(AppiumManagerError) as context:
            manager._validate_current_startup_log(log)
        self.assertEqual(context.exception.code, "xcuitest_driver_load_failed")

    def test_startup_log_ignores_stale_prior_run_bytes(self) -> None:
        manager = AppiumManager(self.config)
        log = self.config.paths.logs / "appium-server.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        stale = "XCUITestDriver has been successfully loaded\nFaceSwapLivePlugin has been successfully loaded\n"
        log.write_text(stale + "Could not load driver 'xcuitest'\n")
        manager._log_start_offset = len(stale.encode("utf-8"))
        with self.assertRaises(AppiumManagerError) as context:
            manager._validate_current_startup_log(log)
        self.assertEqual(context.exception.code, "xcuitest_driver_load_failed")

    def test_capabilities_are_qa_gated_and_include_wda_reuse_ports(self) -> None:
        request = LiveSessionRequest(
            target=Target(TargetKind.CABLE, udid="DEVICE-1234"),
            lease_seconds=600,
        )
        device = DeviceInfo(
            TargetKind.CABLE,
            "DEVICE-1234",
            "Phone",
            "18.1",
            "iPhone",
            True,
        )
        capabilities = build_xcuitest_capabilities(
            self.config, request, device, wda_port=8111, mjpeg_port=9111
        )
        self.assertEqual(capabilities["appium:bundleId"], self.config.live.bundle_id)
        self.assertEqual(capabilities["faceswap:liveControl"], True)
        self.assertEqual(capabilities["appium:wdaLocalPort"], 8111)
        self.assertEqual(capabilities["appium:mjpegServerPort"], 9111)
        self.assertEqual(capabilities["appium:useNewWDA"], False)
        self.assertEqual(capabilities["appium:xcodeOrgId"], "TEAM123456")

    def test_webdriver_session_commands_and_normalized_error(self) -> None:
        FakeWebDriverHandler.requests = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeWebDriverHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = WebDriverClient(f"http://127.0.0.1:{server.server_port}")
            self.assertTrue(client.status()["ready"])
            session = client.create_session({"platformName": "iOS"})
            self.assertEqual(session.id, "SESSION")
            self.assertEqual(client.screenshot(session.id), "YWJj")
            self.assertEqual(client.source(session.id), "<App/>")
            found = client.find(session.id, "accessibility id", "qa.banner")
            self.assertEqual(found["element-6066-11e4-a52e-4f735466cecf"], "E1")
            with self.assertRaises(WebDriverError) as context:
                client.request("GET", "/session/SESSION/bad")
            self.assertEqual(context.exception.code, "no_such_element")
            client.delete_session(session.id)
            session_payload = FakeWebDriverHandler.requests[0][2]
            self.assertIn("capabilities", session_payload)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_webdriver_rejects_non_loopback_endpoint(self) -> None:
        with self.assertRaisesRegex(ValueError, "loopback"):
            WebDriverClient("http://example.com:4723")

    def test_jpeg_parser_dimensions_hash_and_latest_frame_backpressure(self) -> None:
        frame = (
            b"\xff\xd8"
            b"\xff\xc0\x00\x11\x08\x00\x02\x00\x03\x03"
            b"\x01\x11\x00\x02\x11\x00\x03\x11\x00"
            b"\xff\xd9"
        )
        self.assertEqual(jpeg_dimensions(frame), (3, 2))
        parser = JPEGStreamParser()
        self.assertEqual(parser.feed(b"header" + frame[:8]), [])
        self.assertEqual(parser.feed(frame[8:] + frame), [frame, frame])
        buffer = LatestFrameBuffer()
        first = buffer.publish(frame, captured_at=1.0)
        second = buffer.publish(frame + b"ignored", captured_at=2.0)
        self.assertEqual(first.sequence, 1)
        self.assertEqual(second.sequence, 2)
        self.assertEqual(buffer.latest().sequence if buffer.latest() else None, 2)
        self.assertEqual(buffer.wait_for_frame(after_sequence=1, timeout=0.01).sequence, 2)
        self.assertEqual(len(second.sha256), 64)


if __name__ == "__main__":
    unittest.main()
