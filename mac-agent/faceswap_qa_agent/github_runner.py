from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol, Sequence

from .cli import base_url, load_token
from .config import AgentConfig
from .json_safety import JSONSafetyError, loads_bounded
from .redaction import RedactionPolicy, redact_structured, redact_text

SCHEMA_VERSION = 1
ACTIVATION_VALUE = "phase11-v1"
TERMINAL_STATUSES = frozenset({"succeeded", "failed", "cancelled"})
UUID_NAMESPACE = uuid.UUID("92e65a6f-54a9-5fb0-a809-60ac33a96b22")
UDID_PATTERN = re.compile(r"^[A-Za-z0-9-]{4,128}$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
TRACE_LABEL_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
RUNNER_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
DIGITS_PATTERN = re.compile(r"^[0-9]{1,20}$")
PRIVATE_FILE_MODE = 0o600
PRIVATE_DIRECTORY_MODE = 0o700
MAXIMUM_STATE_BYTES = 1024 * 1024
MAXIMUM_LOG_BYTES = 64 * 1024 * 1024
MAXIMUM_DOWNLOAD_BYTES = 2 * 1024 * 1024 * 1024

TEST_TARGET = "FaceSwapLiveAppV17UITests/FaceSwapLiveAppV17UITests"
SCENARIO_TESTS: dict[str, tuple[str, ...]] = {
    "launch": (f"{TEST_TARGET}/test01ManifestLaunchPublishesRunIdentityAndCapabilities",),
    "tabs": (f"{TEST_TARGET}/test02AllRootTabsAreCommandNavigable",),
    "browser": (
        f"{TEST_TARGET}/test03BrowserLoadURLUpdatesChromeWebContentAndState",
        f"{TEST_TARGET}/test04FeatureRegistryMutatesLiveInjectionAndRejectsBadVersion",
    ),
    "media": (f"{TEST_TARGET}/test05DeterministicSequenceDrivesMediaAndNativeWebRTC",),
    "diagnostics": (f"{TEST_TARGET}/test06DiagnosticsRunsAgainstBuiltInFixture",),
    "recovery": (f"{TEST_TARGET}/test07LifecycleRecoveryEvidenceAndStateCleanup",),
    "hardware": (f"{TEST_TARGET}/test08CableDevicePublishesPhysicalCaptureAndAudioOutcome",),
    "canary": (
        f"{TEST_TARGET}/test01ManifestLaunchPublishesRunIdentityAndCapabilities",
        f"{TEST_TARGET}/test08CableDevicePublishesPhysicalCaptureAndAudioOutcome",
    ),
    "all": (),
}
TIMEOUT_CHOICES = frozenset({15, 30, 45, 60, 90, 120})
RETRY_CHOICES = frozenset({0, 1, 2})
RETENTION_CHOICES = frozenset({1, 3, 7, 14, 30})


class GitHubRunnerError(RuntimeError):
    def __init__(self, code: str, message: str, *, exit_code: int = 70) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


@dataclass(frozen=True, slots=True)
class WorkflowInputs:
    operation: str
    scenario: str
    device_udid: str
    timeout_minutes: int
    retry_count: int
    retention_days: int
    trace_label: str | None
    confirm_physical_device: bool

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> "WorkflowInputs":
        operation = environment.get("INPUT_OPERATION", "").strip()
        if operation not in {"preflight", "execute"}:
            raise GitHubRunnerError("invalid_operation", "operation must be preflight or execute", exit_code=64)
        scenario = environment.get("INPUT_SCENARIO", "").strip()
        if scenario not in SCENARIO_TESTS:
            raise GitHubRunnerError("invalid_scenario", "scenario is not allowlisted", exit_code=64)
        udid = environment.get("INPUT_DEVICE_UDID", "").strip()
        if not UDID_PATTERN.fullmatch(udid):
            raise GitHubRunnerError("invalid_udid", "device UDID contains unsupported characters", exit_code=64)
        timeout_minutes = _choice_integer(environment, "INPUT_TIMEOUT_MINUTES", TIMEOUT_CHOICES)
        retry_count = _choice_integer(environment, "INPUT_RETRY_COUNT", RETRY_CHOICES)
        retention_days = _choice_integer(environment, "INPUT_RETENTION_DAYS", RETENTION_CHOICES)
        label = environment.get("INPUT_TRACE_LABEL", "").strip()
        if label and not TRACE_LABEL_PATTERN.fullmatch(label):
            raise GitHubRunnerError("invalid_trace_label", "trace label contains unsupported characters", exit_code=64)
        raw_confirm = environment.get("INPUT_CONFIRM_PHYSICAL_DEVICE", "false").strip().lower()
        if raw_confirm not in {"true", "false"}:
            raise GitHubRunnerError("invalid_confirmation", "physical-device confirmation must be true or false", exit_code=64)
        confirmed = raw_confirm == "true"
        if operation == "execute" and not confirmed:
            raise GitHubRunnerError("confirmation_required", "execute requires explicit physical-device confirmation", exit_code=64)
        return cls(
            operation=operation,
            scenario=scenario,
            device_udid=udid,
            timeout_minutes=timeout_minutes,
            retry_count=retry_count,
            retention_days=retention_days,
            trace_label=label or None,
            confirm_physical_device=confirmed,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "operation": self.operation,
            "scenario": self.scenario,
            "device_udid": self.device_udid,
            "timeout_minutes": self.timeout_minutes,
            "retry_count": self.retry_count,
            "retention_days": self.retention_days,
            "trace_label": self.trace_label,
            "confirm_physical_device": self.confirm_physical_device,
            "only_testing": list(SCENARIO_TESTS[self.scenario]),
        }


@dataclass(frozen=True, slots=True)
class WorkflowContext:
    repository: str
    sha: str
    run_id: str
    run_attempt: int
    ref: str
    event_name: str
    runner_temp: Path
    runner_user: str
    runner_name: str
    repository_private: bool

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str],
        *,
        system_name: str | None = None,
        effective_uid: int | None = None,
        username: str | None = None,
    ) -> "WorkflowContext":
        if environment.get("GITHUB_ACTIONS", "").lower() != "true":
            raise GitHubRunnerError("not_github_actions", "bridge must execute inside GitHub Actions", exit_code=78)
        event_name = environment.get("GITHUB_EVENT_NAME", "")
        if event_name != "workflow_dispatch":
            raise GitHubRunnerError("untrusted_trigger", "only workflow_dispatch is authorized", exit_code=78)
        ref = environment.get("GITHUB_REF", "")
        if ref != "refs/heads/main":
            raise GitHubRunnerError("untrusted_ref", "physical-device workflow is restricted to main", exit_code=78)
        if environment.get("GITHUB_REPOSITORY_PRIVATE", "").lower() != "true":
            raise GitHubRunnerError("public_repository", "physical-device execution requires a private repository", exit_code=78)
        repository = environment.get("GITHUB_REPOSITORY", "")
        if not REPOSITORY_PATTERN.fullmatch(repository):
            raise GitHubRunnerError("invalid_repository", "GitHub repository identity is invalid", exit_code=78)
        if environment.get("PHYSICAL_QA_ACTIVATION", "") != ACTIVATION_VALUE:
            raise GitHubRunnerError("environment_unprotected", "protected-environment activation value is missing", exit_code=78)
        if environment.get("PHYSICAL_QA_REPOSITORY", "") != repository:
            raise GitHubRunnerError("environment_repository_mismatch", "protected environment is not bound to this repository", exit_code=78)
        sha = environment.get("GITHUB_SHA", "")
        if not SHA_PATTERN.fullmatch(sha):
            raise GitHubRunnerError("invalid_commit", "GitHub commit SHA is invalid", exit_code=78)
        run_id = environment.get("GITHUB_RUN_ID", "")
        attempt_text = environment.get("GITHUB_RUN_ATTEMPT", "")
        if not DIGITS_PATTERN.fullmatch(run_id) or not DIGITS_PATTERN.fullmatch(attempt_text):
            raise GitHubRunnerError("invalid_run_identity", "GitHub run identity is invalid", exit_code=78)
        attempt = int(attempt_text)
        if attempt < 1 or attempt > 9999:
            raise GitHubRunnerError("invalid_run_attempt", "GitHub run attempt is outside the supported range", exit_code=78)
        actual_system = system_name or platform.system()
        if actual_system != "Darwin":
            raise GitHubRunnerError("invalid_runner_os", "physical-device bridge requires macOS", exit_code=78)
        uid = os.geteuid() if effective_uid is None else effective_uid
        if uid == 0:
            raise GitHubRunnerError("root_runner", "physical-device runner must not run as root", exit_code=78)
        actual_user = username or pwd.getpwuid(uid).pw_name
        expected_user = environment.get("PHYSICAL_QA_RUNNER_USER", "").strip()
        if not expected_user or actual_user != expected_user:
            raise GitHubRunnerError("runner_user_mismatch", "runner must use the protected dedicated account", exit_code=78)
        if environment.get("RUNNER_OS", "") != "macOS":
            raise GitHubRunnerError("runner_label_mismatch", "GitHub runner OS must be macOS", exit_code=78)
        runner_name = environment.get("RUNNER_NAME", "").strip()
        if not RUNNER_NAME_PATTERN.fullmatch(runner_name):
            raise GitHubRunnerError("runner_name_invalid", "GitHub runner name is invalid", exit_code=78)
        raw_temp = environment.get("RUNNER_TEMP", "").strip()
        if not raw_temp:
            raise GitHubRunnerError("runner_temp_missing", "RUNNER_TEMP is required", exit_code=78)
        runner_temp = _owned_directory(Path(raw_temp), private=False)
        return cls(
            repository=repository,
            sha=sha.lower(),
            run_id=run_id,
            run_attempt=attempt,
            ref=ref,
            event_name=event_name,
            runner_temp=runner_temp,
            runner_user=actual_user,
            runner_name=runner_name,
            repository_private=True,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "repository": self.repository,
            "sha": self.sha,
            "github_run_id": self.run_id,
            "github_run_attempt": self.run_attempt,
            "ref": self.ref,
            "event_name": self.event_name,
            "runner_user": self.runner_user,
            "runner_name": self.runner_name,
            "repository_private": self.repository_private,
        }


