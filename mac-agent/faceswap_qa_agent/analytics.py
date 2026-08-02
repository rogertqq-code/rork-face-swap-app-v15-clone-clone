from __future__ import annotations

import math
from collections import Counter, defaultdict
from typing import Any, Iterable, Mapping, Sequence

ANALYTICS_SCHEMA_VERSION = 1
_SOURCE_PRIORITIES = {
    "agent": 10,
    "appium": 20,
    "wda": 30,
    "bidi": 40,
    "ios": 50,
    "mjpeg": 60,
    "xcode": 70,
}
_TERMINAL_RECOVERY_OUTCOMES = frozenset(
    {"recovered", "degraded", "failed", "cancelled"}
)
_SENSITIVE_MARKERS = (
    "authorization",
    "password",
    "secret",
    "token",
    "cookie",
    "credential",
    "api_key",
    "apikey",
)


class AnalyticsError(ValueError):
    pass


def nearest_rank(values: Sequence[float], percentile: int) -> float | None:
    if not values:
        return None
    if percentile < 0 or percentile > 100:
        raise AnalyticsError("percentile must be between zero and 100")
    normalized = sorted(_finite(value, "latency") for value in values)
    if percentile == 0:
        return normalized[0]
    rank = max(1, math.ceil(percentile / 100 * len(normalized)))
    return normalized[rank - 1]


def build_analytics(
    *,
    events: Iterable[Mapping[str, Any]],
    recovery_episodes: Iterable[Mapping[str, Any]] = (),
    evidence_manifest: Mapping[str, Any] | None = None,
    expected_session_trace_id: str | None = None,
    active_device_owner_count: int | None = None,
    environmental_gates: Iterable[str] = (),
) -> dict[str, Any]:
    event_documents = [_event_document(item, index) for index, item in enumerate(events)]
    timeline = sorted(event_documents, key=_timeline_key)
    recovery_documents = [dict(item) for item in recovery_episodes]
    manifest = dict(evidence_manifest or {})

    latency_values = [
        latency
        for event in timeline
        for latency in [_latency_ms(event)]
        if latency is not None
    ]
    errors_by_component: Counter[str] = Counter()
    errors_by_code: Counter[str] = Counter()
    for event in timeline:
        code = _error_code(event)
        if code is not None:
            errors_by_component[str(event.get("component", event.get("source", "unknown")))] += 1
            errors_by_code[code] += 1

    recovery_causes = Counter(str(item.get("cause", "unknown")) for item in recovery_documents)
    recovery_outcomes = Counter(str(item.get("outcome", "unknown")) for item in recovery_documents)
    recovery_latencies = [
        duration
        for item in recovery_documents
        for duration in [_recovery_duration_ms(item)]
        if duration is not None
    ]

    trace_roots = _trace_roots(timeline, recovery_documents, manifest)
    expected_root = expected_session_trace_id or manifest.get("session_trace_id")
    root_continuity = (
        not trace_roots
        or (
            len(trace_roots) == 1
            and (expected_root is None or trace_roots == {expected_root})
        )
    )
    sequence_valid, sequence_failures = _monotonic_sequences(timeline)
    hash_valid, hash_failures = _artifact_hashes(manifest)
    recovery_valid, recovery_failures = _closed_recoveries(recovery_documents)
    redaction_valid, redaction_failures = _summary_redaction(timeline)
    owner_valid = active_device_owner_count in (None, 0, 1)
    correlation_valid, correlation_failures = _command_correlation(timeline)
    terminal_evidence_valid = manifest.get("status") in {"complete", "partial", "corrupt"}

    invariants = {
        "root_trace_continuity": _invariant(root_continuity, sorted(trace_roots)),
        "monotonic_per_source_sequences": _invariant(sequence_valid, sequence_failures),
        "no_artifact_hash_mismatch": _invariant(hash_valid, hash_failures),
        "no_unclosed_recovery_episode": _invariant(recovery_valid, recovery_failures),
        "no_plaintext_secret_marker_in_summaries": _invariant(
            redaction_valid, redaction_failures
        ),
        "one_active_device_owner": _invariant(
            owner_valid,
            [] if owner_valid else [f"active_owner_count={active_device_owner_count}"],
        ),
        "command_result_correlation": _invariant(
            correlation_valid, correlation_failures
        ),
        "terminal_evidence_generation": _invariant(
            terminal_evidence_valid,
            [] if terminal_evidence_valid else ["evidence manifest is missing"],
        ),
    }

    failures = [name for name, value in invariants.items() if not value["passed"]]
    gates = sorted({str(item)[:256] for item in environmental_gates if str(item).strip()})
    if failures:
        qualification = "fail"
    elif gates or not timeline or manifest.get("status") != "complete":
        qualification = "incomplete"
    else:
        qualification = "pass"

    return {
        "schema_version": ANALYTICS_SCHEMA_VERSION,
        "session_trace_id": expected_root,
        "timeline": timeline,
        "latency_ms": _latency_summary(latency_values),
        "errors": {
            "by_component": dict(sorted(errors_by_component.items())),
            "by_code": dict(sorted(errors_by_code.items())),
            "total": sum(errors_by_code.values()),
        },
        "counts": {
            "events": len(timeline),
            "artifacts": len(manifest.get("artifacts", []))
            if isinstance(manifest.get("artifacts", []), list)
            else 0,
            "recoveries": len(recovery_documents),
        },
        "recovery": {
            "causes": dict(sorted(recovery_causes.items())),
            "outcomes": dict(sorted(recovery_outcomes.items())),
            "latency_ms": _latency_summary(recovery_latencies),
        },
        "evidence": {
            "status": manifest.get("status", "missing"),
            "complete": manifest.get("status") == "complete",
            "reasons": list(manifest.get("reasons", []))
            if isinstance(manifest.get("reasons", []), list)
            else ["invalid evidence reasons"],
        },
        "invariants": invariants,
        "qualification": {
            "status": qualification,
            "failed_invariants": failures,
            "environmental_gates": gates,
        },
    }


