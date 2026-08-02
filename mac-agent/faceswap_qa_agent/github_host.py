from __future__ import annotations

import argparse
import json
import os
import platform
import pwd
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .config import AgentConfig
from .github_policy import ENVIRONMENT_NAME, REQUIRED_RUNNER_LABELS
from .github_runner import (
    ACTIVATION_VALUE,
    DeviceLock,
    GitHubRunnerError,
    LocalAgentAPI,
    REPOSITORY_PATTERN,
    UDID_PATTERN,
)
from .json_safety import JSONSafetyError, loads_bounded
from .redaction import redact_structured, redact_text

ACTIVATION_MAXIMUM_BYTES = 64 * 1024
ACKNOWLEDGEMENT = "I verified the dedicated Mac, agent, and cable device are safe"
RUNNER_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
USER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")


class HostPolicyError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class ActivationPolicy:
    repository: str
    runner_user: str
    runner_name: str
    device_udid: str
    labels: tuple[str, ...]
    environment: str = ENVIRONMENT_NAME
    activation: str = ACTIVATION_VALUE
    schema_version: int = 1

    @classmethod
    def load(cls, path: Path) -> "ActivationPolicy":
        _assert_private_regular(path)
        try:
            value = loads_bounded(path.read_bytes(), maximum_bytes=ACTIVATION_MAXIMUM_BYTES)
        except JSONSafetyError as error:
            raise HostPolicyError("activation_json_invalid", f"activation JSON rejected: {error.code}") from error
        if not isinstance(value, dict):
            raise HostPolicyError("activation_invalid", "activation document must be an object")
        allowed = {
            "schema_version",
            "activation",
            "repository",
            "environment",
            "runner_user",
            "runner_name",
            "device_udid",
            "labels",
        }
        unknown = set(value) - allowed
        if unknown:
            raise HostPolicyError("activation_unknown_fields", f"activation document has unsupported fields: {sorted(unknown)}")
        labels = value.get("labels")
        if not isinstance(labels, list) or not all(isinstance(item, str) for item in labels):
            raise HostPolicyError("activation_labels_invalid", "activation labels must be an array of strings")
        policy = cls(
            schema_version=int(value.get("schema_version", 0)),
            activation=str(value.get("activation", "")),
            repository=str(value.get("repository", "")),
            environment=str(value.get("environment", "")),
            runner_user=str(value.get("runner_user", "")),
            runner_name=str(value.get("runner_name", "")),
            device_udid=str(value.get("device_udid", "")),
            labels=tuple(sorted(set(labels))),
        )
        policy.validate()
        return policy

    def validate(self) -> None:
        if self.schema_version != 1:
            raise HostPolicyError("activation_version_invalid", "activation schema version must be 1")
        if self.activation != ACTIVATION_VALUE:
            raise HostPolicyError("activation_value_invalid", "activation value is not authorized")
        if not REPOSITORY_PATTERN.fullmatch(self.repository):
            raise HostPolicyError("activation_repository_invalid", "activation repository is invalid")
        if self.environment != ENVIRONMENT_NAME:
            raise HostPolicyError("activation_environment_invalid", "activation environment is invalid")
        if not USER_PATTERN.fullmatch(self.runner_user):
            raise HostPolicyError("activation_user_invalid", "activation runner user is invalid")
        if not RUNNER_NAME_PATTERN.fullmatch(self.runner_name):
            raise HostPolicyError("activation_runner_invalid", "activation runner name is invalid")
        if not UDID_PATTERN.fullmatch(self.device_udid):
            raise HostPolicyError("activation_udid_invalid", "activation device UDID is invalid")
        if set(self.labels) != REQUIRED_RUNNER_LABELS:
            raise HostPolicyError("activation_labels_invalid", "activation labels must equal the dedicated runner label set")

    def assert_workflow(self, *, repository: str, runner_user: str, runner_name: str, device_udid: str) -> None:
        mismatches = []
        for name, actual, expected in (
            ("repository", repository, self.repository),
            ("runner_user", runner_user, self.runner_user),
            ("runner_name", runner_name, self.runner_name),
            ("device_udid", device_udid, self.device_udid),
        ):
            if actual != expected:
                mismatches.append(name)
        if mismatches:
            raise HostPolicyError("activation_workflow_mismatch", f"workflow does not match local activation: {mismatches}")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "activation": self.activation,
            "repository": self.repository,
            "environment": self.environment,
            "runner_user": self.runner_user,
            "runner_name": self.runner_name,
            "device_udid": self.device_udid,
            "labels": list(self.labels),
        }


