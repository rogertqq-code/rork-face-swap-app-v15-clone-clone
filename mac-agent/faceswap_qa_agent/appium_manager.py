from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

from .config import AgentConfig
from .json_safety import JSONSafetyError, loads_bounded
from .live_models import AppiumProcessStatus


class AppiumManagerError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class AppiumState:
    status: AppiumProcessStatus
    url: str
    pid: int | None
    started_at: float | None
    version: str | None
    managed: bool
    last_error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status.value,
            "url": self.url,
            "pid": self.pid,
            "started_at": self.started_at,
            "version": self.version,
            "managed": self.managed,
            "last_error": self.last_error,
        }


class AppiumManager:
    def __init__(
        self,
        config: AgentConfig,
        *,
        popen_factory: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
        command_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.config = config
        self.popen_factory = popen_factory
        self.command_runner = command_runner
        self.sleep = sleep
        self.monotonic = monotonic
        self._lock = threading.RLock()
        self._process: subprocess.Popen[str] | None = None
        self._log_handle: Any = None
        self._started_at: float | None = None
        self._last_error: str | None = None
        self._external_healthy = False
        self._log_start_offset = 0

    @property
    def status_url(self) -> str:
        return self.config.appium.url.rstrip("/") + "/status"

    @property
    def log_path(self) -> Path:
        return self.config.paths.logs / "appium-server.log"

    def log_checkpoint(self) -> int:
        with self._lock:
            if self._log_handle is not None:
                self._log_handle.flush()
            try:
                return self.log_path.stat().st_size
            except OSError:
                return 0

    def read_log_since(self, offset: int, *, maximum_bytes: int) -> bytes:
        maximum_bytes = max(1024, min(int(maximum_bytes), 64 * 1024 * 1024))
        with self._lock:
            if self._log_handle is not None:
                self._log_handle.flush()
            try:
                size = self.log_path.stat().st_size
                start = max(0, min(int(offset), size))
                marker = b"[earlier session log bytes omitted]\n"
                truncated = size - start > maximum_bytes
                payload_limit = maximum_bytes - len(marker) if truncated else maximum_bytes
                if truncated:
                    start = max(start, size - payload_limit)
                with self.log_path.open("rb") as handle:
                    handle.seek(start)
                    data = handle.read(payload_limit)
            except OSError as error:
                raise AppiumManagerError(
                    "appium_log_unavailable", f"unable to retain Appium/WDA log: {error}"
                ) from error
        if truncated:
            return marker + data
        return data

    def build_command(self) -> list[str]:
        return [
            self.config.appium.executable,
            "server",
            "--address",
            self.config.appium.host,
            "--port",
            str(self.config.appium.port),
            "--base-path",
            self.config.appium.base_path,
            "--use-plugins",
            self.config.appium.plugin_name,
            "--log-no-colors",
            "--log-timestamp",
        ]

    def verify_installation(self) -> dict[str, str]:
        version = self._run_version([self.config.appium.executable, "--version"])
        if version != self.config.appium.version:
            raise AppiumManagerError(
                "appium_version_mismatch",
                f"expected Appium {self.config.appium.version}, found {version}",
            )
        drivers = self.command_runner(
            [self.config.appium.executable, "driver", "list", "--installed", "--json"],
            capture_output=True,
            text=True,
            timeout=30,
            env=self._environment(),
            check=False,
        )
        if drivers.returncode != 0:
            raise AppiumManagerError(
                "xcuitest_driver_missing",
                (drivers.stderr or drivers.stdout or "unable to list Appium drivers").strip(),
            )
        driver_version = self._extract_extension_version(drivers.stdout, "xcuitest")
        if driver_version != self.config.appium.xcuitest_driver_version:
            raise AppiumManagerError(
                "xcuitest_driver_version_mismatch",
                f"expected XCUITest driver {self.config.appium.xcuitest_driver_version}, found {driver_version}",
            )
        plugins = self.command_runner(
            [self.config.appium.executable, "plugin", "list", "--installed", "--json"],
            capture_output=True,
            text=True,
            timeout=30,
            env=self._environment(),
            check=False,
        )
        if plugins.returncode != 0:
            raise AppiumManagerError(
                "appium_plugin_missing",
                (plugins.stderr or plugins.stdout or "unable to list Appium plugins").strip(),
            )
        plugin_version = self._extract_extension_version(
            plugins.stdout, self.config.appium.plugin_name
        )
        if plugin_version != self.config.appium.plugin_version:
            raise AppiumManagerError(
                "appium_plugin_version_mismatch",
                f"expected plugin {self.config.appium.plugin_name} {self.config.appium.plugin_version}, found {plugin_version}",
            )
        remotexpc_path = (
            self.config.appium.home
            / "node_modules"
            / "appium-ios-remotexpc"
            / "package.json"
        )
        try:
            remotexpc_document = loads_bounded(
                remotexpc_path.read_bytes(), maximum_bytes=1024 * 1024
            )
            remotexpc_version = str(remotexpc_document.get("version", "")).strip()
        except (OSError, JSONSafetyError, AttributeError) as error:
            raise AppiumManagerError(
                "remotexpc_missing",
                f"unable to load pinned RemoteXPC package metadata: {error}",
            ) from error
        if remotexpc_version != self.config.appium.remotexpc_version:
            raise AppiumManagerError(
                "remotexpc_version_mismatch",
                f"expected RemoteXPC {self.config.appium.remotexpc_version}, found {remotexpc_version or 'unknown'}",
            )
        return {
            "appium": version,
            "xcuitest": driver_version,
            "plugin": f"{self.config.appium.plugin_name}@{plugin_version}",
            "remotexpc": remotexpc_version,
        }

    def ensure_started(self) -> AppiumState:
        with self._lock:
            if self.is_healthy():
                if self._process is not None and self._process.poll() is None:
                    return self.state()
                recorded_pid = self._read_pid()
                if recorded_pid and self.terminate_verified_stale_pid(recorded_pid):
                    self._wait_until_stopped()
                    self._remove_pid()
                else:
                    raise AppiumManagerError(
                        "appium_port_in_use",
                        "a healthy but unmanaged Appium server already owns the configured port",
                    )
            if self._process is not None and self._process.poll() is None:
                self._terminate_process(self._process)
            self.verify_installation()
            log_path = self.log_path
            log_path.parent.mkdir(parents=True, exist_ok=True)
            self._log_start_offset = log_path.stat().st_size if log_path.exists() else 0
            self._log_handle = log_path.open("a", encoding="utf-8", buffering=1)
            command = self.build_command()
            self._log_handle.write(
                json.dumps({"event": "start", "argv": command, "timestamp": time.time()}) + "\n"
            )
            self._process = self.popen_factory(
                command,
                cwd=str(self.config.config_dir),
                env=self._environment(),
                stdout=self._log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            self._started_at = time.time()
            self._write_pid(self._process.pid)
            self._last_error = None
            self._external_healthy = False
            deadline = self.monotonic() + self.config.appium.startup_timeout_seconds
            while self.monotonic() < deadline:
                if self._process.poll() is not None:
                    code = self._process.returncode
                    self._remove_pid()
                    self._close_log()
                    self._last_error = f"Appium exited during startup with code {code}"
                    raise AppiumManagerError("appium_start_failed", self._last_error)
                if self.is_healthy():
                    try:
                        self._validate_current_startup_log(log_path)
                    except AppiumManagerError as error:
                        self._last_error = str(error)
                        self._terminate_process(self._process)
                        self._remove_pid()
                        self._close_log()
                        raise
                    return self.state()
                self.sleep(0.25)
            self._terminate_process(self._process)
            self._remove_pid()
            self._close_log()
            self._last_error = "Appium did not become healthy before the startup deadline"
            raise AppiumManagerError("appium_start_timeout", self._last_error)

    def is_healthy(self) -> bool:
        request = urllib.request.Request(
            self.status_url, headers={"Accept": "application/json"}, method="GET"
        )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                if response.status != 200:
                    return False
                payload = loads_bounded(
                    response.read(65536), maximum_bytes=65536
                )
        except (OSError, urllib.error.URLError, JSONSafetyError):
            return False
        value = payload.get("value", payload) if isinstance(payload, dict) else None
        if not isinstance(value, dict):
            return False
        return value.get("ready", True) is not False

    def state(self) -> AppiumState:
        with self._lock:
            process_alive = self._process is not None and self._process.poll() is None
            healthy = self.is_healthy()
            if healthy:
                status = AppiumProcessStatus.HEALTHY
            elif process_alive:
                status = AppiumProcessStatus.STARTING
            elif self._last_error:
                status = AppiumProcessStatus.UNHEALTHY
            else:
                status = AppiumProcessStatus.STOPPED
            return AppiumState(
                status=status,
                url=self.config.appium.url,
                pid=self._process.pid if process_alive and self._process is not None else None,
                started_at=self._started_at,
                version=self.config.appium.version if healthy else None,
                managed=process_alive,
                last_error=self._last_error,
            )

    def stop(self) -> AppiumState:
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                self._terminate_process(self._process)
            elif self._process is None:
                recorded_pid = self._read_pid()
                if recorded_pid:
                    self.terminate_verified_stale_pid(recorded_pid)
            self._remove_pid()
            self._process = None
            self._external_healthy = False
            self._started_at = None
            self._close_log()
            return self.state()

    @property
    def pid_path(self) -> Path:
        return self.config.api.token_file.parent / "appium.pid"

    def _write_pid(self, pid: int) -> None:
        temporary = self.pid_path.with_suffix(".pid.new")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(f"{pid}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.pid_path)
        self.pid_path.chmod(0o600)

    def _read_pid(self) -> int | None:
        try:
            value = int(self.pid_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return None
        return value if value > 1 else None

    def _remove_pid(self) -> None:
        self.pid_path.unlink(missing_ok=True)

    def _wait_until_stopped(self) -> None:
        deadline = self.monotonic() + self.config.appium.shutdown_grace_seconds
        while self.is_healthy() and self.monotonic() < deadline:
            self.sleep(0.1)
        if self.is_healthy():
            raise AppiumManagerError(
                "appium_stale_process_survived",
                "verified stale Appium process did not release the configured port",
            )

    def _terminate_process(self, process: subprocess.Popen[str]) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return
        deadline = self.monotonic() + self.config.appium.shutdown_grace_seconds
        while process.poll() is None and self.monotonic() < deadline:
            self.sleep(0.1)
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def terminate_verified_stale_pid(self, pid: int) -> bool:
        try:
            result = self.command_runner(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        command = result.stdout.strip()
        expected = (
            Path(self.config.appium.executable).name,
            "server",
            str(self.config.appium.port),
            self.config.appium.plugin_name,
        )
        if result.returncode != 0 or not all(marker in command for marker in expected):
            return False
        try:
            os.killpg(pid, signal.SIGTERM)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def _validate_current_startup_log(self, log_path: Path) -> None:
        if self._log_handle is not None:
            self._log_handle.flush()
        try:
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(self._log_start_offset)
                source = handle.read(2 * 1024 * 1024)
        except OSError as error:
            raise AppiumManagerError(
                "appium_start_log_unavailable", f"unable to verify Appium startup log: {error}"
            ) from error
        lowered = source.lower()
        if "could not load driver 'xcuitest'" in lowered:
            raise AppiumManagerError(
                "xcuitest_driver_load_failed",
                "Appium became healthy but the XCUITest driver failed to load",
            )
        if f"could not load plugin '{self.config.appium.plugin_name.lower()}'" in lowered:
            raise AppiumManagerError(
                "appium_plugin_load_failed",
                f"Appium became healthy but plugin {self.config.appium.plugin_name} failed to load",
            )
        driver_loaded = (
            "xcuitestdriver has been successfully loaded" in lowered
            or f"xcuitest@{self.config.appium.xcuitest_driver_version}" in lowered
        )
        plugin_loaded = (
            "faceswapliveplugin has been successfully loaded" in lowered
            or (
                f"{self.config.appium.plugin_name}@" in lowered
                and "(active)" in lowered
            )
        )
        if not driver_loaded:
            raise AppiumManagerError(
                "xcuitest_driver_load_unverified",
                "Appium startup did not confirm that XCUITestDriver loaded",
            )
        if not plugin_loaded:
            raise AppiumManagerError(
                "appium_plugin_load_unverified",
                f"Appium startup did not confirm that plugin {self.config.appium.plugin_name} loaded",
            )

    def _run_version(self, command: Sequence[str]) -> str:
        result = self.command_runner(
            list(command),
            capture_output=True,
            text=True,
            timeout=30,
            env=self._environment(),
            check=False,
        )
        if result.returncode != 0:
            raise AppiumManagerError(
                "appium_missing",
                (result.stderr or result.stdout or "Appium is not executable").strip(),
            )
        return result.stdout.strip().lstrip("v")

    @staticmethod
    def _extract_extension_version(payload: str, name: str) -> str:
        try:
            data = loads_bounded(payload, maximum_bytes=2 * 1024 * 1024)
        except JSONSafetyError:
            data = None
        if isinstance(data, dict):
            candidate = data.get(name)
            if isinstance(candidate, dict):
                version = candidate.get("version")
                if isinstance(version, str):
                    return version
            if isinstance(candidate, str):
                return candidate
            for key, value in data.items():
                if name in key and isinstance(value, dict) and isinstance(value.get("version"), str):
                    return value["version"]
        return "unknown"

    def _environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(self.config.environment())
        environment["FACESWAP_LIVE_ENABLED"] = "1"
        environment["FACESWAP_QA_BUNDLE_ID"] = self.config.live.bundle_id
        return environment

    def _close_log(self) -> None:
        if self._log_handle is not None:
            try:
                self._log_handle.close()
            finally:
                self._log_handle = None