def _event_document(item: Mapping[str, Any], index: int) -> dict[str, Any]:
    if not isinstance(item, Mapping):
        raise AnalyticsError("event must be an object")
    document = dict(item)
    document.setdefault("source", "agent")
    document.setdefault("source_priority", _SOURCE_PRIORITIES.get(str(document["source"]), 99))
    document.setdefault("sequence", index)
    document.setdefault("event_id", document.get("id", index))
    document["timestamp"] = _finite(document.get("timestamp", 0.0), "timestamp")
    return document


def _timeline_key(event: Mapping[str, Any]) -> tuple[Any, ...]:
    return (
        float(event["timestamp"]),
        int(event.get("source_priority", 99)),
        int(event.get("sequence", 0)),
        str(event.get("event_id", "")),
    )


def _latency_ms(event: Mapping[str, Any]) -> float | None:
    for key in ("elapsed_ms", "latency_ms", "duration_ms"):
        if key in event:
            return _finite(event[key], key)
    payload = event.get("payload")
    if isinstance(payload, Mapping):
        for key in ("elapsed_ms", "latency_ms", "duration_ms"):
            if key in payload:
                return _finite(payload[key], key)
    return None


def _error_code(event: Mapping[str, Any]) -> str | None:
    for container in (event, event.get("payload")):
        if not isinstance(container, Mapping):
            continue
        code = container.get("error_code") or container.get("code")
        if isinstance(code, str) and code:
            return code[:256]
        if container.get("success") is False or container.get("status") == "failed":
            return "unknown_error"
    if event.get("category") == "error" or event.get("type") == "error":
        return "unknown_error"
    return None


def _recovery_duration_ms(item: Mapping[str, Any]) -> float | None:
    if "duration_ms" in item:
        return _finite(item["duration_ms"], "duration_ms")
    started = item.get("started_at")
    finished = item.get("finished_at")
    if started is None or finished is None:
        return None
    return max(0.0, (_finite(finished, "finished_at") - _finite(started, "started_at")) * 1000)


def _trace_roots(
    events: Sequence[Mapping[str, Any]],
    recoveries: Sequence[Mapping[str, Any]],
    manifest: Mapping[str, Any],
) -> set[str]:
    values: set[str] = set()
    for item in [*events, *recoveries, manifest]:
        value = item.get("session_trace_id") if isinstance(item, Mapping) else None
        if isinstance(value, str) and value:
            values.add(value)
    for artifact in manifest.get("artifacts", []):
        if isinstance(artifact, Mapping):
            value = artifact.get("session_trace_id")
            if isinstance(value, str) and value:
                values.add(value)
    return values