@dataclass(frozen=True, slots=True)
class Identity:
    run_id: str
    session_trace_id: str
    idempotency_key: str


def deterministic_identity(context: WorkflowContext, inputs: WorkflowInputs) -> Identity:
    seed = "|".join(
        (
            context.repository.lower(),
            context.sha,
            context.run_id,
            str(context.run_attempt),
            inputs.device_udid,
            inputs.scenario,
        )
    )
    run_uuid = uuid.uuid5(UUID_NAMESPACE, f"run|{seed}")
    trace_uuid = uuid.uuid5(UUID_NAMESPACE, f"trace|{seed}")
    key_hash = hashlib.sha256(seed.encode("utf-8")).hexdigest()
    return Identity(str(run_uuid), str(trace_uuid), f"github-physical-{key_hash}")


class AgentAPIProtocol(Protocol):
    def request(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
        timeout: float = 120,
    ) -> dict[str, Any]: ...

    def download(self, path: str, destination: Path, *, timeout: float) -> dict[str, Any]: ...


class LocalAgentAPI:
    def __init__(self, config: AgentConfig) -> None:
        self.config = config

    def request(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
        timeout: float = 120,
    ) -> dict[str, Any]:
        data: bytes | None = None
        headers = {"Authorization": f"Bearer {load_token(self.config)}"}
        if payload is not None:
            data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
            if len(data) > self.config.limits.max_request_bytes:
                raise GitHubRunnerError("request_too_large", "agent request exceeds configured limit")
            headers["Content-Type"] = "application/json"
        if idempotency_key:
            if len(idempotency_key) > 256:
                raise GitHubRunnerError("idempotency_key_too_long", "idempotency key exceeds agent limit")
            headers["Idempotency-Key"] = idempotency_key
        request = urllib.request.Request(base_url(self.config) + path, data=data, headers=headers, method=method)
        maximum = max(1024 * 1024, min(self.config.live.maximum_observation_bytes * 2, 64 * 1024 * 1024))
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read(maximum + 1)
        except urllib.error.HTTPError as error:
            raw = error.read(min(maximum, 1024 * 1024) + 1)
            detail = redact_text(raw[: 1024 * 1024].decode("utf-8", errors="replace"))
            raise GitHubRunnerError("agent_http_error", f"agent returned HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            raise GitHubRunnerError("agent_unreachable", f"agent request failed: {error.reason}") from error
        if len(raw) > maximum:
            raise GitHubRunnerError("agent_response_too_large", "agent response exceeded configured bound")
        try:
            value = loads_bounded(raw, maximum_bytes=maximum)
        except JSONSafetyError as error:
            raise GitHubRunnerError("agent_response_invalid", f"agent response JSON rejected: {error.code}") from error
        if not isinstance(value, dict):
            raise GitHubRunnerError("agent_response_invalid", "agent response must be an object")
        return value

    def download(self, path: str, destination: Path, *, timeout: float) -> dict[str, Any]:
        destination.parent.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
        _owned_directory(destination.parent, private=True)
        if destination.exists() or destination.is_symlink():
            raise GitHubRunnerError("download_destination_exists", "evidence destination must not preexist")
        request = urllib.request.Request(
            base_url(self.config) + path,
            headers={"Authorization": f"Bearer {load_token(self.config)}"},
            method="GET",
        )
        temporary_path: Path | None = None
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw_length = response.headers.get("Content-Length")
                expected_hash = response.headers.get("X-Content-SHA256", "").lower()
                if raw_length is None or not raw_length.isdigit():
                    raise GitHubRunnerError("download_length_missing", "evidence response omitted Content-Length")
                expected_length = int(raw_length)
                if expected_length < 1 or expected_length > MAXIMUM_DOWNLOAD_BYTES:
                    raise GitHubRunnerError("download_length_invalid", "evidence length is outside the safe bound")
                if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
                    raise GitHubRunnerError("download_hash_missing", "evidence response omitted a valid SHA-256")
                descriptor, raw_path = tempfile.mkstemp(
                    prefix=f".{destination.name}.", suffix=".part", dir=str(destination.parent)
                )
                temporary_path = Path(raw_path)
                try:
                    _validate_private_descriptor(descriptor)
                except BaseException:
                    os.close(descriptor)
                    raise
                digest = hashlib.sha256()
                observed = 0
                with os.fdopen(descriptor, "wb") as handle:
                    while observed < expected_length:
                        chunk = response.read(min(1024 * 1024, expected_length - observed))
                        if not chunk:
                            break
                        observed += len(chunk)
                        digest.update(chunk)
                        handle.write(chunk)
                    if response.read(1):
                        raise GitHubRunnerError("download_overflow", "evidence exceeded Content-Length")
                    handle.flush()
                    os.fsync(handle.fileno())
                if observed != expected_length:
                    raise GitHubRunnerError("download_truncated", "evidence ended before Content-Length")
                if digest.hexdigest() != expected_hash:
                    raise GitHubRunnerError("download_hash_mismatch", "evidence SHA-256 mismatch")
                os.replace(temporary_path, destination)
                temporary_path = None
                destination.chmod(PRIVATE_FILE_MODE)
                return {
                    "path": str(destination),
                    "byte_size": observed,
                    "sha256": expected_hash,
                    "content_type": response.headers.get("Content-Type", "application/gzip"),
                }
        except urllib.error.HTTPError as error:
            raise GitHubRunnerError("evidence_download_http_error", f"evidence download returned HTTP {error.code}") from error
        except urllib.error.URLError as error:
            raise GitHubRunnerError("evidence_download_failed", f"evidence download failed: {error.reason}") from error
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)


