from __future__ import annotations

import enum
import hashlib
import json
import math
import re
import secrets
import uuid
from dataclasses import dataclass, field
from typing import Any, Mapping

from .models import Target, new_uuid, utc_timestamp
from .trace_context import normalize_uuid

ELEMENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,512}$")
ATTRIBUTE_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_.:-]{0,127}$")
CONTEXT_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,256}$")
BUNDLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$")


class LiveSessionStatus(str, enum.Enum):
    PENDING = "pending"
    STARTING = "starting"
    ACTIVE = "active"
    STOPPING = "stopping"
    CLOSED = "closed"
    FAILED = "failed"
    EXPIRED = "expired"
    CANCELLED = "cancelled"

    @property
    def terminal(self) -> bool:
        return self in {self.CLOSED, self.FAILED, self.EXPIRED, self.CANCELLED}


LIVE_TRANSITIONS: dict[LiveSessionStatus, frozenset[LiveSessionStatus]] = {
    LiveSessionStatus.PENDING: frozenset(
        {
            LiveSessionStatus.STARTING,
            LiveSessionStatus.CANCELLED,
            LiveSessionStatus.FAILED,
            LiveSessionStatus.EXPIRED,
        }
    ),
    LiveSessionStatus.STARTING: frozenset(
        {
            LiveSessionStatus.ACTIVE,
            LiveSessionStatus.STOPPING,
            LiveSessionStatus.FAILED,
            LiveSessionStatus.CANCELLED,
            LiveSessionStatus.EXPIRED,
        }
    ),
    LiveSessionStatus.ACTIVE: frozenset(
        {
            LiveSessionStatus.STOPPING,
            LiveSessionStatus.FAILED,
            LiveSessionStatus.CANCELLED,
            LiveSessionStatus.EXPIRED,
        }
    ),
    LiveSessionStatus.STOPPING: frozenset(
        {
            LiveSessionStatus.CLOSED,
            LiveSessionStatus.FAILED,
            LiveSessionStatus.CANCELLED,
            LiveSessionStatus.EXPIRED,
        }
    ),
    LiveSessionStatus.CLOSED: frozenset(),
    LiveSessionStatus.FAILED: frozenset(),
    LiveSessionStatus.EXPIRED: frozenset(),
    LiveSessionStatus.CANCELLED: frozenset(),
}


def is_valid_live_transition(
    current: LiveSessionStatus, target: LiveSessionStatus
) -> bool:
    return target in LIVE_TRANSITIONS[current]


class ActionKind(str, enum.Enum):
    TAP = "tap"
    DOUBLE_TAP = "double_tap"
    TOUCH_AND_HOLD = "touch_and_hold"
    SWIPE = "swipe"
    DRAG = "drag"
    TYPE_TEXT = "type_text"
    CLEAR_TEXT = "clear_text"
    PRESS_KEY = "press_key"
    FIND = "find"
    GET_ATTRIBUTE = "get_attribute"
    SET_CONTEXT = "set_context"
    ALERT = "alert"
    LAUNCH_APP = "launch_app"
    ACTIVATE_APP = "activate_app"
    TERMINATE_APP = "terminate_app"
    QUERY_APP_STATE = "query_app_state"
    BACKGROUND_APP = "background_app"
    QA_COMMAND = "qa_command"
    SETTINGS = "settings"
    START_NETWORK_MONITOR = "start_network_monitor"
    STOP_NETWORK_MONITOR = "stop_network_monitor"


class ObservationKind(str, enum.Enum):
    SCREENSHOT = "screenshot"
    SOURCE_XML = "source_xml"
    SOURCE_JSON = "source_json"
    CONTEXTS = "contexts"
    ORIENTATION = "orientation"
    WINDOW_RECT = "window_rect"
    DEVICE_INFO = "device_info"
    BATTERY_INFO = "battery_info"
    COMBINED = "combined"


class AppiumProcessStatus(str, enum.Enum):
    STOPPED = "stopped"
    STARTING = "starting"
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"
    STOPPING = "stopping"


