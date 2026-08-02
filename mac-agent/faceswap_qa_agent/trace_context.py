from __future__ import annotations

import re
import secrets
import uuid
from dataclasses import dataclass
from typing import Any

_TRACEPARENT_PATTERN = re.compile(
    r"^00-([0-9a-fA-F]{32})-([0-9a-fA-F]{16})-([0-9a-fA-F]{2})$"
)
_SPAN_PATTERN = re.compile(r"^[0-9a-f]{16}$")
_ZERO_TRACE = "0" * 32
_ZERO_SPAN = "0" * 16


class TraceContextError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class ParsedTraceparent:
    session_trace_id: str
    span_id: str
    flags: str

    @property
    def sampled(self) -> bool:
        return bool(int(self.flags, 16) & 0x01)

    def to_string(self) -> str:
        return (
            f"00-{uuid.UUID(self.session_trace_id).hex}-"
            f"{self.span_id}-{self.flags}"
        )


@dataclass(frozen=True, slots=True)
class TraceContext:
    session_trace_id: str
    operation_trace_id: str
    span_id: str
    traceparent: str
    sampled: bool

    @classmethod
    def create(
        cls,
        *,
        session_trace_id: str | None = None,
        operation_trace_id: str | None = None,
        span_id: str | None = None,
        traceparent: str | None = None,
        sampled: bool = True,
    ) -> "TraceContext":
        parsed: ParsedTraceparent | None = None
        if traceparent not in (None, ""):
            parsed = parse_traceparent(traceparent)

        normalized_session = (
            normalize_uuid(session_trace_id, "session_trace_id")
            if session_trace_id not in (None, "")
            else None
        )
        if parsed is not None:
            if (
                normalized_session is not None
                and normalized_session != parsed.session_trace_id
            ):
                raise TraceContextError(
                    "trace_root_mismatch",
                    "explicit session trace ID does not match traceparent root",
                )
            normalized_session = parsed.session_trace_id
            sampled = parsed.sampled

        if normalized_session is None:
            normalized_session = str(uuid.uuid4())

        normalized_operation = (
            normalize_uuid(operation_trace_id, "operation_trace_id")
            if operation_trace_id not in (None, "")
            else str(uuid.uuid4())
        )

        if span_id not in (None, ""):
            normalized_span = normalize_span_id(span_id)
            if parsed is not None and normalized_span != parsed.span_id:
                raise TraceContextError(
                    "trace_span_mismatch",
                    "explicit span ID does not match traceparent span",
                )
        elif parsed is not None:
            normalized_span = parsed.span_id
        else:
            normalized_span = new_span_id()

        normalized_parent = format_traceparent(
            normalized_session, normalized_span, sampled=sampled
        )
        return cls(
            session_trace_id=normalized_session,
            operation_trace_id=normalized_operation,
            span_id=normalized_span,
            traceparent=normalized_parent,
            sampled=sampled,
        )

    @classmethod
    def from_document(
        cls, data: dict[str, Any], *, expected_session_trace_id: str | None = None
    ) -> "TraceContext":
        if not isinstance(data, dict):
            raise TraceContextError(
                "trace_document_invalid", "trace context must be an object"
            )
        unknown = set(data) - {
            "session_trace_id",
            "operation_trace_id",
            "span_id",
            "traceparent",
            "sampled",
        }
        if unknown:
            raise TraceContextError(
                "trace_document_invalid",
                f"unsupported trace context fields: {sorted(unknown)}",
            )
        sampled = data.get("sampled", True)
        if not isinstance(sampled, bool):
            raise TraceContextError(
                "trace_document_invalid", "sampled must be a boolean"
            )
        context = cls.create(
            session_trace_id=data.get("session_trace_id"),
            operation_trace_id=data.get("operation_trace_id"),
            span_id=data.get("span_id"),
            traceparent=data.get("traceparent"),
            sampled=sampled,
        )
        if expected_session_trace_id is not None:
            context.require_session(expected_session_trace_id)
        return context

    def child(self, *, operation_trace_id: str | None = None) -> "TraceContext":
        return TraceContext.create(
            session_trace_id=self.session_trace_id,
            operation_trace_id=operation_trace_id,
            span_id=new_span_id(),
            sampled=self.sampled,
        )

    def require_session(self, expected_session_trace_id: str) -> None:
        expected = normalize_uuid(expected_session_trace_id, "session_trace_id")
        if self.session_trace_id != expected:
            raise TraceContextError(
                "trace_root_mismatch",
                "trace context belongs to a different session root",
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_trace_id": self.session_trace_id,
            "operation_trace_id": self.operation_trace_id,
            "span_id": self.span_id,
            "traceparent": self.traceparent,
            "sampled": self.sampled,
        }


def normalize_uuid(value: Any, name: str = "trace_id") -> str:
    if not isinstance(value, str):
        raise TraceContextError(f"{name}_invalid", f"{name} must be a UUID string")
    try:
        normalized = str(uuid.UUID(value))
    except (ValueError, AttributeError) as error:
        raise TraceContextError(
            f"{name}_invalid", f"{name} must be a valid UUID"
        ) from error
    if uuid.UUID(normalized).int == 0:
        raise TraceContextError(
            f"{name}_invalid", f"{name} cannot be the all-zero UUID"
        )
    return normalized


def normalize_span_id(value: Any) -> str:
    if not isinstance(value, str):
        raise TraceContextError("span_id_invalid", "span_id must be a hex string")
    normalized = value.lower()
    if not _SPAN_PATTERN.fullmatch(normalized) or normalized == _ZERO_SPAN:
        raise TraceContextError(
            "span_id_invalid",
            "span_id must be 16 non-zero lowercase hexadecimal characters",
        )
    return normalized


def new_span_id() -> str:
    while True:
        candidate = secrets.token_hex(8)
        if candidate != _ZERO_SPAN:
            return candidate


def parse_traceparent(value: Any) -> ParsedTraceparent:
    if not isinstance(value, str):
        raise TraceContextError(
            "traceparent_invalid", "traceparent must be a string"
        )
    match = _TRACEPARENT_PATTERN.fullmatch(value.strip())
    if match is None:
        raise TraceContextError(
            "traceparent_invalid",
            "traceparent must use version 00 with 32-hex trace, 16-hex span, and 2-hex flags",
        )
    trace_hex, span_id, flags = (item.lower() for item in match.groups())
    if trace_hex == _ZERO_TRACE or span_id == _ZERO_SPAN:
        raise TraceContextError(
            "traceparent_invalid", "traceparent identifiers cannot be all zero"
        )
    if int(flags, 16) & 0xFE:
        raise TraceContextError(
            "traceparent_invalid", "traceparent version 00 supports only flag 00 or 01"
        )
    return ParsedTraceparent(
        session_trace_id=str(uuid.UUID(hex=trace_hex)),
        span_id=span_id,
        flags=flags,
    )


def format_traceparent(
    session_trace_id: str, span_id: str, *, sampled: bool = True
) -> str:
    normalized_session = normalize_uuid(session_trace_id, "session_trace_id")
    normalized_span = normalize_span_id(span_id)
    flags = "01" if sampled else "00"
    return f"00-{uuid.UUID(normalized_session).hex}-{normalized_span}-{flags}"