class DeviceLock:
    def __init__(self, path: Path, metadata: Mapping[str, Any]) -> None:
        self.path = path
        self.metadata = dict(metadata)
        self.descriptor: int | None = None

    def __enter__(self) -> "DeviceLock":
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
        _owned_directory(self.path.parent, private=True)
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(self.path, flags, PRIVATE_FILE_MODE)
        try:
            _validate_private_descriptor(descriptor)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise GitHubRunnerError("device_lock_busy", "another authorized process holds the physical-device lock", exit_code=75) from error
            encoded = json.dumps(redact_structured(self.metadata), sort_keys=True, separators=(",", ":")).encode("utf-8")
            if len(encoded) > MAXIMUM_STATE_BYTES:
                raise GitHubRunnerError("lock_metadata_too_large", "lock metadata exceeds the safe bound")
            os.ftruncate(descriptor, 0)
            os.lseek(descriptor, 0, os.SEEK_SET)
            os.write(descriptor, encoded)
            os.fsync(descriptor)
            self.descriptor = descriptor
            return self
        except BaseException:
            os.close(descriptor)
            raise

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self.descriptor is not None:
            try:
                fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            finally:
                os.close(self.descriptor)
                self.descriptor = None


class GitHubPhysicalRunner:
    def __init__(
        self,
        config: AgentConfig,
        context: WorkflowContext,
        inputs: WorkflowInputs,
        *,
        api: AgentAPIProtocol | None = None,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        activation_path: Path | None = None,
        installation_home: Path | None = None,
    ) -> None:
        self.config = config
        self.context = context
        self.inputs = inputs
        self.identity = deterministic_identity(context, inputs)
        self.api = api or LocalAgentAPI(config)
        self.monotonic = monotonic
        self.sleep = sleep
        self.command_runner = command_runner
        self.installation_home = _owned_directory(
            installation_home or Path.home(), private=False
        )
        self.activation_path = activation_path or default_activation_path()
        _assert_beneath(config.config_path, self.installation_home, "configuration")
        _assert_beneath(config.api.token_file, self.installation_home, "API token")
        _assert_beneath(config.paths.database.parent, self.installation_home, "agent state")
        _assert_beneath(self.activation_path, self.installation_home, "activation document")
        self.activation_policy: Any | None = None
        self.state_root = _owned_directory(config.paths.database.parent, private=True)
        self.run_directory = self._run_directory()
        self.state_path = self.run_directory / "run-state.json"
        self.lock_path = self.state_root / "github-physical-device.lock"
        self.quarantine_path = self.state_root / "github-physical-device.quarantine.json"
        self._interrupted = threading.Event()

    def _run_directory(self) -> Path:
        base = _owned_directory(self.context.runner_temp, private=False)
        name = f"faceswap-physical-{self.context.run_id}-{self.context.run_attempt}"
        path = base / name
        _assert_beneath(path, base, "workflow run directory")
        if path.is_symlink():
            raise GitHubRunnerError("run_directory_symlink", "run directory must not be a symlink")
        path.mkdir(mode=PRIVATE_DIRECTORY_MODE, parents=False, exist_ok=True)
        return _owned_directory(path, private=True)

    def lock_metadata(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "repository": self.context.repository,
            "sha": self.context.sha,
            "github_run_id": self.context.run_id,
            "github_run_attempt": self.context.run_attempt,
            "run_id": self.identity.run_id,
            "session_trace_id": self.identity.session_trace_id,
            "device_udid": self.inputs.device_udid,
            "scenario": self.inputs.scenario,
            "pid": os.getpid(),
        }

    def run(self) -> dict[str, Any]:
        with DeviceLock(self.lock_path, self.lock_metadata()):
            self._reject_quarantine()
            from .github_host import ActivationPolicy

            try:
                policy = ActivationPolicy.load(self.activation_path)
                policy.assert_workflow(
                    repository=self.context.repository,
                    runner_user=self.context.runner_user,
                    runner_name=self.context.runner_name,
                    device_udid=self.inputs.device_udid,
                )
                self.activation_policy = policy
                self._install_signal_handlers()
                _assert_private_regular(self.config.config_path)
                _assert_private_regular(self.config.api.token_file)
                _write_private_json(self.run_directory / "inputs.json", self.inputs.to_dict())
                _write_private_json(self.run_directory / "context.json", self.context.to_dict())
                preflight = self.preflight()
                if self.inputs.operation == "preflight":
                    summary = self._summary(
                        status="preflight_succeeded",
                        job=None,
                        preflight=preflight,
                        evidence=None,
                        analytics=None,
                    )
                    _write_private_json(self.run_directory / "summary.json", summary)
                    self._write_state({"phase": "preflight_succeeded", "terminal": True})
                    return summary
                return self._execute(preflight)
            except BaseException as error:
                code = getattr(error, "code", type(error).__name__)
                message = redact_text(str(error))
                if not (self.run_directory / "inputs.json").exists():
                    _write_private_json(self.run_directory / "inputs.json", self.inputs.to_dict())
                if not (self.run_directory / "context.json").exists():
                    _write_private_json(self.run_directory / "context.json", self.context.to_dict())
                if not (self.run_directory / "preflight.json").exists():
                    _write_private_json(
                        self.run_directory / "preflight.json",
                        {
                            "schema_version": SCHEMA_VERSION,
                            "status": "failed",
                            "run_id": self.identity.run_id,
                            "session_trace_id": self.identity.session_trace_id,
                            "error": {"code": str(code), "message": message},
                        },
                    )
                _write_private_json(
                    self.run_directory / "bridge-error.json",
                    {
                        "schema_version": SCHEMA_VERSION,
                        "run_id": self.identity.run_id,
                        "session_trace_id": self.identity.session_trace_id,
                        "error": {"code": str(code), "message": message},
                    },
                )
                if not (self.run_directory / "summary.json").exists():
                    _write_private_json(
                        self.run_directory / "summary.json",
                        self._summary(
                            status="failed",
                            job=None,
                            preflight={"status": "failed"},
                            evidence=None,
                            analytics=None,
                        )
                        | {"error": {"code": str(code), "message": message}},
                    )
                try:
                    self._write_state(
                        {"phase": "failed", "terminal": True, "error_code": str(code)}
                    )
                except Exception:
                    pass
                raise

    def preflight(self) -> dict[str, Any]:
        health = self.api.request("GET", "/health", timeout=30)
        if health.get("status") != "ok" or health.get("worker_alive") is not True:
            raise GitHubRunnerError("agent_unhealthy", "Mac agent worker is not healthy", exit_code=69)
        active_job = health.get("active_job_id")
        active_live = health.get("active_live_session_id")
        if active_job or active_live or int(health.get("queue_depth", 0)) != 0:
            raise GitHubRunnerError("agent_busy", "Mac agent already has queued or active device ownership", exit_code=75)
        device_document = self.api.request("GET", "/devices", timeout=60)
        devices = device_document.get("devices")
        if not isinstance(devices, list):
            raise GitHubRunnerError("device_inventory_invalid", "agent device inventory is invalid")
        matches = [
            item
            for item in devices
            if isinstance(item, dict)
            and item.get("kind") == "cable"
            and item.get("udid") == self.inputs.device_udid
        ]
        if len(matches) != 1:
            raise GitHubRunnerError("device_not_found", "exactly one requested cable device must be present", exit_code=69)
        device = matches[0]
        reasons = device.get("readiness_reasons")
        if device.get("ready") is not True or (isinstance(reasons, list) and reasons):
            raise GitHubRunnerError("device_not_ready", "requested cable device is not ready", exit_code=69)
        free_bytes = shutil.disk_usage(self.run_directory).free
        minimum_free = 10 * 1024 * 1024 * 1024
        if free_bytes < minimum_free:
            raise GitHubRunnerError("disk_space_low", "runner has less than 10 GiB free", exit_code=69)
        versions = self._toolchain_versions()
        if self.config.appium.version != "3.6.0" or self.config.appium.xcuitest_driver_version != "12.1.4":
            raise GitHubRunnerError("appium_contract_mismatch", "pinned Appium/XCUITest contract is not configured", exit_code=69)
        if self.config.appium.plugin_version != "1.0.0" or self.config.appium.remotexpc_version != "5.13.2":
            raise GitHubRunnerError("appium_extension_mismatch", "pinned plugin/RemoteXPC contract is not configured", exit_code=69)
        document = {
            "schema_version": SCHEMA_VERSION,
            "status": "ready",
            "run_id": self.identity.run_id,
            "session_trace_id": self.identity.session_trace_id,
            "health": redact_structured(health),
            "device": redact_structured(device),
            "free_bytes": free_bytes,
            "minimum_free_bytes": minimum_free,
            "toolchain": versions,
            "activation": (
                self.activation_policy.to_dict()
                if self.activation_policy is not None
                else None
            ),
        }
        _write_private_json(self.run_directory / "preflight.json", document)
        self._write_state({"phase": "preflight_ready", "terminal": False})
        return document

    def _toolchain_versions(self) -> dict[str, str]:
        commands = {
            "xcodebuild": ["xcodebuild", "-version"],
            "devicectl": ["xcrun", "--find", "devicectl"],
        }
        result: dict[str, str] = {}
        environment = os.environ.copy()
        environment.update(self.config.environment())
        for name, command in commands.items():
            completed = self.command_runner(
                command,
                capture_output=True,
                text=True,
                timeout=30,
                env=environment,
                check=False,
            )
            if completed.returncode != 0:
                raise GitHubRunnerError("toolchain_missing", f"required tool failed: {name}", exit_code=69)
            output = (completed.stdout or completed.stderr or "").strip()
            result[name] = redact_text(output)[:4096]
        result.update(
            {
                "appium": self.config.appium.version,
                "xcuitest_driver": self.config.appium.xcuitest_driver_version,
                "plugin": self.config.appium.plugin_version,
                "remotexpc": self.config.appium.remotexpc_version,
            }
        )
        return result

    def _execute(self, preflight: dict[str, Any]) -> dict[str, Any]:
        payload = {
            "target": {"kind": "cable", "udid": self.inputs.device_udid, "os": "latest"},
            "run_id": self.identity.run_id,
            "session_trace_id": self.identity.session_trace_id,
            "only_testing": list(SCENARIO_TESTS[self.inputs.scenario]),
            "skip_testing": [],
            "timeout_seconds": self.inputs.timeout_minutes * 60,
            "max_retries": self.inputs.retry_count,
            "labels": {
                "github_repository": self.context.repository,
                "github_run_id": self.context.run_id,
                "github_run_attempt": str(self.context.run_attempt),
                "github_sha": self.context.sha,
                "scenario": self.inputs.scenario,
                "trace_label": self.inputs.trace_label or "",
            },
        }
        _write_private_json(self.run_directory / "request.json", redact_structured(payload))
        response = self.api.request(
            "POST",
            "/jobs",
            payload=payload,
            idempotency_key=self.identity.idempotency_key,
            timeout=60,
        )
        job = response.get("job")
        if not isinstance(job, dict) or not _is_uuid(job.get("id")):
            raise GitHubRunnerError("job_response_invalid", "agent did not return a valid job")
        if job.get("session_trace_id") != self.identity.session_trace_id:
            raise GitHubRunnerError("job_trace_mismatch", "agent job root trace does not match the workflow trace")
        self._write_state(
            {
                "phase": "submitted",
                "terminal": False,
                "job_id": job["id"],
                "job_status": job.get("status"),
            }
        )
        try:
            terminal = self._wait_for_terminal(str(job["id"]))
        except BaseException:
            self._cancel_and_wait(str(job["id"]))
            raise
        _write_private_json(self.run_directory / "job.json", redact_structured(terminal))
        artifacts = self.api.request("GET", f"/jobs/{job['id']}/artifacts", timeout=60)
        _write_private_json(self.run_directory / "artifacts.json", redact_structured(artifacts))
        trace = self.api.request("GET", f"/traces/{self.identity.session_trace_id}", timeout=120)
        analytics = self.api.request(
            "GET", f"/traces/{self.identity.session_trace_id}/analytics", timeout=120
        )
        recoveries = self.api.request(
            "GET", f"/traces/{self.identity.session_trace_id}/recoveries", timeout=120
        )
        evidence = self.api.request(
            "POST", f"/traces/{self.identity.session_trace_id}/evidence", timeout=300
        )
        for name, document in (
            ("trace.json", trace),
            ("analytics.json", analytics),
            ("recoveries.json", recoveries),
            ("evidence.json", evidence),
        ):
            _write_private_json(self.run_directory / name, redact_structured(document))
        bundle_path = self.run_directory / "trace-evidence.tar.gz"
        bundle = self.api.download(
            f"/traces/{self.identity.session_trace_id}/evidence/download",
            bundle_path,
            timeout=300,
        )
        _write_private_json(self.run_directory / "bundle.json", bundle)
        analytics_document = analytics.get("analytics")
        qualification = (
            analytics_document.get("qualification", {}).get("status")
            if isinstance(analytics_document, dict)
            and isinstance(analytics_document.get("qualification"), dict)
            else None
        )
        status = str(terminal.get("status"))
        summary = self._summary(
            status=status,
            job=terminal,
            preflight=preflight,
            evidence=bundle,
            analytics=analytics_document if isinstance(analytics_document, dict) else None,
        )
        _write_private_json(self.run_directory / "summary.json", summary)
        self._write_state(
            {
                "phase": "terminal",
                "terminal": True,
                "job_id": job["id"],
                "job_status": status,
                "evidence_sha256": bundle["sha256"],
                "analytics_qualification": qualification,
            }
        )
        if status != "succeeded":
            raise GitHubRunnerError("physical_job_failed", f"physical QA job ended with status {status}", exit_code=1)
        if qualification == "fail":
            raise GitHubRunnerError("trace_qualification_failed", "trace analytics qualification failed", exit_code=1)
        return summary

    def _wait_for_terminal(self, job_id: str) -> dict[str, Any]:
        deadline = self.monotonic() + self.inputs.timeout_minutes * 60 + 180
        offset = 0
        log_bytes = 0
        log_path = self.run_directory / "job.log"
        log_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            log_flags |= os.O_NOFOLLOW
        descriptor = os.open(log_path, log_flags, PRIVATE_FILE_MODE)
        try:
            _validate_private_descriptor(descriptor)
        except BaseException:
            os.close(descriptor)
            raise
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            while True:
                if self._interrupted.is_set():
                    raise GitHubRunnerError("workflow_interrupted", "workflow received a termination signal", exit_code=130)
                job_document = self.api.request("GET", f"/jobs/{job_id}", timeout=30)
                job = job_document.get("job")
                if not isinstance(job, dict):
                    raise GitHubRunnerError("job_response_invalid", "job status response is invalid")
                log_response = self.api.request(
                    "GET",
                    f"/jobs/{job_id}/log?{urllib.parse.urlencode({'offset': offset, 'limit': 65536})}",
                    timeout=30,
                )
                log = log_response.get("log")
                if isinstance(log, dict):
                    data = log.get("data", "")
                    if isinstance(data, str) and data:
                        sanitized = redact_text(
                            data,
                            policy=RedactionPolicy(maximum_text_bytes=min(len(data.encode("utf-8")) + 1, 1024 * 1024)),
                        )
                        encoded = sanitized.encode("utf-8")
                        log_bytes += len(encoded)
                        if log_bytes > MAXIMUM_LOG_BYTES:
                            raise GitHubRunnerError("job_log_too_large", "job log exceeded the safe bound")
                        output.write(sanitized)
                        output.flush()
                    next_offset = log.get("next_offset")
                    if isinstance(next_offset, int) and next_offset >= offset:
                        offset = next_offset
                status = str(job.get("status"))
                self._write_state(
                    {
                        "phase": "polling",
                        "terminal": status in TERMINAL_STATUSES,
                        "job_id": job_id,
                        "job_status": status,
                        "log_offset": offset,
                    }
                )
                if status in TERMINAL_STATUSES:
                    return job
                if self.monotonic() >= deadline:
                    raise GitHubRunnerError("workflow_timeout", "physical QA job exceeded the workflow deadline", exit_code=124)
                self.sleep(1.0)

    def _cancel_and_wait(self, job_id: str, *, timeout: float = 60) -> dict[str, Any] | None:
        try:
            response = self.api.request("POST", f"/jobs/{job_id}/cancel", timeout=30)
        except Exception:
            return None
        deadline = self.monotonic() + timeout
        job = response.get("job") if isinstance(response, dict) else None
        while self.monotonic() < deadline:
            if isinstance(job, dict) and job.get("status") in TERMINAL_STATUSES:
                return job
            try:
                document = self.api.request("GET", f"/jobs/{job_id}", timeout=15)
            except Exception:
                self.sleep(1.0)
                continue
            job = document.get("job") if isinstance(document, dict) else None
            self.sleep(1.0)
        return job if isinstance(job, dict) else None

    def cleanup(self) -> dict[str, Any]:
        with DeviceLock(self.lock_path, self.lock_metadata()):
            state = _read_private_json(self.state_path) if self.state_path.exists() else {}
            job_id = state.get("job_id") if isinstance(state, dict) else None
            failures: list[str] = []
            if isinstance(job_id, str) and _is_uuid(job_id):
                try:
                    job_document = self.api.request("GET", f"/jobs/{job_id}", timeout=30)
                    job = job_document.get("job")
                    if isinstance(job, dict) and job.get("status") not in TERMINAL_STATUSES:
                        terminal = self._cancel_and_wait(job_id)
                        if terminal is None or terminal.get("status") not in TERMINAL_STATUSES:
                            failures.append("job_not_terminal")
                except Exception as error:
                    failures.append(f"job_cleanup:{type(error).__name__}")
            try:
                health = self.api.request("GET", "/health", timeout=30)
            except Exception as error:
                health = {"status": "unreachable"}
                failures.append(f"health:{type(error).__name__}")
            if health.get("status") != "ok":
                failures.append("agent_not_ok")
            active_job = health.get("active_job_id")
            active_live = health.get("active_live_session_id")
            if active_job is not None:
                failures.append("active_job_remains")
            if active_live is not None:
                failures.append("active_live_session_remains")
            if int(health.get("queue_depth", 0)) != 0:
                failures.append("queue_not_empty")
            device: dict[str, Any] | None = None
            try:
                inventory = self.api.request("GET", "/devices", timeout=60)
                devices = inventory.get("devices")
                if isinstance(devices, list):
                    candidates = [
                        item
                        for item in devices
                        if isinstance(item, dict)
                        and item.get("kind") == "cable"
                        and item.get("udid") == self.inputs.device_udid
                    ]
                    if len(candidates) == 1:
                        device = candidates[0]
                if device is None or device.get("ready") is not True:
                    failures.append("device_not_ready")
            except Exception as error:
                failures.append(f"device_inventory:{type(error).__name__}")
            document = {
                "schema_version": SCHEMA_VERSION,
                "status": "failed" if failures else "clean",
                "run_id": self.identity.run_id,
                "session_trace_id": self.identity.session_trace_id,
                "job_id": job_id,
                "health": redact_structured(health),
                "device": redact_structured(device),
                "failures": failures,
            }
            _write_private_json(self.run_directory / "cleanup.json", document)
            if failures:
                self._write_quarantine(document)
                self._write_state({"phase": "cleanup_failed", "terminal": True, "cleanup_failures": failures})
                raise GitHubRunnerError("cleanup_failed", "cleanup could not prove a safe idle device state", exit_code=74)
            self._write_state({"phase": "cleaned", "terminal": True, "cleanup_status": "clean"})
            return document

    def quarantine_status(self) -> dict[str, Any]:
        if not self.quarantine_path.exists():
            return {"quarantined": False}
        return {"quarantined": True, "document": _read_private_json(self.quarantine_path)}

    def clear_quarantine(self, acknowledgement: str) -> dict[str, Any]:
        from .github_host import ActivationPolicy, clear_quarantine as clear_host_quarantine

        policy = ActivationPolicy.load(self.activation_path)
        policy.assert_workflow(
            repository=self.context.repository,
            runner_user=self.context.runner_user,
            runner_name=self.context.runner_name,
            device_udid=self.inputs.device_udid,
        )
        return clear_host_quarantine(
            self.config,
            policy,
            acknowledgement,
            api=self.api,
        )

    def _summary(
        self,
        *,
        status: str,
        job: dict[str, Any] | None,
        preflight: dict[str, Any],
        evidence: dict[str, Any] | None,
        analytics: dict[str, Any] | None,
    ) -> dict[str, Any]:
        qualification = analytics.get("qualification") if isinstance(analytics, dict) else None
        return {
            "schema_version": SCHEMA_VERSION,
            "status": status,
            "operation": self.inputs.operation,
            "scenario": self.inputs.scenario,
            "device_udid": self.inputs.device_udid,
            "run_id": self.identity.run_id,
            "session_trace_id": self.identity.session_trace_id,
            "github": self.context.to_dict(),
            "job_id": job.get("id") if isinstance(job, dict) else None,
            "job_status": job.get("status") if isinstance(job, dict) else None,
            "error_code": job.get("error_code") if isinstance(job, dict) else None,
            "evidence": evidence,
            "qualification": qualification,
            "preflight_status": preflight.get("status"),
            "retention_days": self.inputs.retention_days,
        }

    def _write_state(self, updates: Mapping[str, Any]) -> None:
        current = _read_private_json(self.state_path) if self.state_path.exists() else {}
        if not isinstance(current, dict):
            current = {}
        document = {
            **current,
            **dict(updates),
            "schema_version": SCHEMA_VERSION,
            "run_id": self.identity.run_id,
            "session_trace_id": self.identity.session_trace_id,
            "github_run_id": self.context.run_id,
            "github_run_attempt": self.context.run_attempt,
            "device_udid": self.inputs.device_udid,
            "scenario": self.inputs.scenario,
        }
        _write_private_json(self.state_path, redact_structured(document))

    def _write_quarantine(self, details: Mapping[str, Any]) -> None:
        _write_private_json(
            self.quarantine_path,
            {
                "schema_version": SCHEMA_VERSION,
                "status": "quarantined",
                "run_id": self.identity.run_id,
                "session_trace_id": self.identity.session_trace_id,
                "device_udid": self.inputs.device_udid,
                "details": redact_structured(dict(details)),
            },
        )

    def _reject_quarantine(self) -> None:
        if self.quarantine_path.exists():
            document = _read_private_json(self.quarantine_path)
            raise GitHubRunnerError(
                "runner_quarantined",
                f"runner is quarantined; inspect {self.quarantine_path.name}: {redact_structured(document)}",
                exit_code=75,
            )

    def _install_signal_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, lambda _signum, _frame: self._interrupted.set())


