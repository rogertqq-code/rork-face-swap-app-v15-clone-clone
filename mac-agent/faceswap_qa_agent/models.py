from __future__ import annotations

import enum
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

from .trace_context import normalize_uuid

TEST_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9_.\-/]+$")
LABEL_KEY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
UDID_PATTERN = re.compile(r"^[A-Za-z0-9-]{4,128}$")


def new_uuid() -> str:
    return str(uuid.uuid4())


def utc_timestamp() -> float:
    return time.time()


class JobStatus(str, enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def terminal(self) -> bool:
        return self in {self.SUCCEEDED, self.FAILED, self.CANCELLED}


class TargetKind(str, enum.Enum):
    SIMULATOR = "simulator"
    CABLE = "cable"


ALLOWED_TRANSITIONS: dict[JobStatus, frozenset[JobStatus]] = {
    JobStatus.QUEUED: frozenset({JobStatus.RUNNING, JobStatus.CANCELLED}),
    JobStatus.RUNNING: frozenset(
        {JobStatus.SUCCEEDED, JobStatus.FAILED, JobStatus.CANCELLED, JobStatus.QUEUED}
    ),
    JobStatus.SUCCEEDED: frozenset(),
    JobStatus.FAILED: frozenset(),
    JobStatus.CANCELLED: frozenset(),
}


def is_valid_transition(current: JobStatus, target: JobStatus) -> bool:
    return target in ALLOWED_TRANSITIONS[current]


def _optional_text(value: Any, field_name: str, maximum: int = 256) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field_name} must be a string")
    value = value.strip()
    if not value:
        return None
    if len(value) > maximum:
        raise ValueError(f"{field_name} is too long")
    return value


def _string_list(value: Any, field_name: str) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list):
        raise ValueError(f"{field_name} must be an array")
    if len(value) > 256:
        raise ValueError(f"{field_name} contains too many identifiers")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or not TEST_IDENTIFIER_PATTERN.fullmatch(item):
            raise ValueError(f"invalid test identifier in {field_name}: {item!r}")
        result.append(item)
    return tuple(result)


def _labels(value: Any) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > 64:
        raise ValueError("labels must be an object with at most 64 entries")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not LABEL_KEY_PATTERN.fullmatch(key):
            raise ValueError(f"invalid label key: {key!r}")
        if not isinstance(item, str) or len(item) > 512:
            raise ValueError(f"invalid label value for {key}")
        result[key] = item
    return result


@dataclass(frozen=True, slots=True)
class Target:
    kind: TargetKind
    udid: str | None = None
    name: str | None = None
    os: str = "latest"

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "Target":
        if not isinstance(data, Mapping):
            raise ValueError("target must be an object")
        unknown = set(data) - {"kind", "udid", "name", "os"}
        if unknown:
            raise ValueError(f"unsupported target fields: {sorted(unknown)}")
        try:
            kind = TargetKind(data.get("kind"))
        except (TypeError, ValueError) as error:
            raise ValueError("target.kind must be simulator or cable") from error
        udid = _optional_text(data.get("udid"), "target.udid", 128)
        if udid and not UDID_PATTERN.fullmatch(udid):
            raise ValueError("target.udid contains unsupported characters")
        name = _optional_text(data.get("name"), "target.name", 128)
        os_version = _optional_text(data.get("os", "latest"), "target.os", 64) or "latest"
        return cls(kind=kind, udid=udid, name=name, os=os_version)

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind.value, "udid": self.udid, "name": self.name, "os": self.os}