@dataclass(frozen=True, slots=True)
class LiveSessionRequest:
    target: Target
    lease_seconds: int
    run_id: str = field(default_factory=new_uuid)
    session_trace_id: str | None = None
    no_reset: bool = True
    auto_launch: bool = True
    language: str | None = None
    locale: str | None = None
    labels: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        normalized_run = normalize_uuid(self.run_id, "run_id")
        normalized_trace = normalize_uuid(
            self.session_trace_id or normalized_run, "session_trace_id"
        )
        object.__setattr__(self, "run_id", normalized_run)
        object.__setattr__(self, "session_trace_id", normalized_trace)

    @classmethod
    def from_dict(
        cls,
        data: Mapping[str, Any],
        *,
        default_lease_seconds: int,
        maximum_lease_seconds: int,
    ) -> "LiveSessionRequest":
        if not isinstance(data, Mapping):
            raise ValueError("live session request must be an object")
        allowed = {
            "target",
            "lease_seconds",
            "run_id",
            "session_trace_id",
            "no_reset",
            "auto_launch",
            "language",
            "locale",
            "labels",
        }
        unknown = set(data) - allowed
        if unknown:
            raise ValueError(f"unsupported live session fields: {sorted(unknown)}")
        if "target" not in data:
            raise ValueError("target is required")
        lease = _integer(
            data.get("lease_seconds", default_lease_seconds),
            "lease_seconds",
            30,
            maximum_lease_seconds,
        )
        run_id = _uuid(data.get("run_id") or new_uuid(), "run_id")
        return cls(
            target=Target.from_dict(data["target"]),
            lease_seconds=lease,
            run_id=run_id,
            session_trace_id=normalize_uuid(
                data.get("session_trace_id") or run_id, "session_trace_id"
            ),
            no_reset=_boolean(data.get("no_reset", True), "no_reset"),
            auto_launch=_boolean(data.get("auto_launch", True), "auto_launch"),
            language=_optional_code(data.get("language"), "language"),
            locale=_optional_code(data.get("locale"), "locale"),
            labels=_labels(data.get("labels")),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target.to_dict(),
            "lease_seconds": self.lease_seconds,
            "run_id": self.run_id,
            "session_trace_id": self.session_trace_id,
            "no_reset": self.no_reset,
            "auto_launch": self.auto_launch,
            "language": self.language,
            "locale": self.locale,
            "labels": dict(self.labels),
        }


@dataclass(slots=True)
class LiveSession:
    id: str
    request: LiveSessionRequest
    status: LiveSessionStatus
    created_at: float
    updated_at: float
    lease_expires_at: float
    lease_token_hash: str
    idempotency_key: str | None = None
    device_udid: str | None = None
    device_name: str | None = None
    appium_session_id: str | None = None
    appium_pid: int | None = None
    appium_port: int | None = None
    wda_port: int | None = None
    mjpeg_port: int | None = None
    wda_url: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    closed_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "request": self.request.to_dict(),
            "session_trace_id": self.request.session_trace_id,
            "status": self.status.value,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "lease_expires_at": self.lease_expires_at,
            "idempotency_key": self.idempotency_key,
            "device_udid": self.device_udid,
            "device_name": self.device_name,
            "appium_session_id": self.appium_session_id,
            "appium_pid": self.appium_pid,
            "appium_port": self.appium_port,
            "wda_port": self.wda_port,
            "mjpeg_port": self.mjpeg_port,
            "wda_url": self.wda_url,
            "error_code": self.error_code,
            "error_message": self.error_message,
            "closed_at": self.closed_at,
        }


@dataclass(frozen=True, slots=True)
class LeaseCredential:
    token: str
    token_hash: str

    @classmethod
    def create(cls) -> "LeaseCredential":
        token = secrets.token_urlsafe(32)
        return cls(token=token, token_hash=hash_lease_token(token))