def _choice_integer(
    environment: Mapping[str, str], name: str, choices: frozenset[int]
) -> int:
    raw = environment.get(name, "").strip()
    if not raw.isdigit():
        raise GitHubRunnerError("invalid_input", f"{name} must be an allowlisted integer", exit_code=64)
    value = int(raw)
    if value not in choices:
        raise GitHubRunnerError("invalid_input", f"{name} is outside the allowlist", exit_code=64)
    return value


def _owned_directory(path: Path, *, private: bool) -> Path:
    if path.is_symlink():
        raise GitHubRunnerError("unsafe_directory", f"directory must not be a symlink: {path}")
    resolved = path.expanduser().resolve(strict=True)
    details = resolved.stat()
    if not stat.S_ISDIR(details.st_mode):
        raise GitHubRunnerError("unsafe_directory", f"path is not a directory: {resolved}")
    if details.st_uid != os.geteuid():
        raise GitHubRunnerError("unsafe_directory_owner", f"directory is not owned by the runner: {resolved}")
    if private:
        resolved.chmod(PRIVATE_DIRECTORY_MODE)
        if stat.S_IMODE(resolved.stat().st_mode) & 0o077:
            raise GitHubRunnerError("unsafe_directory_mode", f"directory is not private: {resolved}")
    return resolved