@dataclass(frozen=True, slots=True)
class JobRequest:
    target: Target
    run_id: str = field(default_factory=new_uuid)
    session_trace_id: str | None = None
    only_testing: tuple[str, ...] = ()
    skip_testing: tuple[str, ...] = ()
    timeout_seconds: int = 1800
    max_retries: int = 0
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
        default_timeout: int = 1800,
        maximum_timeout: int = 7200,
        maximum_retries: int = 2,
    ) -> "JobRequest":
        if not isinstance(data, Mapping):
            raise ValueError("request body must be an object")
        allowed = {
            "target",
            "run_id",
            "session_trace_id",
            "only_testing",
            "skip_testing",
            "timeout_seconds",
            "max_retries",
            "labels",
        }
        unknown = set(data) - allowed
        if unknown:
            raise ValueError(f"unsupported job fields: {sorted(unknown)}")
        if "target" not in data:
            raise ValueError("target is required")
        run_id = data.get("run_id") or new_uuid()
        if not isinstance(run_id, str):
            raise ValueError("run_id must be a UUID string")
        try:
            run_id = str(uuid.UUID(run_id))
        except ValueError as error:
            raise ValueError("run_id must be a valid UUID") from error
        timeout = data.get("timeout_seconds", default_timeout)
        retries = data.get("max_retries", 0)
        if isinstance(timeout, bool) or not isinstance(timeout, int):
            raise ValueError("timeout_seconds must be an integer")
        if timeout < 1 or timeout > maximum_timeout:
            raise ValueError(f"timeout_seconds must be between 1 and {maximum_timeout}")
        if isinstance(retries, bool) or not isinstance(retries, int):
            raise ValueError("max_retries must be an integer")
        if retries < 0 or retries > maximum_retries:
            raise ValueError(f"max_retries must be between 0 and {maximum_retries}")
        return cls(
            target=Target.from_dict(data["target"]),
            run_id=run_id,
            session_trace_id=normalize_uuid(
                data.get("session_trace_id") or run_id, "session_trace_id"
            ),
            only_testing=_string_list(data.get("only_testing"), "only_testing"),
            skip_testing=_string_list(data.get("skip_testing"), "skip_testing"),
            timeout_seconds=timeout,
            max_retries=retries,
            labels=_labels(data.get("labels")),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target.to_dict(),
            "run_id": self.run_id,
            "session_trace_id": self.session_trace_id,
            "only_testing": list(self.only_testing),
            "skip_testing": list(self.skip_testing),
            "timeout_seconds": self.timeout_seconds,
            "max_retries": self.max_retries,
            "labels": dict(self.labels),
        }


@dataclass(slots=True)
class Job:
    id: str
    status: JobStatus
    request: JobRequest
    created_at: float
    updated_at: float
    attempt: int = 0
    pid: int | None = None
    exit_code: int | None = None
    error_code: str | None = None
    error_message: str | None = None
    cancel_requested: bool = False
    idempotency_key: str | None = None
    result_path: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "status": self.status.value,
            "request": self.request.to_dict(),
            "session_trace_id": self.request.session_trace_id,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "attempt": self.attempt,
            "pid": self.pid,
            "exit_code": self.exit_code,
            "error_code": self.error_code,
            "error_message": self.error_message,
            "cancel_requested": self.cancel_requested,
            "idempotency_key": self.idempotency_key,
            "result_path": self.result_path,
        }


@dataclass(frozen=True, slots=True)
class DeviceInfo:
    kind: TargetKind
    udid: str
    name: str
    os_version: str
    device_type: str
    ready: bool
    readiness_reasons: tuple[str, ...] = ()
    identifier: str | None = None
    transport: str | None = None
    pairing_state: str | None = None
    developer_mode: str | None = None
    state: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind.value,
            "udid": self.udid,
            "name": self.name,
            "os_version": self.os_version,
            "device_type": self.device_type,
            "ready": self.ready,
            "readiness_reasons": list(self.readiness_reasons),
            "identifier": self.identifier,
            "transport": self.transport,
            "pairing_state": self.pairing_state,
            "developer_mode": self.developer_mode,
            "state": self.state,
        }


@dataclass(frozen=True, slots=True)
class Artifact:
    path: str
    kind: str
    byte_size: int
    sha256: str
    created_at: float = field(default_factory=utc_timestamp)
    session_trace_id: str | None = None
    operation_trace_id: str | None = None
    span_id: str | None = None
    content_type: str | None = None
    provenance: str = "agent"
    redaction_state: str = "not_applicable"

    def __post_init__(self) -> None:
        if self.session_trace_id is not None:
            object.__setattr__(
                self,
                "session_trace_id",
                normalize_uuid(self.session_trace_id, "session_trace_id"),
            )
        if self.operation_trace_id is not None:
            object.__setattr__(
                self,
                "operation_trace_id",
                normalize_uuid(self.operation_trace_id, "operation_trace_id"),
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "kind": self.kind,
            "byte_size": self.byte_size,
            "sha256": self.sha256,
            "created_at": self.created_at,
            "session_trace_id": self.session_trace_id,
            "operation_trace_id": self.operation_trace_id,
            "span_id": self.span_id,
            "content_type": self.content_type,
            "provenance": self.provenance,
            "redaction_state": self.redaction_state,
        }


@dataclass(frozen=True, slots=True)
class RunResult:
    success: bool
    exit_code: int | None
    error_code: str | None
    error_message: str | None
    result_path: str | None
    artifacts: tuple[Artifact, ...] = ()


TRANSIENT_ERROR_CODES = frozenset(
    {"device_unavailable", "simulator_unavailable", "timeout", "xcodebuild_interrupted"}
)


def serialize_devices(devices: Sequence[DeviceInfo]) -> list[dict[str, Any]]:
    return [device.to_dict() for device in devices]