def hash_lease_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(frozen=True, slots=True)
class LiveActionRequest:
    kind: ActionKind
    parameters: dict[str, Any]
    trace_id: str = field(default_factory=new_uuid)

    @classmethod
    def from_dict(
        cls, data: Mapping[str, Any], *, maximum_text_length: int
    ) -> "LiveActionRequest":
        if not isinstance(data, Mapping):
            raise ValueError("action request must be an object")
        unknown = set(data) - {"kind", "parameters", "trace_id"}
        if unknown:
            raise ValueError(f"unsupported action fields: {sorted(unknown)}")
        try:
            kind = ActionKind(data.get("kind"))
        except (TypeError, ValueError) as error:
            raise ValueError("unsupported action kind") from error
        parameters = data.get("parameters", {})
        if not isinstance(parameters, Mapping):
            raise ValueError("action parameters must be an object")
        trace_id = _uuid(data.get("trace_id") or new_uuid(), "trace_id")
        normalized = _validate_action(kind, dict(parameters), maximum_text_length)
        return cls(kind=kind, parameters=normalized, trace_id=trace_id)

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind.value, "parameters": self.parameters, "trace_id": self.trace_id}


@dataclass(frozen=True, slots=True)
class ObservationRequest:
    kind: ObservationKind
    trace_id: str = field(default_factory=new_uuid)
    persist: bool = True

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "ObservationRequest":
        if not isinstance(data, Mapping):
            raise ValueError("observation request must be an object")
        unknown = set(data) - {"kind", "trace_id", "persist"}
        if unknown:
            raise ValueError(f"unsupported observation fields: {sorted(unknown)}")
        try:
            kind = ObservationKind(data.get("kind", "combined"))
        except (TypeError, ValueError) as error:
            raise ValueError("unsupported observation kind") from error
        return cls(
            kind=kind,
            trace_id=_uuid(data.get("trace_id") or new_uuid(), "trace_id"),
            persist=_boolean(data.get("persist", True), "persist"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind.value, "trace_id": self.trace_id, "persist": self.persist}


@dataclass(frozen=True, slots=True)
class LiveEvent:
    id: int
    session_id: str
    timestamp: float
    category: str
    name: str
    trace_id: str | None
    payload: dict[str, Any]
    session_trace_id: str | None = None
    span_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "session_id": self.session_id,
            "timestamp": self.timestamp,
            "category": self.category,
            "name": self.name,
            "session_trace_id": self.session_trace_id,
            "trace_id": self.trace_id,
            "operation_trace_id": self.trace_id,
            "span_id": self.span_id,
            "payload": self.payload,
        }


@dataclass(frozen=True, slots=True)
class ActionResult:
    trace_id: str
    kind: ActionKind
    success: bool
    started_at: float
    finished_at: float
    value: Any = None
    error_code: str | None = None
    error_message: str | None = None
    session_trace_id: str | None = None
    span_id: str | None = None
    traceparent: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_trace_id": self.session_trace_id,
            "trace_id": self.trace_id,
            "operation_trace_id": self.trace_id,
            "span_id": self.span_id,
            "traceparent": self.traceparent,
            "kind": self.kind.value,
            "success": self.success,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "elapsed_ms": round((self.finished_at - self.started_at) * 1000, 3),
            "value": self.value,
            "error_code": self.error_code,
            "error_message": self.error_message,
        }


@dataclass(frozen=True, slots=True)
class ObservationResult:
    trace_id: str
    kind: ObservationKind
    captured_at: float
    sequence: int
    value: Any
    artifact_path: str | None = None
    sha256: str | None = None
    session_trace_id: str | None = None
    span_id: str | None = None
    traceparent: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_trace_id": self.session_trace_id,
            "trace_id": self.trace_id,
            "operation_trace_id": self.trace_id,
            "span_id": self.span_id,
            "traceparent": self.traceparent,
            "kind": self.kind.value,
            "captured_at": self.captured_at,
            "sequence": self.sequence,
            "value": self.value,
            "artifact_path": self.artifact_path,
            "sha256": self.sha256,
        }