def _assert_beneath(path: Path, root: Path, label: str) -> Path:
    resolved = path.expanduser().resolve(strict=False)
    canonical_root = root.expanduser().resolve(strict=True)
    if resolved != canonical_root and canonical_root not in resolved.parents:
        raise GitHubRunnerError(
            "path_outside_installation_home",
            f"{label} must resolve beneath the dedicated account home",
        )
    return resolved


def _assert_private_regular(path: Path) -> None:
    if path.is_symlink():
        raise GitHubRunnerError("unsafe_file", f"file must not be a symlink: {path}")
    details = path.stat()
    if not stat.S_ISREG(details.st_mode):
        raise GitHubRunnerError("unsafe_file", f"path is not a regular file: {path}")
    if details.st_uid != os.geteuid():
        raise GitHubRunnerError("unsafe_file_owner", f"file is not owned by the runner: {path}")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise GitHubRunnerError("unsafe_file_mode", f"file is not private: {path}")


def _validate_private_descriptor(descriptor: int) -> None:
    os.fchmod(descriptor, PRIVATE_FILE_MODE)
    details = os.fstat(descriptor)
    if not stat.S_ISREG(details.st_mode):
        raise GitHubRunnerError("unsafe_descriptor", "descriptor is not a regular file")
    if details.st_uid != os.geteuid():
        raise GitHubRunnerError("unsafe_descriptor_owner", "descriptor has the wrong owner")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise GitHubRunnerError("unsafe_descriptor_mode", "descriptor permissions are not private")


