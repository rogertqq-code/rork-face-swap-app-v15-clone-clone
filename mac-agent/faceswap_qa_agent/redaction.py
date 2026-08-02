from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, Iterable

from .json_safety import JSONSafetyError, loads_bounded

_CORRELATION_KEYS = frozenset(
    {
        "run_id",
        "session_id",
        "job_id",
        "session_trace_id",
        "trace_id",
        "operation_trace_id",
        "span_id",
        "traceparent",
        "bundle_id",
        "recovery_id",
        "command_id",
    }
)
_SENSITIVE_KEY_MARKERS = (
    "authorization",
    "api_key",
    "apikey",
    "cookie",
    "credential",
    "password",
    "private_key",
    "secret",
    "session_token",
    "token",
)
_BEARER_PATTERN = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}")
_HEADER_PATTERN = re.compile(
    r"(?im)^(Authorization|Proxy-Authorization|Cookie|Set-Cookie)\s*:\s*[^\r\n]*$"
)
_ASSIGNMENT_PATTERN = re.compile(
    r"(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|token|authorization|credential)"
    r"\s*[:=]\s*([^\s,;]+)"
)


@dataclass(frozen=True, slots=True)
class RedactionPolicy:
    maximum_depth: int = 24
    maximum_nodes: int = 5000
    maximum_string_bytes: int = 65536
    maximum_text_bytes: int = 1024 * 1024
    sensitive_key_markers: tuple[str, ...] = _SENSITIVE_KEY_MARKERS
    extra_text_patterns: tuple[re.Pattern[str], ...] = ()

    def __post_init__(self) -> None:
        if self.maximum_depth < 1:
            raise ValueError("maximum_depth must be positive")
        if self.maximum_nodes < 1:
            raise ValueError("maximum_nodes must be positive")
        if self.maximum_string_bytes < 1 or self.maximum_text_bytes < 1:
            raise ValueError("redaction byte limits must be positive")


DEFAULT_REDACTION_POLICY = RedactionPolicy()


def digest_metadata(value: Any, *, reason: str = "sensitive") -> dict[str, Any]:
    encoded = _stable_bytes(value)
    return {
        "redacted": True,
        "reason": reason,
        "byte_size": len(encoded),
        "sha256": hashlib.sha256(encoded).hexdigest(),
    }


def redact_structured(
    value: Any, *, policy: RedactionPolicy = DEFAULT_REDACTION_POLICY
) -> Any:
    nodes = 0

    def visit(current: Any, *, key: str | None, depth: int) -> Any:
        nonlocal nodes
        nodes += 1
        if nodes > policy.maximum_nodes:
            return digest_metadata(current, reason="node_limit")
        if depth > policy.maximum_depth:
            return digest_metadata(current, reason="depth_limit")

        normalized_key = (key or "").lower()
        if normalized_key in _CORRELATION_KEYS:
            return _bounded_identifier(current, policy.maximum_string_bytes)
        if normalized_key and _sensitive_key(
            normalized_key, policy.sensitive_key_markers
        ):
            return digest_metadata(current)

        if isinstance(current, dict):
            return {
                str(item_key): visit(
                    item_value, key=str(item_key), depth=depth + 1
                )
                for item_key, item_value in sorted(
                    current.items(), key=lambda item: str(item[0])
                )
            }
        if isinstance(current, (list, tuple)):
            return [visit(item, key=None, depth=depth + 1) for item in current]
        if isinstance(current, str):
            encoded = current.encode("utf-8", errors="replace")
            if len(encoded) > policy.maximum_string_bytes:
                return digest_metadata(current, reason="string_limit")
            stripped = current.lstrip()
            if stripped.startswith(("{", "[")):
                try:
                    nested = loads_bounded(
                        current,
                        maximum_bytes=policy.maximum_string_bytes,
                        maximum_depth=policy.maximum_depth,
                        maximum_nodes=policy.maximum_nodes,
                    )
                except JSONSafetyError:
                    pass
                else:
                    redacted = visit(nested, key=None, depth=depth + 1)
                    return json.dumps(
                        redacted,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=False,
                    )
            return redact_text(current, policy=policy)
        if current is None or isinstance(current, (bool, int, float)):
            return current
        return digest_metadata(repr(current), reason="unsupported_type")

    return visit(value, key=None, depth=1)


def redact_text(
    text: str, *, policy: RedactionPolicy = DEFAULT_REDACTION_POLICY
) -> str:
    if not isinstance(text, str):
        raise TypeError("text must be a string")
    encoded = text.encode("utf-8", errors="replace")
    truncated = len(encoded) > policy.maximum_text_bytes
    if truncated:
        encoded = encoded[: policy.maximum_text_bytes]
        text = encoded.decode("utf-8", errors="ignore")

    value = _BEARER_PATTERN.sub("Bearer [REDACTED]", text)
    value = _HEADER_PATTERN.sub(lambda match: f"{match.group(1)}: [REDACTED]", value)
    value = _ASSIGNMENT_PATTERN.sub(
        lambda match: (
            f"{match.group(1)}: [REDACTED]"
            if match.group(1).lower() == "authorization"
            else f"{match.group(1)}=[REDACTED]"
        ),
        value,
    )
    for pattern in policy.extra_text_patterns:
        value = pattern.sub("[REDACTED]", value)
    if truncated:
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        value += f"\n[TRUNCATED sha256={digest}]"
    return value


def redact_lines(
    lines: Iterable[str], *, policy: RedactionPolicy = DEFAULT_REDACTION_POLICY
) -> list[str]:
    result: list[str] = []
    consumed = 0
    for line in lines:
        encoded = line.encode("utf-8", errors="replace")
        if consumed + len(encoded) > policy.maximum_text_bytes:
            remaining = max(0, policy.maximum_text_bytes - consumed)
            if remaining:
                result.append(
                    redact_text(
                        encoded[:remaining].decode("utf-8", errors="ignore"),
                        policy=policy,
                    )
                )
            result.append("[TRUNCATED]")
            break
        result.append(redact_text(line, policy=policy))
        consumed += len(encoded)
    return result


def _sensitive_key(key: str, markers: tuple[str, ...]) -> bool:
    normalized = key.lower().replace("-", "_")
    return any(marker in normalized for marker in markers)


def _stable_bytes(value: Any) -> bytes:
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return value.encode("utf-8", errors="replace")
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            default=repr,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError):
        return repr(value).encode("utf-8", errors="replace")


def _bounded_identifier(value: Any, maximum_bytes: int) -> Any:
    if isinstance(value, str) and len(value.encode("utf-8")) <= maximum_bytes:
        return value
    if value is None:
        return None
    return digest_metadata(value, reason="invalid_correlation_identifier")