def _validate_action(
    kind: ActionKind, parameters: dict[str, Any], maximum_text_length: int
) -> dict[str, Any]:
    validators = {
        ActionKind.TAP: _tap_parameters,
        ActionKind.DOUBLE_TAP: _tap_parameters,
        ActionKind.TOUCH_AND_HOLD: _hold_parameters,
        ActionKind.SWIPE: _swipe_parameters,
        ActionKind.DRAG: _drag_parameters,
        ActionKind.TYPE_TEXT: lambda value: _type_parameters(value, maximum_text_length),
        ActionKind.CLEAR_TEXT: _element_only,
        ActionKind.PRESS_KEY: _key_parameters,
        ActionKind.FIND: _find_parameters,
        ActionKind.GET_ATTRIBUTE: _attribute_parameters,
        ActionKind.SET_CONTEXT: _context_parameters,
        ActionKind.ALERT: _alert_parameters,
        ActionKind.LAUNCH_APP: _lifecycle_parameters,
        ActionKind.ACTIVATE_APP: _lifecycle_parameters,
        ActionKind.TERMINATE_APP: _lifecycle_parameters,
        ActionKind.QUERY_APP_STATE: _lifecycle_parameters,
        ActionKind.BACKGROUND_APP: _background_parameters,
        ActionKind.QA_COMMAND: lambda value: _qa_parameters(value, maximum_text_length),
        ActionKind.SETTINGS: _settings_parameters,
        ActionKind.START_NETWORK_MONITOR: _empty_parameters,
        ActionKind.STOP_NETWORK_MONITOR: _empty_parameters,
    }
    return validators[kind](parameters)


def _closed(data: dict[str, Any], allowed: set[str], context: str) -> None:
    unknown = set(data) - allowed
    if unknown:
        raise ValueError(f"unsupported {context} parameters: {sorted(unknown)}")


def _element(value: Any, *, required: bool = False) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not ELEMENT_ID_PATTERN.fullmatch(value):
        raise ValueError("element_id is invalid")
    return value


def _number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a number")
    number = float(value)
    if not math.isfinite(number) or number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def _tap_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"element_id", "x", "y"}, "tap")
    element = _element(data.get("element_id"))
    has_coordinates = "x" in data or "y" in data
    if element and has_coordinates:
        raise ValueError("tap accepts either element_id or coordinates, not both")
    if not element and not has_coordinates:
        raise ValueError("tap requires element_id or x and y")
    if has_coordinates and not {"x", "y"}.issubset(data):
        raise ValueError("tap coordinates require both x and y")
    result: dict[str, Any] = {}
    if element:
        result["element_id"] = element
    else:
        result["x"] = _number(data["x"], "x", 0, 100000)
        result["y"] = _number(data["y"], "y", 0, 100000)
    return result


def _hold_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"element_id", "x", "y", "duration"}, "touch_and_hold")
    base = _tap_parameters({key: value for key, value in data.items() if key != "duration"})
    base["duration"] = _number(data.get("duration", 1.0), "duration", 0.5, 60)
    return base


def _swipe_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"element_id", "direction", "velocity"}, "swipe")
    direction = data.get("direction")
    if direction not in {"up", "down", "left", "right"}:
        raise ValueError("swipe direction must be up, down, left, or right")
    result = {"direction": direction}
    element = _element(data.get("element_id"))
    if element:
        result["element_id"] = element
    if "velocity" in data:
        result["velocity"] = _number(data["velocity"], "velocity", 1, 100000)
    return result


def _drag_parameters(data: dict[str, Any]) -> dict[str, Any]:
    required = {"from_x", "from_y", "to_x", "to_y"}
    _closed(data, required | {"duration"}, "drag")
    if not required.issubset(data):
        raise ValueError("drag requires from_x, from_y, to_x, and to_y")
    result = {
        name: _number(data[name], name, 0, 100000)
        for name in ("from_x", "from_y", "to_x", "to_y")
    }
    result["duration"] = _number(data.get("duration", 0.5), "duration", 0, 60)
    return result


def _type_parameters(data: dict[str, Any], maximum: int) -> dict[str, Any]:
    _closed(data, {"element_id", "text"}, "type_text")
    text = data.get("text")
    if not isinstance(text, str) or len(text) > maximum:
        raise ValueError(f"text must be a string no longer than {maximum} characters")
    result = {"text": text}
    element = _element(data.get("element_id"))
    if element:
        result["element_id"] = element
    return result