def default_activation_path() -> Path:
    raw = os.environ.get("FACESWAP_QA_ACTIVATION_FILE", "").strip()
    return Path(raw).expanduser() if raw else Path.home() / ".faceswap-qa-runner" / "activation.json"


def verify_host(
    config: AgentConfig,
    policy: ActivationPolicy,
    *,
    api: LocalAgentAPI | None = None,
    system_name: str | None = None,
    effective_uid: int | None = None,
    username: str | None = None,
    runner_name: str | None = None,
) -> dict[str, Any]:
    actual_system = system_name or platform.system()
    uid = os.geteuid() if effective_uid is None else effective_uid
    actual_user = username or pwd.getpwuid(uid).pw_name
    actual_runner = runner_name or os.environ.get("RUNNER_NAME", "")
    checks = {
        "darwin": actual_system == "Darwin",
        "non_root": uid != 0,
        "runner_user": actual_user == policy.runner_user,
        "runner_name": actual_runner == policy.runner_name,
        "config_private": _private_regular(config.config_path),
        "token_private": _private_regular(config.api.token_file),
    }
    client = api or LocalAgentAPI(config)
    health: dict[str, Any] = {}
    device: dict[str, Any] | None = None
    try:
        health = client.request("GET", "/health", timeout=30)
        checks["agent_healthy"] = health.get("status") == "ok" and health.get("worker_alive") is True
        checks["agent_idle"] = (
            health.get("active_job_id") is None
            and health.get("active_live_session_id") is None
            and int(health.get("queue_depth", 0)) == 0
        )
        inventory = client.request("GET", "/devices", timeout=60)
        devices = inventory.get("devices")
        candidates = [
            item
            for item in devices
            if isinstance(devices, list)
            and isinstance(item, dict)
            and item.get("kind") == "cable"
            and item.get("udid") == policy.device_udid
        ] if isinstance(devices, list) else []
        if len(candidates) == 1:
            device = candidates[0]
        checks["device_ready"] = bool(device and device.get("ready") is True)
    except Exception:
        checks["agent_healthy"] = False
        checks["agent_idle"] = False
        checks["device_ready"] = False
    passed = all(checks.values())
    return {
        "schema_version": 1,
        "status": "pass" if passed else "fail",
        "checks": checks,
        "failed_checks": sorted(name for name, value in checks.items() if not value),
        "activation": policy.to_dict(),
        "health": redact_structured(health),
        "device": redact_structured(device),
    }


def set_quarantine(config: AgentConfig, policy: ActivationPolicy, reason: str) -> dict[str, Any]:
    allowed_reasons = {"manual", "runner-maintenance", "device-maintenance"}
    if reason not in allowed_reasons:
        raise HostPolicyError("quarantine_reason_invalid", "quarantine reason is not allowlisted")
    state_root = config.paths.database.parent.resolve(strict=True)
    if state_root.is_symlink():
        raise HostPolicyError("state_directory_symlink", "agent state directory must not be a symlink")
    marker = state_root / "github-physical-device.quarantine.json"
    if marker.is_symlink():
        raise HostPolicyError("quarantine_symlink", "quarantine marker must not be a symlink")
    payload = json.dumps(
        {
            "schema_version": 1,
            "status": "quarantined",
            "reason": reason,
            "repository": policy.repository,
            "device_udid": policy.device_udid,
        },
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"
    descriptor, raw_path = tempfile.mkstemp(
        prefix=".github-quarantine.", suffix=".tmp", dir=str(state_root)
    )
    temporary = Path(raw_path)
    try:
        os.fchmod(descriptor, 0o600)
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid():
            raise HostPolicyError("quarantine_descriptor_invalid", "quarantine descriptor is unsafe")
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, marker)
        marker.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)
    return {"quarantined": True, "reason": reason, "device_udid": policy.device_udid}


