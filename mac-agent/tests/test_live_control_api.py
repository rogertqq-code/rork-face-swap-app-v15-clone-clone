from __future__ import annotations

import base64
import http.client
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from faceswap_qa_agent.appium_manager import AppiumState
from faceswap_qa_agent.config import AgentConfig, ApiConfig, LimitsConfig, PathsConfig, XcodeConfig
from faceswap_qa_agent.live_control import LiveControlError, LiveControlManager
from faceswap_qa_agent.live_models import (
    ActionKind,
    AppiumProcessStatus,
    LiveActionRequest,
    LiveSessionRequest,
    LiveSessionStatus,
    ObservationRequest,
)
from faceswap_qa_agent.live_store import LiveStore
from faceswap_qa_agent.models import DeviceInfo, JobRequest, RunResult, Target, TargetKind
from faceswap_qa_agent.service import AgentService
from faceswap_qa_agent.store import JobStore
from faceswap_qa_agent.webdriver import WebDriverSession


class FakeDiscovery:
    device = DeviceInfo(
        TargetKind.SIMULATOR,
        "SIM-1234",
        "iPhone 16 Pro",
        "18.1",
        "Simulator",
        True,
        state="Booted",
    )

    def resolve(self, target, default_name):
        return self.device

    def ensure_simulator_booted(self, device):
        return None

    def list_devices(self):
        return [self.device]


class FakeAppiumManager:
    def __init__(self, config) -> None:
        self.config = config
        self.stopped = False
        self.healthy = True

    def ensure_started(self):
        return self.state()

    def state(self):
        return AppiumState(
            AppiumProcessStatus.HEALTHY,
            self.config.appium.url,
            4321,
            1.0,
            self.config.appium.version,
            True,
        )

    def is_healthy(self):
        return self.healthy

    def log_checkpoint(self):
        return 17

    def read_log_since(self, offset, *, maximum_bytes):
        assert offset == 17
        return b"[Appium] WDA session log\n"[:maximum_bytes]

    def stop(self):
        self.stopped = True
        return AppiumState(
            AppiumProcessStatus.STOPPED,
            self.config.appium.url,
            None,
            None,
            None,
            False,
        )

    def terminate_verified_stale_pid(self, pid):
        return pid == 4321


class FakeFrameBuffer:
    def latest(self):
        return None


class FakeMJPEGClient:
    def __init__(self, url, **kwargs) -> None:
        self.url = url
        self.buffer = FakeFrameBuffer()
        self.started = False

    def start(self):
        self.started = True

    def stop(self):
        self.started = False

    def state(self):
        return {"url": self.url, "connected": self.started, "latest": None}


class FakeBiDiState:
    def __init__(self, connected, subscriptions):
        self.connected = connected
        self.subscriptions = tuple(subscriptions)

    def to_dict(self):
        return {
            "connected": self.connected,
            "url": "ws://127.0.0.1/bidi",
            "subscriptions": list(self.subscriptions),
            "last_error": None,
            "messages_received": 0,
            "messages_sent": 0,
        }


class FakeBiDiClient:
    instances: list["FakeBiDiClient"] = []

    def __init__(self, url, *, event_handler=None, **kwargs):
        self.url = url
        self.event_handler = event_handler
        self.connected = False
        self.subscriptions: list[str] = []
        type(self).instances.append(self)

    def connect(self):
        self.connected = True

    def subscribe(self, events):
        self.subscriptions.extend(events)

    def close(self):
        self.connected = False

    def state(self):
        return FakeBiDiState(self.connected, self.subscriptions)

    def emit(self, method, params):
        if self.event_handler:
            self.event_handler({"method": method, "params": params})


