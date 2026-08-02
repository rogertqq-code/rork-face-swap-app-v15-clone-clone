from __future__ import annotations

import enum
import json
import math
import uuid
from dataclasses import dataclass, field, replace
from typing import Any, Mapping

from .redaction import redact_structured
from .trace_context import TraceContext, normalize_uuid

RECOVERY_SCHEMA_VERSION = 1


class RecoveryCause(str, enum.Enum):
    AGENT_RESTARTED = "agent_restarted"
    APPIUM_CRASHED = "appium_crashed"
    WDA_UNHEALTHY = "wda_unhealthy"
    DEVICE_DISCONNECTED = "device_disconnected"
    TRUST_LOST = "trust_lost"
    DEVELOPER_MODE_LOST = "developer_mode_lost"
    BIDI_DISCONNECTED = "bidi_disconnected"
    MJPEG_DISCONNECTED = "mjpeg_disconnected"
    LEASE_EXPIRED = "lease_expired"
    STALE_PROCESS = "stale_process"
    EVIDENCE_CORRUPT = "evidence_corrupt"


class RecoveryOutcome(str, enum.Enum):
    OBSERVED = "observed"
    RECOVERED = "recovered"
    DEGRADED = "degraded"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def terminal(self) -> bool:
        return self is not RecoveryOutcome.OBSERVED


class RecoveryError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class RecoveryEpisode:
    recovery_id: str
    owner_type: str
    owner_id: str
    session_trace_id: str
    operation_trace_id: str
    span_id: str
    traceparent: str
    cause: RecoveryCause
    outcome: RecoveryOutcome
    started_at: float
    finished_at: float | None = None
    attempt: int = 1
    details: dict[str, Any] = field(default_factory=dict)
    evidence_paths: tuple[str, ...] = ()
    error_code: str | None = None
    error_message: str | None = None

    @classmethod
    def start(
        cls,
        *,
        owner_type: str,
        owner_id: str,
        session_trace_id: str,
        cause: RecoveryCause | str,
        started_at: float,
        attempt: int = 1,
        details: Mapping[str, Any] | None = None,
    ) -> "RecoveryEpisode":
        if owner_type not in {"job", "live_session"}:
            raise RecoveryError("owner_invalid", "unsupported recovery owner type")
        if not isinstance(owner_id, str) or not owner_id or len(owner_id) > 256:
            raise RecoveryError("owner_invalid", "recovery owner ID is invalid")
        try:
            normalized_cause = RecoveryCause(cause)
        except (TypeError, ValueError) as error:
            raise RecoveryError("cause_invalid", "unsupported recovery cause") from error
        if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= 100:
            raise RecoveryError("attempt_invalid", "recovery attempt must be 1 through 100")
        context = TraceContext.create(session_trace_id=session_trace_id)
        return cls(
            recovery_id=str(uuid.uuid4()),
            owner_type=owner_type,
            owner_id=owner_id,
            session_trace_id=context.session_trace_id,
            operation_trace_id=context.operation_trace_id,
            span_id=context.span_id,
            traceparent=context.traceparent,
            cause=normalized_cause,
            outcome=RecoveryOutcome.OBSERVED,
            started_at=_timestamp(started_at, "started_at"),
            attempt=attempt,
            details=_details(details or {}),
        )

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "RecoveryEpisode":
        if not isinstance(data, Mapping):
            raise RecoveryError("episode_invalid", "recovery episode must be an object")
        try:
            outcome = RecoveryOutcome(data["outcome"])
            cause = RecoveryCause(data["cause"])
        except (KeyError, TypeError, ValueError) as error:
            raise RecoveryError("episode_invalid", "invalid recovery cause or outcome") from error
        context = TraceContext.create(
            session_trace_id=data.get("session_trace_id"),
            operation_trace_id=data.get("operation_trace_id"),
            span_id=data.get("span_id"),
            traceparent=data.get("traceparent"),
        )
        episode = cls(
            recovery_id=normalize_uuid(data.get("recovery_id"), "recovery_id"),
            owner_type=str(data.get("owner_type", "")),
            owner_id=str(data.get("owner_id", "")),
            session_trace_id=context.session_trace_id,
            operation_trace_id=context.operation_trace_id,
            span_id=context.span_id,
            traceparent=context.traceparent,
            cause=cause,
            outcome=outcome,
            started_at=_timestamp(data.get("started_at"), "started_at"),
            finished_at=(
                _timestamp(data["finished_at"], "finished_at")
                if data.get("finished_at") is not None
                else None
            ),
            attempt=int(data.get("attempt", 1)),
            details=_details(data.get("details", {})),
            evidence_paths=_evidence_paths(data.get("evidence_paths", [])),
            error_code=_optional_text(data.get("error_code"), 256),
            error_message=_optional_text(data.get("error_message"), 2048),
        )
        episode.validate()
        return episode

    def finish(
        self,
        *,
        outcome: RecoveryOutcome | str,
        finished_at: float,
        details: Mapping[str, Any] | None = None,
        evidence_paths: tuple[str, ...] | list[str] = (),
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> "RecoveryEpisode":
        if self.outcome.terminal:
            raise RecoveryError(
                "episode_terminal", "recovery episode is already terminal"
            )
        try:
            normalized_outcome = RecoveryOutcome(outcome)
        except (TypeError, ValueError) as error:
            raise RecoveryError("outcome_invalid", "unsupported recovery outcome") from error
        if not normalized_outcome.terminal:
            raise RecoveryError(
                "outcome_invalid", "recovery completion requires a terminal outcome"
            )
        finished = _timestamp(finished_at, "finished_at")
        if finished < self.started_at:
            raise RecoveryError(
                "timestamp_invalid", "recovery finish precedes start"
            )
        merged = dict(self.details)
        if details:
            merged.update(dict(details))
        result = replace(
            self,
            outcome=normalized_outcome,
            finished_at=finished,
            details=_details(merged),
            evidence_paths=_evidence_paths(evidence_paths),
            error_code=_optional_text(error_code, 256),
            error_message=_optional_text(error_message, 2048),
        )
        result.validate()
        return result

    @property
    def duration_ms(self) -> float | None:
        if self.finished_at is None:
            return None
        return round((self.finished_at - self.started_at) * 1000, 3)

    def validate(self) -> None:
        normalize_uuid(self.recovery_id, "recovery_id")
        normalize_uuid(self.session_trace_id, "session_trace_id")
        if self.outcome.terminal and self.finished_at is None:
            raise RecoveryError(
                "episode_invalid", "terminal recovery requires finished_at"
            )
        if not self.outcome.terminal and self.finished_at is not None:
            raise RecoveryError(
                "episode_invalid", "observed recovery cannot have finished_at"
            )
        if self.finished_at is not None and self.finished_at < self.started_at:
            raise RecoveryError(
                "episode_invalid", "recovery finish precedes start"
            )
        if self.owner_type not in {"job", "live_session"}:
            raise RecoveryError("episode_invalid", "invalid recovery owner type")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": RECOVERY_SCHEMA_VERSION,
            "recovery_id": self.recovery_id,
            "owner_type": self.owner_type,
            "owner_id": self.owner_id,
            "session_trace_id": self.session_trace_id,
            "operation_trace_id": self.operation_trace_id,
            "span_id": self.span_id,
            "traceparent": self.traceparent,
            "cause": self.cause.value,
            "outcome": self.outcome.value,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "duration_ms": self.duration_ms,
            "attempt": self.attempt,
            "details": self.details,
            "evidence_paths": list(self.evidence_paths),
            "error_code": self.error_code,
            "error_message": self.error_message,
        }