def _write_private_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    _owned_directory(path.parent, private=True)
    if path.is_symlink():
        raise GitHubRunnerError("unsafe_output_symlink", f"output must not be a symlink: {path}")
    data = json.dumps(document, sort_keys=True, indent=2, ensure_ascii=False).encode("utf-8") + b"\n"
    if len(data) > MAXIMUM_STATE_BYTES:
        raise GitHubRunnerError("state_too_large", f"JSON output exceeds safe bound: {path.name}")
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        try:
            _validate_private_descriptor(descriptor)
        except BaseException:
            os.close(descriptor)
            raise
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(PRIVATE_FILE_MODE)
    finally:
        temporary.unlink(missing_ok=True)


def _read_private_json(path: Path) -> Any:
    _assert_private_regular(path)
    raw = path.read_bytes()
    try:
        return loads_bounded(raw, maximum_bytes=MAXIMUM_STATE_BYTES)
    except JSONSafetyError as error:
        raise GitHubRunnerError("state_json_invalid", f"state JSON rejected: {error.code}") from error


def _is_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


def default_config_path() -> Path:
    value = os.environ.get("FACESWAP_QA_CONFIG", "").strip()
    return Path(value).expanduser() if value else Path.home() / ".faceswap-qa-agent" / "config.json"


def default_activation_path() -> Path:
    value = os.environ.get("FACESWAP_QA_ACTIVATION_FILE", "").strip()
    return Path(value).expanduser() if value else Path.home() / ".faceswap-qa-runner" / "activation.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Protected GitHub physical-device bridge")
    parser.add_argument("--config", default=str(default_config_path()))
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("run")
    subparsers.add_parser("cleanup")
    subparsers.add_parser("quarantine-status")
    clear = subparsers.add_parser("quarantine-clear")
    clear.add_argument("--acknowledge", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = AgentConfig.load(args.config)
        context = WorkflowContext.from_environment(os.environ)
        inputs = WorkflowInputs.from_environment(os.environ)
        runner = GitHubPhysicalRunner(config, context, inputs)
        if args.command == "run":
            result = runner.run()
        elif args.command == "cleanup":
            result = runner.cleanup()
        elif args.command == "quarantine-status":
            result = runner.quarantine_status()
        elif args.command == "quarantine-clear":
            result = runner.clear_quarantine(args.acknowledge)
        else:
            raise GitHubRunnerError("unsupported_command", "unsupported bridge command", exit_code=64)
        print(json.dumps(redact_structured(result), indent=2, sort_keys=True, ensure_ascii=False))
        return 0
    except GitHubRunnerError as error:
        print(
            json.dumps(
                {"error": {"code": error.code, "message": redact_text(str(error))}},
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return error.exit_code
    except Exception as error:
        print(
            json.dumps(
                {
                    "error": {
                        "code": "github_bridge_internal_error",
                        "message": redact_text(str(error)),
                    }
                },
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
