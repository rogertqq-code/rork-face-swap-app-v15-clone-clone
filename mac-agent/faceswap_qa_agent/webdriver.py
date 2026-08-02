from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from .config import AgentConfig
from .json_safety import JSONSafetyError, loads_bounded
from .live_models import LiveSessionRequest
from .models import DeviceInfo, TargetKind
from .trace_context import TraceContext


class WebDriverError(RuntimeError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        status: int | None = None,
        details: Any = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.details = details

    @property
    def transient(self) -> bool:
        return self.code in {
            "connection_error",
            "request_timeout",
            "unknown_error",
            "invalid_session_id",
            "session_not_created",
        }


@dataclass(frozen=True, slots=True)
class WebDriverSession:
    id: str
    capabilities: dict[str, Any]


class WebDriverClient:
    def __init__(
        self,
        base_url: str,
        *,
        timeout_seconds: float = 240,
        retry_count: int = 2,
        maximum_response_bytes: int = 16 * 1024 * 1024,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if not base_url.startswith(("http://127.0.0.1:", "http://localhost:", "http://[::1]:")):
            raise ValueError("WebDriver base URL must use loopback HTTP")
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self.retry_count = max(0, min(int(retry_count), 5))
        self.maximum_response_bytes = max(
            65536, min(int(maximum_response_bytes), 64 * 1024 * 1024)
        )
        self.sleep = sleep

    def status(self) -> dict[str, Any]:
        value = self.request("GET", "/status", retryable=True)
        return value if isinstance(value, dict) else {"value": value}

    def create_session(self, capabilities: Mapping[str, Any]) -> WebDriverSession:
        payload = {
            "capabilities": {
                "alwaysMatch": dict(capabilities),
                "firstMatch": [{}],
            }
        }
        response = self.request("POST", "/session", payload)
        if not isinstance(response, dict):
            raise WebDriverError("invalid_response", "Appium session response is not an object")
        session_id = response.get("sessionId")
        caps = response.get("capabilities", {})
        if not isinstance(session_id, str) or not session_id:
            raise WebDriverError("invalid_response", "Appium did not return a session identifier")
        return WebDriverSession(session_id, caps if isinstance(caps, dict) else {})

    def delete_session(self, session_id: str) -> None:
        self.request("DELETE", self._session_path(session_id))

    def screenshot(self, session_id: str) -> str:
        value = self.request("GET", self._session_path(session_id, "screenshot"))
        if not isinstance(value, str):
            raise WebDriverError("invalid_response", "screenshot response is not base64 text")
        return value

    def source(self, session_id: str) -> str:
        value = self.request("GET", self._session_path(session_id, "source"))
        if not isinstance(value, str):
            raise WebDriverError("invalid_response", "source response is not text")
        return value

    def mobile_source(self, session_id: str, source_format: str) -> Any:
        return self.execute_mobile(session_id, "source", {"format": source_format})

    def contexts(self, session_id: str) -> list[Any]:
        value = self.request("GET", self._session_path(session_id, "contexts"))
        return value if isinstance(value, list) else []

    def set_context(self, session_id: str, name: str) -> None:
        self.request("POST", self._session_path(session_id, "context"), {"name": name})

    def orientation(self, session_id: str) -> Any:
        return self.request("GET", self._session_path(session_id, "orientation"))

    def window_rect(self, session_id: str) -> dict[str, Any]:
        value = self.request("GET", self._session_path(session_id, "window/rect"))
        return value if isinstance(value, dict) else {}

    def find(self, session_id: str, using: str, value: str, multiple: bool = False) -> Any:
        suffix = "elements" if multiple else "element"
        return self.request(
            "POST",
            self._session_path(session_id, suffix),
            {"using": using, "value": value},
        )

    def click(self, session_id: str, element_id: str) -> None:
        self.request(
            "POST", self._session_path(session_id, f"element/{_quote(element_id)}/click"), {}
        )

    def clear(self, session_id: str, element_id: str) -> None:
        self.request(
            "POST", self._session_path(session_id, f"element/{_quote(element_id)}/clear"), {}
        )

    def type_text(self, session_id: str, text: str, element_id: str | None = None) -> None:
        payload = {"text": text, "value": list(text)}
        suffix = f"element/{_quote(element_id)}/value" if element_id else "keys"
        self.request("POST", self._session_path(session_id, suffix), payload)

    def attribute(self, session_id: str, element_id: str, name: str) -> Any:
        return self.request(
            "GET",
            self._session_path(
                session_id, f"element/{_quote(element_id)}/attribute/{_quote(name)}"
            ),
        )

    def actions(self, session_id: str, actions: list[dict[str, Any]]) -> None:
        self.request("POST", self._session_path(session_id, "actions"), {"actions": actions})

    def release_actions(self, session_id: str) -> None:
        self.request("DELETE", self._session_path(session_id, "actions"))

    def execute_mobile(
        self, session_id: str, method: str, arguments: Mapping[str, Any] | None = None
    ) -> Any:
        return self.request(
            "POST",
            self._session_path(session_id, "execute/sync"),
            {"script": f"mobile: {method}", "args": [dict(arguments or {})]},
        )

    def alert_text(self, session_id: str) -> Any:
        return self.request("GET", self._session_path(session_id, "alert/text"))

    def accept_alert(self, session_id: str) -> None:
        self.request("POST", self._session_path(session_id, "alert/accept"), {})

    def dismiss_alert(self, session_id: str) -> None:
        self.request("POST", self._session_path(session_id, "alert/dismiss"), {})

    def settings(self, session_id: str, values: Mapping[str, Any]) -> Any:
        return self.request(
            "POST", self._session_path(session_id, "appium/settings"), {"settings": dict(values)}
        )

    def request(
        self,
        method: str,
        path: str,
        payload: Mapping[str, Any] | None = None,
        *,
        retryable: bool = False,
    ) -> Any:
        if not path.startswith("/") or ".." in path:
            raise ValueError("WebDriver path must be absolute and confined")
        body = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        attempts = self.retry_count + 1 if retryable else 1
        last_error: WebDriverError | None = None
        for attempt in range(attempts):
            request = urllib.request.Request(
                self.base_url + path, data=body, headers=headers, method=method
            )
            try:
                with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                    raw = response.read(self.maximum_response_bytes + 1)
                    status = response.status
            except urllib.error.HTTPError as error:
                raw = error.read(self.maximum_response_bytes + 1)
                status = error.code
            except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as error:
                last_error = WebDriverError("connection_error", str(error))
                if attempt + 1 < attempts:
                    self.sleep(min(0.25 * (2**attempt), 2.0))
                    continue
                raise last_error from error
            if len(raw) > self.maximum_response_bytes:
                raise WebDriverError(
                    "response_too_large",
                    "WebDriver response exceeded the configured byte limit",
                    status=status,
                )
            try:
                decoded = (
                    loads_bounded(raw, maximum_bytes=self.maximum_response_bytes)
                    if raw
                    else {}
                )
            except JSONSafetyError as error:
                raise WebDriverError(
                    error.code,
                    f"WebDriver response JSON was rejected: {error}",
                    status=status,
                ) from error
            if status >= 400:
                raise self._normalize_error(decoded, status)
            value = decoded.get("value", decoded) if isinstance(decoded, dict) else decoded
            return value
        assert last_error is not None
        raise last_error

    @staticmethod
    def _normalize_error(payload: Any, status: int) -> WebDriverError:
        value = payload.get("value", payload) if isinstance(payload, dict) else {}
        if not isinstance(value, dict):
            value = {}
        code = value.get("error") if isinstance(value.get("error"), str) else "webdriver_error"
        message = value.get("message") if isinstance(value.get("message"), str) else f"HTTP {status}"
        normalized = code.strip().lower().replace(" ", "_")
        return WebDriverError(normalized, message, status=status, details=value)

    @staticmethod
    def _session_path(session_id: str, suffix: str | None = None) -> str:
        if not isinstance(session_id, str) or not session_id or len(session_id) > 512:
            raise ValueError("invalid WebDriver session identifier")
        path = f"/session/{_quote(session_id)}"
        return path if not suffix else f"{path}/{suffix}"


def build_xcuitest_capabilities(
    config: AgentConfig,
    request: LiveSessionRequest,
    device: DeviceInfo,
    *,
    wda_port: int,
    mjpeg_port: int,
    trace_context: TraceContext | None = None,
) -> dict[str, Any]:
    context = trace_context or TraceContext.create(
        session_trace_id=request.session_trace_id,
        operation_trace_id=request.session_trace_id,
    )
    context.require_session(request.session_trace_id or request.run_id)
    capabilities: dict[str, Any] = {
        "platformName": "iOS",
        "webSocketUrl": True,
        "appium:automationName": "XCUITest",
        "appium:udid": device.udid,
        "appium:deviceName": device.name,
        "appium:platformVersion": device.os_version,
        "appium:bundleId": config.live.bundle_id,
        "faceswap:liveControl": True,
        "appium:faceswapTraceId": context.session_trace_id,
        "appium:faceswapTraceparent": context.traceparent,
        "appium:noReset": request.no_reset,
        "appium:autoLaunch": request.auto_launch,
        "appium:useNewWDA": not config.wda.reuse,
        "appium:usePreinstalledWDA": config.wda.use_preinstalled,
        "appium:wdaLocalPort": wda_port,
        "appium:mjpegServerPort": mjpeg_port,
        "appium:wdaLaunchTimeout": config.wda.launch_timeout_ms,
        "appium:wdaConnectionTimeout": config.wda.connection_timeout_ms,
        "appium:wdaStartupRetries": config.wda.startup_retries,
        "appium:shouldTerminateApp": False,
        "appium:newCommandTimeout": request.lease_seconds,
        "appium:printPageSourceOnFindFailure": True,
    }
    if config.wda.updated_bundle_id:
        capabilities["appium:updatedWDABundleId"] = config.wda.updated_bundle_id
    if config.wda.xcode_config_file is not None:
        capabilities["appium:xcodeConfigFile"] = str(config.wda.xcode_config_file)
    elif config.wda.xcode_org_id:
        capabilities["appium:xcodeOrgId"] = config.wda.xcode_org_id
        capabilities["appium:xcodeSigningId"] = config.wda.xcode_signing_id
    if config.wda.derived_data_path is not None:
        capabilities["appium:derivedDataPath"] = str(config.wda.derived_data_path)
    if request.language:
        capabilities["appium:language"] = request.language
    if request.locale:
        capabilities["appium:locale"] = request.locale
    if device.kind == TargetKind.SIMULATOR:
        capabilities["appium:forceSimulatorSoftwareKeyboardPresence"] = True
    return capabilities


def _quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")