class FakeWebDriverClient:
    instances: list["FakeWebDriverClient"] = []

    def __init__(self, base_url, **kwargs) -> None:
        self.base_url = base_url
        self.calls: list[tuple] = []
        self.deleted = False
        type(self).instances.append(self)

    def create_session(self, capabilities):
        self.capabilities = capabilities
        return WebDriverSession("APPIUM-SESSION", {"webSocketUrl": "ws://127.0.0.1/bidi"})

    def delete_session(self, session_id):
        self.deleted = True

    def screenshot(self, session_id):
        return base64.b64encode(b"png-bytes").decode()

    def source(self, session_id):
        return '<App name="FaceSwap"/>'

    def mobile_source(self, session_id, source_format):
        return {"type": "Application", "name": "FaceSwap"}

    def contexts(self, session_id):
        return ["NATIVE_APP"]

    def orientation(self, session_id):
        return "PORTRAIT"

    def window_rect(self, session_id):
        return {"x": 0, "y": 0, "width": 390, "height": 844}

    def find(self, session_id, using, value, multiple=False):
        element = {
            "qa.banner": "BANNER",
            "qa.command.jsonInput": "INPUT",
            "qa.command.executeJSON": "EXECUTE",
            "qa.command.resultJSON": "RESULT",
        }.get(value, "ELEMENT")
        return {"element-6066-11e4-a52e-4f735466cecf": element}

    def click(self, session_id, element_id):
        self.calls.append(("click", element_id))

    def clear(self, session_id, element_id):
        self.calls.append(("clear", element_id))

    def type_text(self, session_id, text, element_id=None):
        self.calls.append(("type", element_id, text))

    def attribute(self, session_id, element_id, name):
        if element_id == "RESULT" and name == "value":
            return json.dumps({"status": "success", "command": "snapshot"})
        return ""

    def set_context(self, session_id, name):
        self.calls.append(("context", name))

    def execute_mobile(self, session_id, method, arguments=None):
        self.calls.append(("mobile", method, arguments))
        if method == "deviceInfo":
            return {"model": "iPhone"}
        if method == "batteryInfo":
            return {"level": 0.8, "state": 2}
        return {"ok": True}

    def settings(self, session_id, values):
        self.calls.append(("settings", values))
        return values

    def accept_alert(self, session_id):
        return None

    def dismiss_alert(self, session_id):
        return None

    def alert_text(self, session_id):
        return "Alert"


class FakeRunner:
    def run(self, job):
        return RunResult(True, 0, None, None, None, ())


class LiveControlAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        ios = root / "ios"
        ios.mkdir()
        (ios / "App.xcodeproj").mkdir()
        self.config = AgentConfig(
            api=ApiConfig("127.0.0.1", 0, root / "state" / "token"),
            paths=PathsConfig(ios, "App.xcodeproj", root / "state" / "jobs.sqlite3", root / "artifacts", root / "logs"),
            xcode=XcodeConfig("QA", "QA", "", "iPhone 16 Pro"),
            limits=LimitsConfig(1024 * 1024, 60, 600, 2, 168, 2),
            config_path=root / "config.json",
        )
        self.job_store = JobStore(self.config.paths.database)
        self.live_store = LiveStore(self.config.paths.database)
        self.discovery = FakeDiscovery()
        self.appium = FakeAppiumManager(self.config)
        self.control = LiveControlManager(
            self.config,
            self.live_store,
            self.discovery,
            self.appium,
            webdriver_factory=FakeWebDriverClient,
        )
        self.mjpeg_patch = mock.patch(
            "faceswap_qa_agent.live_control.MJPEGClient", FakeMJPEGClient
        )
        self.bidi_patch = mock.patch(
            "faceswap_qa_agent.live_control.BiDiClient", FakeBiDiClient
        )
        self.mjpeg_patch.start()
        self.bidi_patch.start()
        FakeWebDriverClient.instances = []
        FakeBiDiClient.instances = []

    def tearDown(self) -> None:
        self.control.stop(stop_appium=False)
        self.bidi_patch.stop()
        self.mjpeg_patch.stop()
        self.temporary.cleanup()

    def request(self):
        return LiveSessionRequest(
            Target(TargetKind.SIMULATOR, udid="SIM-1234"), lease_seconds=120
        )

    def test_manager_executes_actions_observations_qa_router_and_releases_queue(self) -> None:
        session, token, created = self.control.create_session(self.request())
        self.assertTrue(created)
        self.assertIsNotNone(token)
        self.assertEqual(session.status, LiveSessionStatus.ACTIVE)
        client = FakeWebDriverClient.instances[-1]
        bidi = FakeBiDiClient.instances[-1]
        self.assertEqual(client.capabilities["faceswap:liveControl"], True)
        self.assertEqual(client.capabilities["webSocketUrl"], True)
        self.assertIn("faceswap:live.actionCompleted", bidi.subscriptions)
        self.assertIn("log.entryAdded", bidi.subscriptions)
        bidi.emit(
            "appium:xcuitest.contextUpdated",
            {"name": "NATIVE_APP", "type": "NATIVE"},
        )
        bidi_events = self.live_store.get_events(session.id, after=0, limit=100)
        self.assertTrue(
            any(event.category == "bidi" and event.name == "appium:xcuitest.contextUpdated" for event in bidi_events)
        )

        tap = LiveActionRequest.from_dict(
            {"kind": "tap", "parameters": {"element_id": "ELEMENT"}},
            maximum_text_length=1024,
        )
        self.assertTrue(self.control.execute_action(session.id, token or "", tap).success)
        start_network = LiveActionRequest.from_dict(
            {"kind": "start_network_monitor", "parameters": {}},
            maximum_text_length=1024,
        )
        stop_network = LiveActionRequest.from_dict(
            {"kind": "stop_network_monitor", "parameters": {}},
            maximum_text_length=1024,
        )
        with self.assertRaises(LiveControlError) as rejected:
            self.control.execute_action(session.id, token or "", start_network)
        self.assertEqual(rejected.exception.code, "network_monitor_unavailable")
        self.assertNotIn(("mobile", "startNetworkMonitor", {}), client.calls)
        self.assertTrue(
            any(
                event.category == "action"
                and event.name == "failed"
                and event.payload.get("error_code") == "network_monitor_unavailable"
                for event in self.live_store.get_events(session.id, limit=100)
            )
        )
        qa = LiveActionRequest.from_dict(
            {
                "kind": "qa_command",
                "parameters": {"command": {"version": 1, "name": "snapshot"}},
            },
            maximum_text_length=1024,
        )
        qa_result = self.control.execute_action(session.id, token or "", qa)
        self.assertEqual(qa_result.value["status"], "success")

        observation = self.control.capture_observation(
            session.id,
            token or "",
            ObservationRequest.from_dict({"kind": "combined", "persist": True}),
        )
        self.assertIn("screenshot", observation.value)
        artifacts = self.live_store.get_artifacts(session.id)
        self.assertEqual(len(artifacts), 2)
        for artifact in artifacts:
            self.assertTrue((self.config.paths.artifacts / artifact.path).exists())

        closed = self.control.close_session(session.id, token or "")
        self.assertEqual(closed.status, LiveSessionStatus.CLOSED)
        self.assertTrue(client.deleted)
        terminal_artifacts = self.live_store.get_artifacts(session.id)
        self.assertEqual(len(terminal_artifacts), 3)
        log_artifact = next(
            artifact for artifact in terminal_artifacts if artifact.kind == "appium-wda-log"
        )
        self.assertEqual(
            (self.config.paths.artifacts / log_artifact.path).read_bytes(),
            b"[Appium] WDA session log\n",
        )
        job, _ = self.job_store.create_job(JobRequest(target=self.request().target))
        self.assertEqual(self.job_store.claim_next_job().id, job.id)

    def test_cable_ios18_network_monitor_and_bidi_events(self) -> None:
        self.discovery.device = DeviceInfo(
            TargetKind.CABLE,
            "00008110-CABLE",
            "iPhone 16 Pro",
            "18.1",
            "iPhone17,1",
            True,
            state="available",
        )
        request = LiveSessionRequest(
            Target(TargetKind.CABLE, udid="00008110-CABLE"), lease_seconds=120
        )
        session, token, created = self.control.create_session(request)
        self.assertTrue(created)
        client = FakeWebDriverClient.instances[-1]
        bidi = FakeBiDiClient.instances[-1]
        for kind, method in (
            ("start_network_monitor", "startNetworkMonitor"),
            ("stop_network_monitor", "stopNetworkMonitor"),
        ):
            action = LiveActionRequest.from_dict(
                {"kind": kind, "parameters": {}}, maximum_text_length=1024
            )
            self.assertTrue(
                self.control.execute_action(session.id, token or "", action).success
            )
            self.assertIn(("mobile", method, {}), client.calls)
        bidi.emit(
            "appium:xcuitest.networkMonitor",
            {"event": {"type": 2, "bytesIn": 10, "bytesOut": 20}},
        )
        self.assertTrue(
            any(
                event.name == "appium:xcuitest.networkMonitor"
                for event in self.live_store.get_events(session.id, limit=100)
            )
        )
        self.control.close_session(session.id, token or "")

    def test_action_and_observation_summaries_redact_sensitive_values(self) -> None:
        typed = LiveActionRequest.from_dict(
            {"kind": "type_text", "parameters": {"text": "super-secret-value"}},
            maximum_text_length=1024,
        )
        typed_summary = self.control._safe_action_summary(typed)
        self.assertNotIn("super-secret-value", json.dumps(typed_summary))
        self.assertEqual(typed_summary["parameters"]["text_length"], 18)

        qa = LiveActionRequest.from_dict(
            {
                "kind": "qa_command",
                "parameters": {
                    "command": {
                        "version": 1,
                        "name": "snapshot",
                        "api_token": "qa-token-value",
                    }
                },
            },
            maximum_text_length=1024,
        )
        qa_summary = self.control._safe_action_summary(qa)
        self.assertNotIn("qa-token-value", json.dumps(qa_summary))
        self.assertIn("command_sha256", qa_summary["parameters"])

        nested = self.control._redact_summary_value(
            {
                "authorization": "Bearer secret",
                "nested": {
                    "password": "password-value",
                    "cookies": ["session-cookie"],
                    "safe": "visible",
                },
            }
        )
        encoded = json.dumps(nested)
        for forbidden in ("Bearer secret", "password-value", "session-cookie"):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(nested["nested"]["safe"], "visible")

        session, token, _ = self.control.create_session(self.request())
        observation = self.control.capture_observation(
            session.id,
            token or "",
            ObservationRequest.from_dict({"kind": "screenshot", "persist": False}),
        )
        observation_summary = self.control._observation_summary(observation)
        self.assertNotIn("value", observation_summary)
        self.assertNotIn("c2NyZWVuc2hvdA==", json.dumps(observation_summary))
        self.control.close_session(session.id, token or "")

    def test_watchdog_requires_three_consecutive_wda_failures(self) -> None:
        session, token, _ = self.control.create_session(self.request())
        with mock.patch.object(self.control, "_wda_is_healthy", return_value=False):
            self.control._watchdog_tick(now=session.lease_expires_at - 1)
            self.assertEqual(
                self.live_store.get_session(session.id).status,
                LiveSessionStatus.ACTIVE,
            )
            self.control._watchdog_tick(now=session.lease_expires_at - 1)
            self.control._watchdog_tick(now=session.lease_expires_at - 1)
        failed = self.live_store.get_session(session.id)
        self.assertEqual(failed.status, LiveSessionStatus.FAILED)
        self.assertEqual(failed.error_code, "wda_unhealthy")
        failures = [
            event.payload["consecutive_failures"]
            for event in self.live_store.get_events(session.id, limit=100)
            if event.name == "health_probe_failed"
        ]
        self.assertEqual(failures, [1, 2, 3])
        episodes = self.live_store.list_recoveries(
            session_trace_id=session.request.session_trace_id,
            limit=10,
        )
        self.assertEqual(len(episodes), 1)
        self.assertEqual(episodes[0].cause.value, "wda_unhealthy")
        self.assertEqual(episodes[0].outcome.value, "failed")
        self.assertEqual(episodes[0].session_trace_id, session.request.session_trace_id)
        self.assertTrue(
            any(path.endswith("appium-wda.log") for path in episodes[0].evidence_paths)
        )

    def test_watchdog_records_bidi_disconnect_recovery(self) -> None:
        session, _, _ = self.control.create_session(self.request())
        FakeBiDiClient.instances[-1].connected = False
        self.control._watchdog_tick(now=session.lease_expires_at - 1)
        failed = self.live_store.get_session(session.id)
        self.assertEqual(failed.status, LiveSessionStatus.FAILED)
        self.assertEqual(failed.error_code, "bidi_disconnected")
        episodes = self.live_store.list_recoveries(
            session_trace_id=session.request.session_trace_id,
            limit=10,
        )
        self.assertEqual(len(episodes), 1)
        self.assertEqual(episodes[0].cause.value, "bidi_disconnected")
        self.assertEqual(episodes[0].outcome.value, "failed")

    def test_watchdog_fails_unhealthy_appium_and_expires_lease(self) -> None:
        appium_session, _, _ = self.control.create_session(self.request())
        self.appium.healthy = False
        self.control._watchdog_tick(now=appium_session.lease_expires_at - 1)
        failed = self.live_store.get_session(appium_session.id)
        self.assertEqual(failed.status, LiveSessionStatus.FAILED)
        self.assertEqual(failed.error_code, "appium_unhealthy")
        appium_recovery = self.live_store.list_recoveries(
            session_trace_id=appium_session.request.session_trace_id,
            limit=10,
        )
        self.assertEqual(appium_recovery[0].cause.value, "appium_crashed")
        self.assertEqual(appium_recovery[0].outcome.value, "failed")

        self.appium.healthy = True
        expiring, _, _ = self.control.create_session(self.request())
        self.control._watchdog_tick(now=expiring.lease_expires_at + 1)
        expired = self.live_store.get_session(expiring.id)
        self.assertEqual(expired.status, LiveSessionStatus.EXPIRED)
        self.assertEqual(expired.error_code, "lease_expired")
        lease_recovery = self.live_store.list_recoveries(
            session_trace_id=expiring.request.session_trace_id,
            limit=10,
        )
        self.assertEqual(lease_recovery[0].cause.value, "lease_expired")
        self.assertEqual(lease_recovery[0].outcome.value, "cancelled")

    def test_authenticated_live_api_and_sse(self) -> None:
        service = AgentService(
            self.config,
            store=self.job_store,
            discovery=self.discovery,
            runner=FakeRunner(),
            live_store=self.live_store,
            appium_manager=self.appium,
            live_control=self.control,
        )
        service.start()
        address = service.address
        self.assertIsNotNone(address)
        host, port = address or ("127.0.0.1", 0)
        base = f"http://{host}:{port}"
        headers = {"Authorization": f"Bearer {service.token}"}
        try:
            tools = self._http_json(base + "/api/v1/live/tools", headers=headers)
            self.assertGreaterEqual(len(tools["tools"]), 20)
            payload = {
                "target": {"kind": "simulator", "udid": "SIM-1234"},
                "lease_seconds": 120,
            }
            created = self._http_json(
                base + "/api/v1/live/sessions", method="POST", headers=headers, payload=payload
            )
            session_id = created["session"]["id"]
            session_trace_id = created["session"]["session_trace_id"]
            lease = created["lease_token"]
            live_headers = {**headers, "X-Live-Lease": lease}

            action = self._http_json(
                base + f"/api/v1/live/sessions/{session_id}/actions",
                method="POST",
                headers=live_headers,
                payload={"kind": "tap", "parameters": {"x": 10, "y": 20}},
            )
            self.assertTrue(action["result"]["success"])
            self.assertEqual(
                action["result"]["session_trace_id"], session_trace_id
            )
            self.assertIsNotNone(action["result"]["operation_trace_id"])
            self.assertEqual(len(action["result"]["span_id"]), 16)
            observation = self._http_json(
                base + f"/api/v1/live/sessions/{session_id}/observations",
                method="POST",
                headers=live_headers,
                payload={"kind": "screenshot", "persist": True},
            )
            self.assertEqual(observation["observation"]["value"]["source"], "webdriver")
            heartbeat = self._http_json(
                base + f"/api/v1/live/sessions/{session_id}/heartbeat",
                method="POST",
                headers=live_headers,
                payload={"lease_seconds": 180},
            )
            self.assertEqual(heartbeat["session"]["status"], "active")

            invalid_resume = urllib.request.Request(
                base + f"/api/v1/live/sessions/{session_id}/stream?after=0",
                headers={**live_headers, "Last-Event-ID": str(2**63)},
                method="GET",
            )
            with self.assertRaises(urllib.error.HTTPError) as invalid_event_id:
                urllib.request.urlopen(invalid_resume, timeout=5)
            self.assertEqual(invalid_event_id.exception.code, 400)

            stream_result: dict[str, object] = {}

            def read_stream() -> None:
                connection = http.client.HTTPConnection(host, port, timeout=10)
                connection.request(
                    "GET",
                    f"/api/v1/live/sessions/{session_id}/stream?after=0",
                    headers=live_headers,
                )
                response = connection.getresponse()
                stream_result["status"] = response.status
                stream_result["body"] = response.read().decode("utf-8")
                connection.close()

            stream_thread = threading.Thread(target=read_stream)
            stream_thread.start()
            time.sleep(0.2)
            closed = self._http_json(
                base + f"/api/v1/live/sessions/{session_id}",
                method="DELETE",
                headers=live_headers,
            )
            self.assertEqual(closed["session"]["status"], "closed")
            stream_thread.join(timeout=10)
            self.assertEqual(stream_result.get("status"), 200)
            stream_body = str(stream_result.get("body", ""))
            self.assertIn("retry: 15000", stream_body)
            self.assertIn("event: action.completed", stream_body)
            self.assertIn("event: stream.closed", stream_body)

            trace_index = self._http_json(
                base + "/api/v1/traces?owner_type=live_session&status=closed&limit=10",
                headers=headers,
            )
            self.assertEqual(trace_index["total"], 1)
            self.assertEqual(
                trace_index["traces"][0]["session_trace_id"],
                session_trace_id,
            )
            trace = self._http_json(
                base + f"/api/v1/traces/{session_trace_id}",
                headers=headers,
            )["trace"]
            self.assertEqual(trace["owner_type"], "live_session")
            self.assertEqual(trace["session_trace_id"], session_trace_id)
            self.assertEqual(trace["evidence"]["bundle"]["kind"], "trace-evidence-bundle")
            self.assertTrue(
                all(
                    artifact["session_trace_id"] == session_trace_id
                    for artifact in trace["artifacts"]
                )
            )
            analytics = self._http_json(
                base + f"/api/v1/traces/{session_trace_id}/analytics",
                headers=headers,
            )["analytics"]
            self.assertTrue(
                analytics["invariants"]["root_trace_continuity"]["passed"]
            )
            recoveries = self._http_json(
                base + f"/api/v1/traces/{session_trace_id}/recoveries",
                headers=headers,
            )
            self.assertEqual(recoveries["recovery_episodes"], [])
        finally:
            service.stop()

    @staticmethod
    def _http_json(url, *, method="GET", headers=None, payload=None):
        body = None
        request_headers = dict(headers or {})
        if payload is not None:
            body = json.dumps(payload).encode()
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())


if __name__ == "__main__":
    unittest.main()