def summarize_recoveries(
    episodes: list[RecoveryEpisode] | tuple[RecoveryEpisode, ...]
) -> dict[str, Any]:
    causes: dict[str, int] = {}
    outcomes: dict[str, int] = {}
    durations: list[float] = []
    for episode in episodes:
        episode.validate()
        causes[episode.cause.value] = causes.get(episode.cause.value, 0) + 1
        outcomes[episode.outcome.value] = outcomes.get(episode.outcome.value, 0) + 1
        if episode.duration_ms is not None:
            durations.append(episode.duration_ms)
    return {
        "count": len(episodes),
        "causes": dict(sorted(causes.items())),
        "outcomes": dict(sorted(outcomes.items())),
        "open": sum(not episode.outcome.terminal for episode in episodes),
        "duration_ms": {
            "minimum": min(durations) if durations else None,
            "maximum": max(durations) if durations else None,
            "average": round(sum(durations) / len(durations), 3)
            if durations
            else None,
        },
    }


def _details(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise RecoveryError("details_invalid", "recovery details must be an object")
    try:
        raw = json.dumps(
            dict(value),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            default=repr,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise RecoveryError(
            "details_invalid", "recovery details are not serializable"
        ) from error
    if len(raw) > 65536:
        raise RecoveryError(
            "details_too_large", "recovery details exceed 65536 bytes"
        )
    redacted = redact_structured(dict(value))
    encoded = json.dumps(
        redacted,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    if len(encoded) > 65536:
        raise RecoveryError(
            "details_too_large", "recovery details exceed 65536 bytes"
        )
    return redacted


def _evidence_paths(value: Any) -> tuple[str, ...]:
    if not isinstance(value, (list, tuple)) or len(value) > 128:
        raise RecoveryError(
            "evidence_invalid", "recovery evidence paths must be a bounded array"
        )
    result: list[str] = []
    for item in value:
        if (
            not isinstance(item, str)
            or not item
            or item.startswith(("/", "\\"))
            or ".." in item.replace("\\", "/").split("/")
            or len(item) > 4096
        ):
            raise RecoveryError(
                "evidence_invalid", "recovery evidence path is invalid"
            )
        result.append(item.replace("\\", "/"))
    return tuple(sorted(set(result)))


def _timestamp(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RecoveryError("timestamp_invalid", f"{name} must be numeric")
    normalized = float(value)
    if not math.isfinite(normalized) or normalized < 0:
        raise RecoveryError("timestamp_invalid", f"{name} must be finite and nonnegative")
    return normalized


def _optional_text(value: Any, maximum: int) -> str | None:
    if value in (None, ""):
        return None
    if not isinstance(value, str) or len(value) > maximum or "\0" in value:
        raise RecoveryError("text_invalid", "recovery text field is invalid")
    return value