def quarantine_status(config: AgentConfig) -> dict[str, Any]:
    path = config.paths.database.parent / "github-physical-device.quarantine.json"
    if not path.exists():
        return {"quarantined": False}
    _assert_private_regular(path)
    try:
        document = loads_bounded(path.read_bytes(), maximum_bytes=ACTIVATION_MAXIMUM_BYTES)
    except JSONSafetyError as error:
        raise HostPolicyError("quarantine_invalid", f"quarantine JSON rejected: {error.code}") from error
    return {"quarantined": True, "document": redact_structured(document)}


def clear_quarantine(
    config: AgentConfig,
    policy: ActivationPolicy,
    acknowledgement: str,
    *,
    api: LocalAgentAPI | None = None,
    verifier: Callable[..., dict[str, Any]] = verify_host,
) -> dict[str, Any]:
    if acknowledgement != ACKNOWLEDGEMENT:
        raise HostPolicyError("acknowledgement_required", "exact acknowledgement is required")
    state_root = config.paths.database.parent
    lock = state_root / "github-physical-device.lock"
    marker = state_root / "github-physical-device.quarantine.json"
    client = api or LocalAgentAPI(config)
    with DeviceLock(lock, {"operation": "quarantine-clear", "device_udid": policy.device_udid}):
        if marker.exists() or marker.is_symlink():
            _assert_private_regular(marker)
        report = verifier(
            config,
            policy,
            api=client,
            runner_name=policy.runner_name,
        )
        if report["status"] != "pass":
            raise HostPolicyError("quarantine_clear_blocked", f"host verification failed: {report['failed_checks']}")
        marker.unlink(missing_ok=True)
        return {"quarantined": False, "cleared": True, "device_udid": policy.device_udid}


def _assert_private_regular(path: Path) -> None:
    if path.is_symlink():
        raise HostPolicyError("unsafe_private_file", f"file must not be a symlink: {path}")
    details = path.stat()
    if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid():
        raise HostPolicyError("unsafe_private_file", f"file must be regular and owned by the runner: {path}")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise HostPolicyError("unsafe_private_file", f"file must be private: {path}")


def _private_regular(path: Path) -> bool:
    try:
        _assert_private_regular(path)
        return True
    except (OSError, HostPolicyError):
        return False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Dedicated physical-device runner host controls")
    parser.add_argument("--config", default=str(Path.home() / ".faceswap-qa-agent" / "config.json"))
    parser.add_argument("--activation", default=str(default_activation_path()))
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("verify")
    subparsers.add_parser("quarantine-status")
    quarantine_set = subparsers.add_parser("quarantine-set")
    quarantine_set.add_argument(
        "--reason",
        choices=("manual", "runner-maintenance", "device-maintenance"),
        default="manual",
    )
    clear = subparsers.add_parser("quarantine-clear")
    clear.add_argument("--acknowledge", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = AgentConfig.load(args.config)
        policy = ActivationPolicy.load(Path(args.activation).expanduser())
        if args.command == "verify":
            result = verify_host(config, policy)
            exit_code = 0 if result["status"] == "pass" else 1
        elif args.command == "quarantine-status":
            result = quarantine_status(config)
            exit_code = 1 if result.get("quarantined") else 0
        elif args.command == "quarantine-set":
            result = set_quarantine(config, policy, args.reason)
            exit_code = 0
        elif args.command == "quarantine-clear":
            result = clear_quarantine(config, policy, args.acknowledge)
            exit_code = 0
        else:
            raise HostPolicyError("unsupported_command", "unsupported host command")
        print(json.dumps(result, indent=2, sort_keys=True))
        return exit_code
    except (HostPolicyError, GitHubRunnerError, ValueError, OSError) as error:
        code = getattr(error, "code", "host_control_failed")
        print(json.dumps({"error": {"code": code, "message": redact_text(str(error))}}, sort_keys=True), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
