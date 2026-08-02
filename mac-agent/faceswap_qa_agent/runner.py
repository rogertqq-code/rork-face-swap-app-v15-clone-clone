from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

from .config import AgentConfig
from .discovery import DeviceDiscovery, DiscoveryError
from .json_safety import loads_bounded
from .models import Artifact, Job, RunResult, TargetKind, utc_timestamp
from .redaction import redact_structured
from .store import JobStore
from .trace_context import TraceContext


class XcodeRunner:
    def __init__(
        self,
        config: AgentConfig,
        store: JobStore,
        discovery: DeviceDiscovery,
        *,
        popen_factory: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.config = config
        self.store = store
        self.discovery = discovery
        self.popen_factory = popen_factory
        self.monotonic = monotonic
        self.sleep = sleep

    def run(self, job: Job) -> RunResult:
        attempt_dir = self._attempt_directory(job)
        result_bundle = attempt_dir / "result.xcresult"
        log_path = attempt_dir / "xcodebuild.log"
        try:
            device = self.discovery.resolve(
                job.request.target, self.config.xcode.default_simulator_name
            )
            if device.kind == TargetKind.SIMULATOR:
                self.discovery.ensure_simulator_booted(device)
            destination = (
                f"platform=iOS Simulator,id={device.udid}"
                if device.kind == TargetKind.SIMULATOR
                else f"platform=iOS,id={device.udid}"
            )
            command = self.build_command(job, destination, result_bundle)
            trace_context = TraceContext.create(
                session_trace_id=job.request.session_trace_id,
                operation_trace_id=job.id,
            )
            self._write_json(
                attempt_dir / "request.json",
                redact_structured(job.request.to_dict()),
            )
            self._write_json(
                attempt_dir / "trace_context.json",
                {
                    **trace_context.to_dict(),
                    "job_id": job.id,
                    "run_id": job.request.run_id,
                    "attempt": job.attempt,
                },
            )
            self._write_json(attempt_dir / "resolved.json", device.to_dict())
            self._write_json(attempt_dir / "command.json", {"arguments": command})
            result = self._execute(job, command, log_path, result_bundle)
        except DiscoveryError as error:
            self._write_json(
                attempt_dir / "failure.json",
                {"code": error.code, "message": str(error), "timestamp": utc_timestamp()},
            )
            result = RunResult(
                success=False,
                exit_code=None,
                error_code=error.code,
                error_message=str(error),
                result_path=None,
            )
        except Exception as error:  # Runner boundaries convert failures into durable results.
            self._write_json(
                attempt_dir / "failure.json",
                {"code": "runner_error", "message": str(error), "timestamp": utc_timestamp()},
            )
            result = RunResult(
                success=False,
                exit_code=None,
                error_code="runner_error",
                error_message=str(error),
                result_path=None,
            )
        artifacts = tuple(self.collect_artifacts(attempt_dir))
        return RunResult(
            success=result.success,
            exit_code=result.exit_code,
            error_code=result.error_code,
            error_message=result.error_message,
            result_path=result.result_path,
            artifacts=artifacts,
        )

    def build_command(self, job: Job, destination: str, result_bundle: Path) -> list[str]:
        timeout = job.request.timeout_seconds
        default_allowance = min(max(60, timeout // 2), 600)
        maximum_allowance = min(max(default_allowance, timeout), self.config.limits.maximum_timeout_seconds)
        configuration = (
            "Simulator" if job.request.target.kind == TargetKind.SIMULATOR else "Cable Device"
        )
        command = [
            "xcodebuild",
            "test",
            "-project",
            str(self.config.paths.project_path),
            "-scheme",
            self.config.xcode.scheme,
            "-testPlan",
            self.config.xcode.test_plan,
            "-only-test-configuration",
            configuration,
            "-destination",
            destination,
            "-parallel-testing-enabled",
            "NO",
            "-test-timeouts-enabled",
            "YES",
            "-default-test-execution-time-allowance",
            str(default_allowance),
            "-maximum-test-execution-time-allowance",
            str(maximum_allowance),
            "-collect-test-diagnostics",
            "on-failure",
            "-resultBundlePath",
            str(result_bundle),
        ]
        if job.request.target.kind == TargetKind.CABLE:
            command.append("-allowProvisioningUpdates")
        command.extend(f"-only-testing:{identifier}" for identifier in job.request.only_testing)
        command.extend(f"-skip-testing:{identifier}" for identifier in job.request.skip_testing)
        return command

    def _execute(
        self,
        job: Job,
        command: list[str],
        log_path: Path,
        result_bundle: Path,
    ) -> RunResult:
        environment = os.environ.copy()
        environment.update(self.config.environment())
        trace_context = TraceContext.create(
            session_trace_id=job.request.session_trace_id,
            operation_trace_id=job.id,
        )
        environment.update(
            {
                "FACESWAP_QA_JOB_ID": job.id,
                "FACESWAP_QA_RUN_ID": job.request.run_id,
                "FACESWAP_QA_SESSION_TRACE_ID": trace_context.session_trace_id,
                "FACESWAP_QA_OPERATION_TRACE_ID": trace_context.operation_trace_id,
                "FACESWAP_QA_SPAN_ID": trace_context.span_id,
                "FACESWAP_QA_TRACEPARENT": trace_context.traceparent,
                "FACESWAP_QA_ATTEMPT": str(job.attempt),
            }
        )
        started = self.monotonic()
        with log_path.open("w", encoding="utf-8", buffering=1) as log:
            log.write(f"job_id={job.id}\nattempt={job.attempt}\n")
            log.write("argv=" + json.dumps(command) + "\n")
            log.flush()
            process = self.popen_factory(
                command,
                cwd=str(self.config.paths.ios_root),
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            self.store.set_pid(job.id, process.pid)
            termination_code: str | None = None
            termination_message: str | None = None
            while process.poll() is None:
                if self.store.is_cancel_requested(job.id):
                    termination_code = "cancelled"
                    termination_message = "job cancellation was requested"
                    self._terminate_process_group(process)
                    break
                if self.monotonic() - started >= job.request.timeout_seconds:
                    termination_code = "timeout"
                    termination_message = (
                        f"xcodebuild exceeded {job.request.timeout_seconds} seconds"
                    )
                    self._terminate_process_group(process)
                    break
                self.sleep(0.2)
            exit_code = process.wait()
            elapsed = self.monotonic() - started
            log.write(f"\nexit_code={exit_code}\nelapsed_seconds={elapsed:.3f}\n")
        self.store.set_pid(job.id, None)
        relative_result = self._relative_artifact_path(result_bundle) if result_bundle.exists() else None
        if termination_code:
            return RunResult(
                success=False,
                exit_code=exit_code,
                error_code=termination_code,
                error_message=termination_message,
                result_path=relative_result,
            )
        if exit_code == 0 and result_bundle.exists():
            return RunResult(
                success=True,
                exit_code=0,
                error_code=None,
                error_message=None,
                result_path=relative_result,
            )
        if exit_code == 0:
            return RunResult(
                success=False,
                exit_code=0,
                error_code="result_bundle_missing",
                error_message="xcodebuild succeeded without producing result.xcresult",
                result_path=None,
            )
        code, message = self._classify_failure(exit_code, log_path)
        return RunResult(
            success=False,
            exit_code=exit_code,
            error_code=code,
            error_message=message,
            result_path=relative_result,
        )

    def _terminate_process_group(self, process: subprocess.Popen[str]) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return
        deadline = self.monotonic() + self.config.limits.kill_grace_seconds
        while process.poll() is None and self.monotonic() < deadline:
            self.sleep(0.1)
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def _attempt_directory(self, job: Job) -> Path:
        job_root = (self.config.paths.artifacts / job.id).resolve()
        try:
            job_root.relative_to(self.config.paths.artifacts.resolve())
        except ValueError as error:
            raise RuntimeError("job artifact path escaped configured root") from error
        attempt_dir = job_root / f"attempt-{job.attempt:02d}"
        if attempt_dir.exists():
            shutil.rmtree(attempt_dir)
        attempt_dir.mkdir(parents=True, exist_ok=False)
        return attempt_dir

    @staticmethod
    def _write_json(path: Path, value: Any) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    def collect_artifacts(self, attempt_dir: Path) -> list[Artifact]:
        artifacts: list[Artifact] = []
        for path in sorted(attempt_dir.iterdir(), key=lambda item: item.name):
            if path.is_symlink():
                continue
            kind = "xcresult" if path.suffix == ".xcresult" else path.suffix.lstrip(".") or "file"
            size, digest = _path_digest(path)
            artifacts.append(
                Artifact(
                    path=self._relative_artifact_path(path),
                    kind=kind,
                    byte_size=size,
                    sha256=digest,
                    session_trace_id=(
                        TraceContext.create(
                            session_trace_id=(
                                self._read_trace_root(attempt_dir)
                            )
                        ).session_trace_id
                    ),
                    content_type=(
                        "application/json"
                        if path.suffix == ".json"
                        else "text/plain"
                        if path.suffix == ".log"
                        else "application/octet-stream"
                    ),
                    provenance="xcode-runner",
                    redaction_state=(
                        "structured_redacted"
                        if path.name in {"request.json", "resolved.json", "command.json", "trace_context.json"}
                        else "not_applicable"
                    ),
                )
            )
        return artifacts

    @staticmethod
    def _read_trace_root(attempt_dir: Path) -> str:
        value = loads_bounded(
            (attempt_dir / "trace_context.json").read_bytes(),
            maximum_bytes=64 * 1024,
        )
        return str(value["session_trace_id"])

    def _relative_artifact_path(self, path: Path) -> str:
        resolved = path.resolve()
        try:
            return str(resolved.relative_to(self.config.paths.artifacts.resolve()))
        except ValueError as error:
            raise RuntimeError("artifact path escaped configured root") from error

    @staticmethod
    def _classify_failure(exit_code: int, log_path: Path) -> tuple[str, str]:
        try:
            tail = log_path.read_text(encoding="utf-8", errors="replace")[-131072:]
        except OSError:
            tail = ""
        lowered = tail.lower()
        if any(term in lowered for term in ("device disconnected", "device is not connected")):
            return "device_unavailable", "the cable device disconnected during xcodebuild"
        if any(term in lowered for term in ("device is locked", "unlock the device")):
            return "device_unavailable", "the cable device is locked"
        if any(term in lowered for term in ("provisioning profile", "code signing", "requires a development team")):
            return "provisioning_failed", "Xcode code signing or provisioning failed"
        if "failed to boot" in lowered or "simulator" in lowered and "unavailable" in lowered:
            return "simulator_unavailable", "the selected simulator became unavailable"
        if exit_code < 0:
            return "xcodebuild_interrupted", f"xcodebuild terminated by signal {-exit_code}"
        return "xcodebuild_failed", f"xcodebuild exited with code {exit_code}"


def _path_digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    if path.is_file():
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                size += len(block)
                digest.update(block)
        return size, digest.hexdigest()
    for child in sorted((item for item in path.rglob("*") if item.is_file()), key=str):
        if child.is_symlink():
            continue
        relative = str(child.relative_to(path)).encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        with child.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                size += len(block)
                digest.update(block)
    return size, digest.hexdigest()
