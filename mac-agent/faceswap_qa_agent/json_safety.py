from __future__ import annotations

import json
from typing import Any


class JSONSafetyError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def validate_json_complexity(
    value: Any,
    *,
    maximum_depth: int = 32,
    maximum_nodes: int = 10_000,
) -> None:
    if maximum_depth < 1 or maximum_nodes < 1:
        raise ValueError("JSON complexity limits must be positive")
    nodes = 0
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > maximum_nodes:
            raise JSONSafetyError(
                "json_too_complex", f"JSON exceeds {maximum_nodes} nodes"
            )
        if depth > maximum_depth:
            raise JSONSafetyError(
                "json_too_deep", f"JSON exceeds depth {maximum_depth}"
            )
        if isinstance(current, dict):
            stack.extend((nested, depth + 1) for nested in current.values())
        elif isinstance(current, (list, tuple)):
            stack.extend((nested, depth + 1) for nested in current)


def loads_bounded(
    source: str | bytes | bytearray,
    *,
    maximum_bytes: int,
    maximum_depth: int = 32,
    maximum_nodes: int = 10_000,
) -> Any:
    if maximum_bytes < 1:
        raise ValueError("maximum_bytes must be positive")
    if isinstance(source, str):
        encoded = source.encode("utf-8")
    elif isinstance(source, (bytes, bytearray)):
        encoded = bytes(source)
    else:
        raise TypeError("JSON source must be text or bytes")
    if len(encoded) > maximum_bytes:
        raise JSONSafetyError(
            "json_too_large", f"JSON exceeds {maximum_bytes} bytes"
        )
    try:
        value = json.loads(encoded)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise JSONSafetyError("invalid_json", "invalid JSON") from error
    validate_json_complexity(
        value,
        maximum_depth=maximum_depth,
        maximum_nodes=maximum_nodes,
    )
    return value