def _monotonic_sequences(
    events: Sequence[Mapping[str, Any]],
) -> tuple[bool, list[str]]:
    groups: dict[str, list[tuple[float, int]]] = defaultdict(list)
    for event in events:
        groups[str(event.get("source", "agent"))].append(
            (float(event["timestamp"]), int(event.get("sequence", 0)))
        )
    failures: list[str] = []
    for source, values in groups.items():
        ordered = sorted(values, key=lambda item: item[0])
        sequences = [item[1] for item in ordered]
        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            failures.append(source)
    return not failures, sorted(failures)


def _artifact_hashes(manifest: Mapping[str, Any]) -> tuple[bool, list[str]]:
    failures: list[str] = []
    if manifest.get("status") == "corrupt":
        failures.append("manifest_status=corrupt")
    for artifact in manifest.get("artifacts", []):
        if not isinstance(artifact, Mapping):
            failures.append("invalid_artifact")
            continue
        expected = artifact.get("expected_sha256")
        observed = artifact.get("observed_sha256", artifact.get("sha256"))
        if artifact.get("status") == "corrupt" or (
            expected and observed and expected != observed
        ):
            failures.append(str(artifact.get("relative_path", "unknown")))
    return not failures, sorted(failures)


def _closed_recoveries(
    episodes: Sequence[Mapping[str, Any]],
) -> tuple[bool, list[str]]:
    failures = [
        str(item.get("recovery_id", "unknown"))
        for item in episodes
        if item.get("outcome") not in _TERMINAL_RECOVERY_OUTCOMES
        or item.get("finished_at") is None
    ]
    return not failures, sorted(failures)


def _summary_redaction(
    events: Sequence[Mapping[str, Any]],
) -> tuple[bool, list[str]]:
    failures: list[str] = []

    def visit(value: Any, path: str, depth: int = 0) -> None:
        if depth > 24:
            return
        if isinstance(value, Mapping):
            for key, item in value.items():
                normalized = str(key).lower().replace("-", "_")
                if any(marker in normalized for marker in _SENSITIVE_MARKERS):
                    if not (isinstance(item, Mapping) and item.get("redacted") is True):
                        failures.append(f"{path}.{key}")
                else:
                    visit(item, f"{path}.{key}", depth + 1)
        elif isinstance(value, list):
            for index, item in enumerate(value[:1000]):
                visit(item, f"{path}[{index}]", depth + 1)

    for index, event in enumerate(events):
        visit(event.get("payload", {}), f"event[{index}].payload")
    return not failures, sorted(set(failures))


def _command_correlation(
    events: Sequence[Mapping[str, Any]],
) -> tuple[bool, list[str]]:
    failures: list[str] = []
    for event in events:
        name = str(event.get("name", event.get("type", ""))).lower()
        if "qa_command" not in name and "command_result" not in name:
            continue
        operation = event.get("operation_trace_id", event.get("trace_id"))
        root = event.get("session_trace_id")
        if not isinstance(operation, str) or not operation or not isinstance(root, str) or not root:
            failures.append(str(event.get("event_id", event.get("id", "unknown"))))
    return not failures, sorted(failures)


def _latency_summary(values: Sequence[float]) -> dict[str, Any]:
    if not values:
        return {
            "count": 0,
            "minimum": None,
            "maximum": None,
            "p50": None,
            "p90": None,
            "p99": None,
        }
    normalized = [_finite(value, "latency") for value in values]
    return {
        "count": len(normalized),
        "minimum": min(normalized),
        "maximum": max(normalized),
        "p50": nearest_rank(normalized, 50),
        "p90": nearest_rank(normalized, 90),
        "p99": nearest_rank(normalized, 99),
    }


def _invariant(passed: bool, details: Sequence[Any]) -> dict[str, Any]:
    return {"passed": bool(passed), "details": [str(item)[:512] for item in details]}


def _finite(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AnalyticsError(f"{name} must be numeric")
    normalized = float(value)
    if not math.isfinite(normalized):
        raise AnalyticsError(f"{name} must be finite")
    return normalized
