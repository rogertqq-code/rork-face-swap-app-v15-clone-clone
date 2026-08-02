from __future__ import annotations

import base64
import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping

from .appium_manager import AppiumManager, AppiumManagerError
from .bidi import BiDiClient, BiDiError
from .config import AgentConfig
from .discovery import DeviceDiscovery, DiscoveryError
from .json_safety import JSONSafetyError, loads_bounded
from .live_models import (
    ActionKind,
    ActionResult,
    LiveActionRequest,
    LiveSession,
    LiveSessionRequest,
    LiveSessionStatus,
    ObservationKind,
    ObservationRequest,
    ObservationResult,
    utc_timestamp,
)
from .live_store import LiveStore, LiveStoreError
from .mjpeg import LatestFrameBuffer, MJPEGClient
from .models import Artifact, DeviceInfo, TargetKind
from .recovery import RecoveryCause, RecoveryEpisode, RecoveryOutcome
from .redaction import redact_structured
from .trace_context import TraceContext, TraceContextError, normalize_uuid
from .webdriver import (
    WebDriverClient,
    WebDriverError,
    build_xcuitest_capabilities,
)

W3C_ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"


class LiveControlError(RuntimeError):
    def __init__(self, code: str, message: str, *, details: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = details


@dataclass(slots=True)
class LiveRuntime:
    client: WebDriverClient
    device: DeviceInfo
    appium_session_id: str
    mjpeg: MJPEGClient
    bidi: BiDiClient
    appium_log_offset: int
    session_context: TraceContext
    sequence: int = 0
    wda_failures: int = 0
    action_lock: threading.RLock = field(default_factory=threading.RLock)


class LiveControlManager:
    def __init__(
        self,
        config: AgentConfig,
        store: LiveStore,
        discovery: DeviceDiscovery,
        appium: AppiumManager,
        *,
        webdriver_factory: Callable[..., WebDriverClient] = WebDriverClient,
        terminal_callback: Callable[[LiveSession], None] | None = None,
    ) -> None:
        self.config = config
        self.store = store
        self.discovery = discovery
        self.appium = appium
        self.webdriver_factory = webdriver_factory
        self._terminal_callback = terminal_callback
        self._lock = threading.RLock()
        self._runtimes: dict[str, LiveRuntime] = {}
        self._watchdog_stop = threading.Event()
        self._watchdog: threading.Thread | None = None

    def set_terminal_callback(
        self, callback: Callable[[LiveSession], None] | None
    ) -> None:
        with self._lock:
            self._terminal_callback = callback

    def _notify_terminal(self, session: LiveSession) -> None:
        callback = self._terminal_callback
        if callback is None or not session.status.terminal:
            return
        try:
            callback(session)
        except Exception as error:
            try:
                self.store.append_event(
                    session.id,
                    "evidence",
                    "terminal_callback_failed",
                    {"error": str(error)[:1024]},
                )
            except Exception:
                return

    def start(self) -> None:
        with self._lock:
            if self._watchdog and self._watchdog.is_alive():
                return
            self.recover()
            self._watchdog_stop.clear()
            self._watchdog = threading.Thread(
                target=self._watchdog_loop, name="faceswap-live-watchdog", daemon=True
            )
            self._watchdog.start()

    def stop(self, *, stop_appium: bool = True) -> None:
        self._watchdog_stop.set()
        watchdog = self._watchdog
        if watchdog is not None:
            watchdog.join(timeout=self.config.live.watchdog_interval_seconds + 5)
        for session in self.store.list_sessions(limit=500):
            if not session.status.terminal:
                closed = self._close_internal(
                    session, LiveSessionStatus.CANCELLED, "agent_shutdown"
                )
                self._notify_terminal(closed)
        with self._lock:
            self._watchdog = None
        if stop_appium:
            self.appium.stop()

    def recover(self) -> list[LiveSession]:
        recovered: list[LiveSession] = []
        for session in self.store.list_sessions(limit=500):
            if session.status.terminal:
                continue
            if session.appium_pid:
                self.appium.terminate_verified_stale_pid(session.appium_pid)
            try:
                episode = RecoveryEpisode.start(
                    owner_type="live_session",
                    owner_id=session.id,
                    session_trace_id=session.request.session_trace_id,
                    cause=RecoveryCause.AGENT_RESTARTED,
                    started_at=utc_timestamp(),
                    details={"status": session.status.value},
                )
                self.store.record_recovery(episode)
                recovered_session = self.store.transition(
                    session.id,
                    LiveSessionStatus.FAILED,
                    error_code="agent_restarted",
                    error_message="agent restarted during live session",
                )
                self.store.record_recovery(
                    episode.finish(
                        outcome=RecoveryOutcome.FAILED,
                        finished_at=utc_timestamp(),
                        error_code="agent_restarted",
                        error_message="live session could not survive agent restart",
                    )
                )
                self._notify_terminal(recovered_session)
                recovered.append(recovered_session)
            except (LiveStoreError, ValueError):
                continue
        return recovered

    def create_session(
        self, request: LiveSessionRequest, idempotency_key: str | None = None
    ) -> tuple[LiveSession, str | None, bool]:
        session, lease_token, created = self.store.create_session(
            request,
            idempotency_key=idempotency_key,
            wda_ports=self.config.wda.local_ports,
            mjpeg_ports=self.config.wda.mjpeg_ports,
        )
        if not created:
            return session, None, False
        session_context = TraceContext.create(
            session_trace_id=session.request.session_trace_id,
            operation_trace_id=session.request.session_trace_id,
        )
        webdriver_session_id: str | None = None
        appium_log_offset: int | None = None
        client: WebDriverClient | None = None
        bidi: BiDiClient | None = None
        try:
            device = self.discovery.resolve(
                request.target, self.config.xcode.default_simulator_name
            )
            if device.kind == TargetKind.SIMULATOR:
                self.discovery.ensure_simulator_booted(device)
            appium_state = self.appium.ensure_started()
            appium_log_offset = self.appium.log_checkpoint()
            wda_url = f"http://127.0.0.1:{session.wda_port}"
            session = self.store.bind_starting(
                session.id,
                device_udid=device.udid,
                device_name=device.name,
                appium_pid=appium_state.pid,
                appium_port=self.config.appium.port,
                wda_url=wda_url,
            )
            client = self.webdriver_factory(
                self.config.appium.url,
                timeout_seconds=self.config.appium.request_timeout_seconds,
                retry_count=self.config.limits.maximum_retries,
                maximum_response_bytes=self.config.live.maximum_observation_bytes,
            )
            capabilities = build_xcuitest_capabilities(
                self.config,
                request,
                device,
                wda_port=session.wda_port or self.config.wda.local_ports.start,
                mjpeg_port=session.mjpeg_port or self.config.wda.mjpeg_ports.start,
                trace_context=session_context,
            )
            webdriver_session = client.create_session(capabilities)
            webdriver_session_id = webdriver_session.id
            web_socket_url = webdriver_session.capabilities.get("webSocketUrl")
            if not isinstance(web_socket_url, str) or not web_socket_url:
                raise LiveControlError(
                    "bidi_url_missing",
                    "Appium session did not return the mandatory WebDriver BiDi URL",
                )
            bidi = BiDiClient(
                web_socket_url,
                timeout_seconds=self.config.appium.request_timeout_seconds,
                maximum_message_bytes=self.config.live.maximum_observation_bytes,
                event_handler=lambda event: self._record_bidi_event(
                    session.id,
                    event,
                    expected_session_trace_id=session_context.session_trace_id,
                ),
            )
            bidi.connect()
            bidi.subscribe(
                [
                    "faceswap:live.actionCompleted",
                    "faceswap:live.observationCaptured",
                    "appium:xcuitest.contextUpdated",
                    "appium:xcuitest.networkMonitor",
                    "log.entryAdded",
                ]
            )
            session = self.store.activate(session.id, webdriver_session.id)
            frame_buffer = LatestFrameBuffer()
            mjpeg = MJPEGClient(
                f"http://127.0.0.1:{session.mjpeg_port}",
                buffer=frame_buffer,
                maximum_frame_bytes=self.config.live.maximum_observation_bytes,
            )
            mjpeg.start()
            runtime = LiveRuntime(
                client=client,
                device=device,
                appium_session_id=webdriver_session.id,
                mjpeg=mjpeg,
                bidi=bidi,
                appium_log_offset=appium_log_offset,
                session_context=session_context,
            )
            with self._lock:
                self._runtimes[session.id] = runtime
            self.store.append_event(
                session.id,
                "appium",
                "session_created",
                {
                    "device": device.to_dict(),
                    "capability_keys": sorted(capabilities),
                    "appium_session_id": webdriver_session.id,
                    "appium_capabilities": webdriver_session.capabilities,
                    "bidi": bidi.state().to_dict(),
                    "traceparent": session_context.traceparent,
                },
                trace_id=session_context.operation_trace_id,
                span_id=session_context.span_id,
            )
            return session, lease_token, True
        except (
            DiscoveryError,
            AppiumManagerError,
            WebDriverError,
            BiDiError,
            LiveControlError,
            LiveStoreError,
            OSError,
        ) as error:
            if bidi is not None:
                bidi.close()
            if client is not None and webdriver_session_id:
                try:
                    client.delete_session(webdriver_session_id)
                except Exception:
                    pass
            if appium_log_offset is not None:
                self._retain_log_offset(session.id, appium_log_offset)
            code = getattr(error, "code", "live_session_start_failed")
            self._fail_session(session.id, code, str(error))
            raise LiveControlError(code, str(error)) from error
        except Exception as error:
            if bidi is not None:
                bidi.close()
            if client is not None and webdriver_session_id:
                try:
                    client.delete_session(webdriver_session_id)
                except Exception:
                    pass
            if appium_log_offset is not None:
                self._retain_log_offset(session.id, appium_log_offset)
            self._fail_session(session.id, "live_session_start_failed", str(error))
            raise LiveControlError("live_session_start_failed", str(error)) from error

    def heartbeat(
        self, session_id: str, lease_token: str, lease_seconds: int
    ) -> LiveSession:
        return self.store.renew_lease(
            session_id,
            lease_token,
            lease_seconds,
            maximum_lease_seconds=self.config.live.maximum_lease_seconds,
        )

    def close_session(self, session_id: str, lease_token: str) -> LiveSession:
        session = self.store.authorize_lease(
            session_id, lease_token, require_active=False
        )
        closed = self._close_internal(
            session, LiveSessionStatus.CLOSED, "operator_closed"
        )
        self._notify_terminal(closed)
        return closed

    def execute_action(
        self, session_id: str, lease_token: str, action: LiveActionRequest
    ) -> ActionResult:
        session = self.store.authorize_lease(session_id, lease_token)
        runtime = self._runtime(session)
        context = TraceContext.create(
            session_trace_id=session.request.session_trace_id,
            operation_trace_id=action.trace_id,
        )
        started = utc_timestamp()
        self.store.append_event(
            session.id,
            "action",
            "started",
            self._safe_action_summary(action),
            trace_id=context.operation_trace_id,
            span_id=context.span_id,
        )
        with runtime.action_lock:
            try:
                value = self._dispatch_action(runtime, action, context)
                result = ActionResult(
                    trace_id=action.trace_id,
                    kind=action.kind,
                    success=True,
                    started_at=started,
                    finished_at=utc_timestamp(),
                    value=value,
                    session_trace_id=context.session_trace_id,
                    span_id=context.span_id,
                    traceparent=context.traceparent,
                )
                self.store.append_event(
                    session.id,
                    "action",
                    "completed",
                    result.to_dict(),
                    trace_id=context.operation_trace_id,
                    span_id=context.span_id,
                )
                return result
            except (WebDriverError, ValueError, LiveControlError) as error:
                result = ActionResult(
                    trace_id=action.trace_id,
                    kind=action.kind,
                    success=False,
                    started_at=started,
                    finished_at=utc_timestamp(),
                    error_code=getattr(error, "code", "action_failed"),
                    error_message=str(error),
                    session_trace_id=context.session_trace_id,
                    span_id=context.span_id,
                    traceparent=context.traceparent,
                )
                self.store.append_event(
                    session.id,
                    "action",
                    "failed",
                    result.to_dict(),
                    trace_id=context.operation_trace_id,
                    span_id=context.span_id,
                )
                raise LiveControlError(
                    result.error_code or "action_failed", str(error)
                ) from error

    def capture_observation(
        self, session_id: str, lease_token: str, request: ObservationRequest
    ) -> ObservationResult:
        session = self.store.authorize_lease(session_id, lease_token)
        runtime = self._runtime(session)
        context = TraceContext.create(
            session_trace_id=session.request.session_trace_id,
            operation_trace_id=request.trace_id,
        )
        with runtime.action_lock:
            runtime.sequence += 1
            captured_at = utc_timestamp()
            value, artifact_path, digest = self._observation_value(
                session, runtime, request, context
            )
            result = ObservationResult(
                trace_id=request.trace_id,
                kind=request.kind,
                captured_at=captured_at,
                sequence=runtime.sequence,
                value=value,
                artifact_path=artifact_path,
                sha256=digest,
                session_trace_id=context.session_trace_id,
                span_id=context.span_id,
                traceparent=context.traceparent,
            )
            self.store.append_event(
                session.id,
                "observation",
                "captured",
                self._observation_summary(result),
                trace_id=context.operation_trace_id,
                span_id=context.span_id,
            )
            return result

    def session_document(self, session: LiveSession) -> dict[str, Any]:
        document = session.to_dict()
        document["artifacts"] = [
            artifact.to_dict() for artifact in self.store.get_artifacts(session.id)
        ]
        document["appium"] = self.appium.state().to_dict()
        with self._lock:
            runtime = self._runtimes.get(session.id)
        document["mjpeg"] = runtime.mjpeg.state() if runtime else None
        document["bidi"] = runtime.bidi.state().to_dict() if runtime else None
        return document

    def _runtime(self, session: LiveSession) -> LiveRuntime:
        with self._lock:
            runtime = self._runtimes.get(session.id)
        if runtime is None or runtime.appium_session_id != session.appium_session_id:
            raise LiveControlError(
                "session_runtime_unavailable", "live session runtime is unavailable"
            )
        return runtime

    def _dispatch_action(
        self,
        runtime: LiveRuntime,
        action: LiveActionRequest,
        context: TraceContext,
    ) -> Any:
        client = runtime.client
        session_id = runtime.appium_session_id
        values = action.parameters
        kind = action.kind
        if kind == ActionKind.FIND:
            return client.find(
                session_id, values["using"], values["value"], values["multiple"]
            )
        if kind == ActionKind.TAP:
            if "element_id" in values:
                client.click(session_id, values["element_id"])
            else:
                client.execute_mobile(
                    session_id, "tap", {"x": values["x"], "y": values["y"]}
                )
            return None
        if kind == ActionKind.DOUBLE_TAP:
            client.execute_mobile(session_id, "doubleTap", self._element_or_point(values))
            return None
        if kind == ActionKind.TOUCH_AND_HOLD:
            arguments = self._element_or_point(values)
            arguments["duration"] = values["duration"]
            client.execute_mobile(session_id, "touchAndHold", arguments)
            return None
        if kind == ActionKind.SWIPE:
            arguments = {"direction": values["direction"]}
            if "element_id" in values:
                arguments["elementId"] = values["element_id"]
            if "velocity" in values:
                arguments["velocity"] = values["velocity"]
            client.execute_mobile(session_id, "swipe", arguments)
            return None
        if kind == ActionKind.DRAG:
            client.execute_mobile(
                session_id,
                "dragFromToForDuration",
                {
                    "fromX": values["from_x"],
                    "fromY": values["from_y"],
                    "toX": values["to_x"],
                    "toY": values["to_y"],
                    "duration": values["duration"],
                },
            )
            return None
        if kind == ActionKind.TYPE_TEXT:
            client.type_text(session_id, values["text"], values.get("element_id"))
            return None
        if kind == ActionKind.CLEAR_TEXT:
            client.clear(session_id, values["element_id"])
            return None
        if kind == ActionKind.PRESS_KEY:
            client.execute_mobile(session_id, "pressButton", {"name": values["key"]})
            return None
        if kind == ActionKind.GET_ATTRIBUTE:
            return client.attribute(session_id, values["element_id"], values["name"])
        if kind == ActionKind.SET_CONTEXT:
            client.set_context(session_id, values["name"])
            return None
        if kind == ActionKind.ALERT:
            return self._alert(client, session_id, values)
        if kind in {
            ActionKind.LAUNCH_APP,
            ActionKind.ACTIVATE_APP,
            ActionKind.TERMINATE_APP,
            ActionKind.QUERY_APP_STATE,
        }:
            bundle_id = values.get("bundle_id", self.config.live.bundle_id)
            if bundle_id != self.config.live.bundle_id:
                raise LiveControlError(
                    "bundle_not_allowed", "only the configured QA app may be controlled"
                )
            methods = {
                ActionKind.LAUNCH_APP: "launchApp",
                ActionKind.ACTIVATE_APP: "activateApp",
                ActionKind.TERMINATE_APP: "terminateApp",
                ActionKind.QUERY_APP_STATE: "queryAppState",
            }
            return client.execute_mobile(
                session_id, methods[kind], {"bundleId": bundle_id}
            )
        if kind == ActionKind.BACKGROUND_APP:
            return client.execute_mobile(
                session_id, "backgroundApp", {"seconds": values["seconds"]}
            )
        if kind == ActionKind.SETTINGS:
            return client.settings(session_id, values)
        if kind in {
            ActionKind.START_NETWORK_MONITOR,
            ActionKind.STOP_NETWORK_MONITOR,
        }:
            self._require_network_monitor_support(runtime.device)
            method = (
                "startNetworkMonitor"
                if kind == ActionKind.START_NETWORK_MONITOR
                else "stopNetworkMonitor"
            )
            return client.execute_mobile(session_id, method, {})
        if kind == ActionKind.QA_COMMAND:
            return self._execute_qa_command(
                client, session_id, values["command"], context
            )
        raise LiveControlError("unsupported_action", f"unsupported action {kind.value}")

    @staticmethod
    def _require_network_monitor_support(device: DeviceInfo) -> None:
        try:
            major_version = int(device.os_version.split(".", 1)[0])
        except (AttributeError, TypeError, ValueError):
            major_version = 0
        if device.kind != TargetKind.CABLE or major_version < 18:
            raise LiveControlError(
                "network_monitor_unavailable",
                "network monitoring requires a cable-connected iOS 18+ device with RemoteXPC",
            )

    @staticmethod
    def _element_or_point(values: Mapping[str, Any]) -> dict[str, Any]:
        if "element_id" in values:
            return {"elementId": values["element_id"]}
        return {"x": values["x"], "y": values["y"]}

    @staticmethod
    def _alert(
        client: WebDriverClient, session_id: str, values: Mapping[str, Any]
    ) -> Any:
        action = values["action"]
        if action == "accept":
            if "button_label" in values:
                return client.execute_mobile(
                    session_id,
                    "alert",
                    {"action": "accept", "buttonLabel": values["button_label"]},
                )
            client.accept_alert(session_id)
            return None
        if action == "dismiss":
            if "button_label" in values:
                return client.execute_mobile(
                    session_id,
                    "alert",
                    {"action": "dismiss", "buttonLabel": values["button_label"]},
                )
            client.dismiss_alert(session_id)
            return None
        if action == "get_buttons":
            return client.execute_mobile(session_id, "alert", {"action": "getButtons"})
        return client.alert_text(session_id)

    def _execute_qa_command(
        self,
        client: WebDriverClient,
        session_id: str,
        command: Mapping[str, Any],
        context: TraceContext,
    ) -> Any:
        banner = self._find_one(client, session_id, "qa.banner")
        client.click(session_id, banner)
        input_element = self._find_one(client, session_id, "qa.command.jsonInput")
        try:
            client.clear(session_id, input_element)
        except WebDriverError:
            pass
        traced_command = dict(command)
        required_trace = {
            "traceID": context.operation_trace_id,
            "rootTraceID": context.session_trace_id,
            "spanID": context.span_id,
            "traceparent": context.traceparent,
        }
        for key, value in required_trace.items():
            if key in traced_command and traced_command[key] != value:
                raise LiveControlError(
                    "trace_root_mismatch",
                    f"QA command {key} does not match the operation trace",
                )
            traced_command[key] = value
        source = json.dumps(traced_command, sort_keys=True, separators=(",", ":"))
        client.type_text(session_id, source, input_element)
        execute = self._find_one(client, session_id, "qa.command.executeJSON")
        client.click(session_id, execute)
        deadline = time.monotonic() + min(
            self.config.appium.request_timeout_seconds, 120
        )
        last_value: Any = None
        while time.monotonic() < deadline:
            result_element = self._find_one(
                client, session_id, "qa.command.resultJSON", required=False
            )
            if result_element:
                for attribute in ("value", "label", "name"):
                    last_value = client.attribute(
                        session_id, result_element, attribute
                    )
                    if isinstance(last_value, str) and last_value.strip():
                        try:
                            return loads_bounded(
                                last_value,
                                maximum_bytes=min(
                                    self.config.live.maximum_observation_bytes,
                                    1024 * 1024,
                                ),
                            )
                        except JSONSafetyError as error:
                            if error.code == "invalid_json":
                                return last_value
                            raise LiveControlError(
                                f"qa_result_{error.code}",
                                f"QA command result JSON was rejected: {error}",
                            ) from error
            time.sleep(0.1)
        raise LiveControlError(
            "qa_command_timeout",
            f"QA command result was not published; last value was {last_value!r}",
        )

    @staticmethod
    def _find_one(
        client: WebDriverClient,
        session_id: str,
        accessibility_id: str,
        *,
        required: bool = True,
    ) -> str | None:
        try:
            value = client.find(
                session_id, "accessibility id", accessibility_id, False
            )
        except WebDriverError:
            if required:
                raise
            return None
        if not isinstance(value, Mapping):
            if required:
                raise LiveControlError(
                    "element_not_found", f"{accessibility_id} was not found"
                )
            return None
        element_id = value.get(W3C_ELEMENT_KEY) or value.get("ELEMENT")
        if not isinstance(element_id, str):
            if required:
                raise LiveControlError(
                    "invalid_element", f"{accessibility_id} returned no element identifier"
                )
            return None
        return element_id

    def _observation_value(
        self,
        session: LiveSession,
        runtime: LiveRuntime,
        request: ObservationRequest,
        context: TraceContext,
    ) -> tuple[Any, str | None, str | None]:
        kind = request.kind
        client = runtime.client
        webdriver_session_id = runtime.appium_session_id
        if kind == ObservationKind.SCREENSHOT:
            return self._screenshot_observation(
                session, runtime, request, context
            )
        if kind == ObservationKind.SOURCE_XML:
            return self._text_observation(
                session,
                request,
                context,
                "source.xml",
                client.source(webdriver_session_id),
            )
        if kind == ObservationKind.SOURCE_JSON:
            value = client.mobile_source(webdriver_session_id, "json")
            text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
            return self._text_observation(
                session, request, context, "source.json", text
            )
        if kind == ObservationKind.CONTEXTS:
            return client.contexts(webdriver_session_id), None, None
        if kind == ObservationKind.ORIENTATION:
            return client.orientation(webdriver_session_id), None, None
        if kind == ObservationKind.WINDOW_RECT:
            return client.window_rect(webdriver_session_id), None, None
        if kind == ObservationKind.DEVICE_INFO:
            return client.execute_mobile(webdriver_session_id, "deviceInfo"), None, None
        if kind == ObservationKind.BATTERY_INFO:
            return client.execute_mobile(webdriver_session_id, "batteryInfo"), None, None
        if kind == ObservationKind.COMBINED:
            screenshot, screenshot_path, screenshot_sha = self._screenshot_observation(
                session, runtime, request, context
            )
            source, source_path, source_sha = self._text_observation(
                session,
                request,
                context,
                "source.xml",
                client.source(webdriver_session_id),
            )
            return (
                {
                    "screenshot": screenshot,
                    "source_xml": source,
                    "contexts": client.contexts(webdriver_session_id),
                    "orientation": client.orientation(webdriver_session_id),
                    "window_rect": client.window_rect(webdriver_session_id),
                    "artifacts": {
                        "screenshot": screenshot_path,
                        "source_xml": source_path,
                    },
                    "hashes": {
                        "screenshot": screenshot_sha,
                        "source_xml": source_sha,
                    },
                },
                None,
                None,
            )
        raise LiveControlError("unsupported_observation", kind.value)

    def _screenshot_observation(
        self,
        session: LiveSession,
        runtime: LiveRuntime,
        request: ObservationRequest,
        context: TraceContext,
    ) -> tuple[dict[str, Any], str | None, str]:
        frame = runtime.mjpeg.buffer.latest()
        if frame is not None:
            data = frame.data
            content_type = "image/jpeg"
            source = "mjpeg"
            metadata = frame.metadata()
        else:
            encoded = runtime.client.screenshot(runtime.appium_session_id)
            try:
                data = base64.b64decode(encoded, validate=True)
            except ValueError as error:
                raise LiveControlError(
                    "invalid_screenshot", "Appium returned invalid screenshot base64"
                ) from error
            content_type = "image/png"
            source = "webdriver"
            metadata = {"byte_size": len(data)}
        if len(data) > self.config.live.maximum_observation_bytes:
            raise LiveControlError(
                "observation_too_large", "screenshot exceeds configured observation limit"
            )
        digest = hashlib.sha256(data).hexdigest()
        artifact_path = None
        if request.persist:
            extension = "jpg" if content_type == "image/jpeg" else "png"
            artifact_path = self._write_artifact(
                session.id,
                request.trace_id,
                f"screenshot.{extension}",
                data,
                "live-screenshot",
                span_id=context.span_id,
                content_type=content_type,
                provenance=source,
                redaction_state="not_applicable",
            )
        return (
            {
                "content_type": content_type,
                "base64": base64.b64encode(data).decode("ascii"),
                "source": source,
                "sha256": digest,
                **metadata,
            },
            artifact_path,
            digest,
        )

    def _text_observation(
        self,
        session: LiveSession,
        request: ObservationRequest,
        context: TraceContext,
        filename: str,
        text: str,
    ) -> tuple[dict[str, Any], str | None, str]:
        data = text.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        artifact_path = None
        if request.persist or len(data) > self.config.live.maximum_observation_bytes:
            artifact_path = self._write_artifact(
                session.id,
                request.trace_id,
                filename,
                data,
                "live-source",
                span_id=context.span_id,
                content_type=(
                    "application/xml"
                    if filename.endswith(".xml")
                    else "application/json"
                ),
                provenance="webdriver",
                redaction_state="raw_operator_authorized",
            )
        inline = text if len(data) <= self.config.live.maximum_observation_bytes else None
        return (
            {
                "text": inline,
                "byte_size": len(data),
                "sha256": digest,
                "truncated": inline is None,
            },
            artifact_path,
            digest,
        )

    def _write_artifact(
        self,
        session_id: str,
        trace_id: str,
        filename: str,
        data: bytes,
        kind: str,
        *,
        span_id: str | None = None,
        content_type: str | None = None,
        provenance: str = "agent",
        redaction_state: str = "not_applicable",
    ) -> str:
        root = (self.config.paths.artifacts / "live" / session_id).resolve()
        artifact_root = self.config.paths.artifacts.resolve()
        try:
            root.relative_to(artifact_root)
        except ValueError as error:
            raise LiveControlError("artifact_path_escape", "artifact path escaped root") from error
        root.mkdir(parents=True, exist_ok=True)
        path = (root / f"{trace_id}-{filename}").resolve()
        try:
            path.relative_to(root)
        except ValueError as error:
            raise LiveControlError("artifact_path_escape", "artifact path escaped session") from error
        temporary = path.with_suffix(path.suffix + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        relative = str(path.relative_to(artifact_root))
        artifact = Artifact(
            path=relative,
            kind=kind,
            byte_size=len(data),
            sha256=hashlib.sha256(data).hexdigest(),
            operation_trace_id=trace_id if trace_id != "session" else None,
            span_id=span_id,
            content_type=content_type,
            provenance=provenance,
            redaction_state=redaction_state,
        )
        self.store.add_artifact(session_id, artifact)
        return relative

    def _close_internal(
        self, session: LiveSession, terminal: LiveSessionStatus, reason: str
    ) -> LiveSession:
        with self._lock:
            runtime = self._runtimes.pop(session.id, None)
        if session.status.terminal:
            if runtime:
                runtime.mjpeg.stop()
            return session
        if session.status == LiveSessionStatus.PENDING:
            return self.store.transition(
                session.id,
                LiveSessionStatus.CANCELLED
                if terminal == LiveSessionStatus.CLOSED
                else terminal,
                error_code=reason if terminal != LiveSessionStatus.CLOSED else None,
                error_message=reason if terminal != LiveSessionStatus.CLOSED else None,
            )
        try:
            if session.status != LiveSessionStatus.STOPPING:
                session = self.store.transition(
                    session.id, LiveSessionStatus.STOPPING, event_name=reason
                )
        except LiveStoreError:
            pass
        if runtime:
            runtime.mjpeg.stop()
            runtime.bidi.close()
            try:
                runtime.client.delete_session(runtime.appium_session_id)
            except Exception as error:
                self.store.append_event(
                    session.id,
                    "appium",
                    "delete_session_failed",
                    {"error": str(error)},
                )
            self._retain_runtime_log(session.id, runtime)
        try:
            return self.store.transition(
                session.id,
                terminal,
                error_code=reason if terminal != LiveSessionStatus.CLOSED else None,
                error_message=reason if terminal != LiveSessionStatus.CLOSED else None,
            )
        except LiveStoreError:
            latest = self.store.get_session(session.id)
            if latest is None:
                raise
            return latest

    def _fail_session(self, session_id: str, code: str, message: str) -> None:
        with self._lock:
            runtime = self._runtimes.pop(session_id, None)
        if runtime:
            runtime.mjpeg.stop()
            runtime.bidi.close()
            try:
                runtime.client.delete_session(runtime.appium_session_id)
            except Exception as error:
                self.store.append_event(
                    session_id,
                    "appium",
                    "delete_session_failed",
                    {"error": str(error)},
                )
            self._retain_runtime_log(session_id, runtime)
        session = self.store.get_session(session_id)
        if session is None or session.status.terminal:
            return
        try:
            failed = self.store.transition(
                session_id,
                LiveSessionStatus.FAILED,
                error_code=code,
                error_message=message[:4096],
            )
            self._notify_terminal(failed)
        except LiveStoreError:
            pass

    def _retain_runtime_log(self, session_id: str, runtime: LiveRuntime) -> None:
        self._retain_log_offset(session_id, runtime.appium_log_offset)

    def _retain_log_offset(self, session_id: str, offset: int) -> None:
        try:
            data = self.appium.read_log_since(
                offset,
                maximum_bytes=self.config.live.maximum_observation_bytes,
            )
            if data:
                self._write_artifact(
                    session_id,
                    "session",
                    "appium-wda.log",
                    data,
                    "appium-wda-log",
                )
        except (AppiumManagerError, LiveControlError, OSError) as error:
            try:
                self.store.append_event(
                    session_id,
                    "evidence",
                    "appium_wda_log_failed",
                    {"error": str(error)},
                )
            except Exception:
                return

    @staticmethod
    def _wda_is_healthy(url: str) -> bool:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            return False
        request = urllib.request.Request(url.rstrip("/") + "/status", method="GET")
        try:
            with urllib.request.urlopen(request, timeout=2.0) as response:
                if response.status != 200:
                    return False
                document = loads_bounded(
                    response.read(65536), maximum_bytes=65536
                )
        except (
            urllib.error.URLError,
            TimeoutError,
            OSError,
            JSONSafetyError,
        ):
            return False
        return isinstance(document, dict) and isinstance(document.get("value"), dict)

    def _record_bidi_event(
        self,
        session_id: str,
        event: dict[str, Any],
        *,
        expected_session_trace_id: str | None = None,
    ) -> None:
        method = event.get("method")
        params = event.get("params")
        if not isinstance(method, str) or not method or len(method) > 256:
            method = "unknown"
        payload: Any = (
            params
            if isinstance(params, (dict, list, str, int, float, bool))
            else {}
        )
        try:
            encoded = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), default=str
            )
        except (TypeError, ValueError):
            encoded = "{}"
        maximum = min(self.config.live.maximum_observation_bytes, 256 * 1024)
        if len(encoded.encode("utf-8")) > maximum:
            payload = {
                "truncated": True,
                "byte_size": len(encoded.encode("utf-8")),
                "sha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
            }

        session = self.store.get_session(session_id)
        if session is None:
            return
        root = expected_session_trace_id or session.request.session_trace_id
        root = normalize_uuid(root, "session_trace_id")
        payload_mapping = payload if isinstance(payload, dict) else {}
        try:
            provided_root = payload_mapping.get(
                "session_trace_id", payload_mapping.get("root_trace_id")
            )
            if provided_root is not None and normalize_uuid(
                provided_root, "session_trace_id"
            ) != root:
                raise TraceContextError(
                    "trace_root_mismatch", "BiDi event belongs to another trace root"
                )
            operation = payload_mapping.get(
                "operation_trace_id", payload_mapping.get("trace_id")
            )
            context = TraceContext.create(
                session_trace_id=root,
                operation_trace_id=operation,
                span_id=payload_mapping.get("span_id"),
                traceparent=payload_mapping.get("traceparent"),
            )
            stored_payload = redact_structured(payload)
            event_name = method
        except (TraceContextError, ValueError) as error:
            context = TraceContext.create(session_trace_id=root)
            stored_payload = {
                "correlation_error": getattr(error, "code", "trace_invalid"),
                "method": method,
                "payload_sha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
                "payload_byte_size": len(encoded.encode("utf-8")),
            }
            event_name = "correlation_warning"
        try:
            self.store.append_event(
                session_id,
                "bidi",
                event_name,
                {"method": method, "params": stored_payload},
                trace_id=context.operation_trace_id,
                span_id=context.span_id,
            )
            self.store.prune_events(
                session_id, self.config.live.event_history_limit
            )
        except Exception:
            return

    def _watchdog_loop(self) -> None:
        while not self._watchdog_stop.wait(
            self.config.live.watchdog_interval_seconds
        ):
            self._watchdog_tick()

    def _watchdog_tick(self, *, now: float | None = None) -> None:
        timestamp = utc_timestamp() if now is None else now
        for session in self.store.list_sessions(limit=500):
            if session.status.terminal:
                continue
            if session.lease_expires_at <= timestamp:
                self._close_with_recovery(
                    session,
                    LiveSessionStatus.EXPIRED,
                    "lease_expired",
                    RecoveryCause.LEASE_EXPIRED,
                    timestamp,
                )
                continue
            if session.status != LiveSessionStatus.ACTIVE:
                continue
            if not self.appium.is_healthy():
                self._close_with_recovery(
                    session,
                    LiveSessionStatus.FAILED,
                    "appium_unhealthy",
                    RecoveryCause.APPIUM_CRASHED,
                    timestamp,
                )
                continue
            with self._lock:
                runtime = self._runtimes.get(session.id)
            if runtime is None or not session.wda_url:
                continue
            if not runtime.bidi.state().connected:
                self._close_with_recovery(
                    session,
                    LiveSessionStatus.FAILED,
                    "bidi_disconnected",
                    RecoveryCause.BIDI_DISCONNECTED,
                    timestamp,
                )
                continue
            if self._wda_is_healthy(session.wda_url):
                runtime.wda_failures = 0
            else:
                runtime.wda_failures += 1
                self.store.append_event(
                    session.id,
                    "wda",
                    "health_probe_failed",
                    {"consecutive_failures": runtime.wda_failures},
                )
                if runtime.wda_failures >= 3:
                    self._close_with_recovery(
                        session,
                        LiveSessionStatus.FAILED,
                        "wda_unhealthy",
                        RecoveryCause.WDA_UNHEALTHY,
                        timestamp,
                    )

    def _close_with_recovery(
        self,
        session: LiveSession,
        terminal: LiveSessionStatus,
        reason: str,
        cause: RecoveryCause,
        started_at: float,
    ) -> LiveSession:
        episode = RecoveryEpisode.start(
            owner_type="live_session",
            owner_id=session.id,
            session_trace_id=session.request.session_trace_id,
            cause=cause,
            started_at=started_at,
            details={"status": session.status.value, "reason": reason},
        )
        self.store.record_recovery(episode)
        closed = self._close_internal(session, terminal, reason)
        evidence_paths = tuple(
            artifact.path for artifact in self.store.get_artifacts(session.id)
        )
        outcome = (
            RecoveryOutcome.CANCELLED
            if terminal in {LiveSessionStatus.CANCELLED, LiveSessionStatus.EXPIRED}
            else RecoveryOutcome.FAILED
        )
        self.store.record_recovery(
            episode.finish(
                outcome=outcome,
                finished_at=max(started_at, utc_timestamp()),
                evidence_paths=evidence_paths,
                error_code=reason,
                error_message=f"live session terminated after {reason}",
            )
        )
        self._notify_terminal(closed)
        return closed

    @staticmethod
    def _safe_action_summary(action: LiveActionRequest) -> dict[str, Any]:
        parameters = dict(action.parameters)
        if action.kind == ActionKind.TYPE_TEXT and "text" in parameters:
            text = parameters.pop("text")
            parameters["text_length"] = len(text)
            parameters["text_sha256"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if action.kind == ActionKind.QA_COMMAND and "command" in parameters:
            source = json.dumps(parameters.pop("command"), sort_keys=True, separators=(",", ":"))
            parameters["command_sha256"] = hashlib.sha256(source.encode("utf-8")).hexdigest()
        return {
            "kind": action.kind.value,
            "parameters": LiveControlManager._redact_summary_value(parameters),
        }

    @staticmethod
    def _redact_summary_value(value: Any) -> Any:
        if isinstance(value, Mapping):
            result: dict[str, Any] = {}
            for raw_key, nested in value.items():
                key = str(raw_key)
                normalized = key.lower().replace("-", "_")
                if any(
                    marker in normalized
                    for marker in (
                        "authorization",
                        "api_key",
                        "apikey",
                        "cookie",
                        "credential",
                        "password",
                        "secret",
                        "token",
                    )
                ):
                    source = json.dumps(
                        nested, sort_keys=True, separators=(",", ":"), default=str
                    ).encode("utf-8")
                    result[key] = {
                        "redacted": True,
                        "byte_size": len(source),
                        "sha256": hashlib.sha256(source).hexdigest(),
                    }
                else:
                    result[key] = LiveControlManager._redact_summary_value(nested)
            return result
        if isinstance(value, (list, tuple)):
            return [LiveControlManager._redact_summary_value(item) for item in value]
        return value

    @staticmethod
    def _observation_summary(result: ObservationResult) -> dict[str, Any]:
        return {
            "kind": result.kind.value,
            "sequence": result.sequence,
            "artifact_path": result.artifact_path,
            "sha256": result.sha256,
        }