def _element_only(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"element_id"}, "element")
    return {"element_id": _element(data.get("element_id"), required=True)}


def _key_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"key"}, "press_key")
    key = data.get("key")
    if key not in {"home", "volumeUp", "volumeDown"}:
        raise ValueError("key must be home, volumeUp, or volumeDown")
    return {"key": key}


def _find_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"using", "value", "multiple"}, "find")
    using = data.get("using")
    if using not in {
        "accessibility id",
        "id",
        "class name",
        "xpath",
        "-ios predicate string",
        "-ios class chain",
    }:
        raise ValueError("unsupported element locator strategy")
    value = data.get("value")
    if not isinstance(value, str) or not value or len(value) > 4096 or "\0" in value:
        raise ValueError("find value is invalid")
    return {
        "using": using,
        "value": value,
        "multiple": _boolean(data.get("multiple", False), "multiple"),
    }


def _attribute_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"element_id", "name"}, "get_attribute")
    name = data.get("name")
    if not isinstance(name, str) or not ATTRIBUTE_PATTERN.fullmatch(name):
        raise ValueError("attribute name is invalid")
    return {"element_id": _element(data.get("element_id"), required=True), "name": name}


def _context_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"name"}, "set_context")
    name = data.get("name")
    if not isinstance(name, str) or not CONTEXT_PATTERN.fullmatch(name):
        raise ValueError("context name is invalid")
    return {"name": name}


def _alert_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"action", "button_label"}, "alert")
    action = data.get("action")
    if action not in {"accept", "dismiss", "get_buttons", "get_text"}:
        raise ValueError("unsupported alert action")
    result = {"action": action}
    if "button_label" in data:
        label = data["button_label"]
        if not isinstance(label, str) or not label or len(label) > 256:
            raise ValueError("alert button_label is invalid")
        result["button_label"] = label
    return result


def _lifecycle_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"bundle_id"}, "app lifecycle")
    bundle_id = data.get("bundle_id")
    if bundle_id is None:
        return {}
    if not isinstance(bundle_id, str) or not BUNDLE_ID_PATTERN.fullmatch(bundle_id):
        raise ValueError("bundle_id is invalid")
    return {"bundle_id": bundle_id}


def _background_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, {"seconds"}, "background_app")
    return {"seconds": _number(data.get("seconds", 1), "seconds", 0, 3600)}


def _qa_parameters(data: dict[str, Any], maximum: int) -> dict[str, Any]:
    _closed(data, {"command"}, "qa_command")
    command = data.get("command")
    if not isinstance(command, Mapping):
        raise ValueError("qa_command.command must be an object")
    encoded = json.dumps(command, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > maximum:
        raise ValueError("qa_command.command is too large")
    return {"command": dict(command)}


def _empty_parameters(data: dict[str, Any]) -> dict[str, Any]:
    _closed(data, set(), "parameterless action")
    return {}


def _settings_parameters(data: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "mjpegServerFramerate": (1, 60),
        "mjpegScalingFactor": (1, 100),
        "mjpegServerScreenshotQuality": (1, 100),
        "screenshotQuality": (0, 3),
        "waitForIdleTimeout": (0, 600),
        "animationCoolOffTimeout": (0, 600),
    }
    _closed(data, set(allowed), "settings")
    if not data:
        raise ValueError("settings requires at least one supported setting")
    return {
        name: _number(value, name, minimum, maximum)
        for name, value in data.items()
        for minimum, maximum in (allowed[name],)
    }


def _integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{name} must be an integer")
    if value < minimum or value > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _uuid(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a UUID string")
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise ValueError(f"{name} must be a valid UUID") from error


def _optional_code(value: Any, name: str) -> str | None:
    if value in (None, ""):
        return None
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", value):
        raise ValueError(f"{name} contains invalid characters")
    return value


def _labels(value: Any) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, Mapping) or len(value) > 64:
        raise ValueError("labels must be an object with at most 64 entries")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", key):
            raise ValueError("invalid label key")
        if not isinstance(item, str) or len(item) > 512:
            raise ValueError(f"invalid label value for {key}")
        result[key] = item
    return result
