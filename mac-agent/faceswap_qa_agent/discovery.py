from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Protocol, Sequence

from .json_safety import JSONSafetyError, loads_bounded
from .models import DeviceInfo, Target, TargetKind


class DiscoveryError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class CommandRunner(Protocol):
    def run(
        self,
        arguments: Sequence[str],
        *,
        capture_output: bool = True,
        text: bool = True,
        timeout: float | None = None,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]: ...


class SubprocessCommandRunner:
    def run(
        self,
        arguments: Sequence[str],
        *,
        capture_output: bool = True,
        text: bool = True,
        timeout: float | None = None,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(arguments),
            capture_output=capture_output,
            text=text,
            timeout=timeout,
            env=env,
            check=False,
        )


class DeviceDiscovery:
    def __init__(
        self,
        command_runner: CommandRunner | None = None,
        *,
        environment: dict[str, str] | None = None,
    ) -> None:
        self.command_runner = command_runner or SubprocessCommandRunner()
        self.environment = environment

    def list_devices(self) -> list[DeviceInfo]:
        return self.list_physical_devices() + self.list_simulators()

    def list_physical_devices(self) -> list[DeviceInfo]:
        try:
            devices = self._list_physical_devicectl()
            if devices:
                return devices
        except (DiscoveryError, OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
            pass
        return self._list_physical_xctrace()

    def _list_physical_devicectl(self) -> list[DeviceInfo]:
        descriptor, raw_path = tempfile.mkstemp(prefix="faceswap-devices-", suffix=".json")
        os.close(descriptor)
        path = Path(raw_path)
        try:
            result = self.command_runner.run(
                ["xcrun", "devicectl", "list", "devices", "--json-output", str(path)],
                timeout=30,
                env=self.environment,
            )
            if result.returncode != 0 or not path.exists() or path.stat().st_size == 0:
                raise DiscoveryError(
                    "devicectl_failed",
                    (result.stderr or result.stdout or "devicectl failed").strip(),
                )
            try:
                data = loads_bounded(
                    path.read_bytes(), maximum_bytes=16 * 1024 * 1024
                )
            except JSONSafetyError as error:
                raise DiscoveryError(
                    "devicectl_invalid_json",
                    f"devicectl JSON was rejected: {error}",
                ) from error
            return self.parse_devicectl_json(data)
        finally:
            path.unlink(missing_ok=True)

    @classmethod
    def parse_devicectl_json(cls, data: Any) -> list[DeviceInfo]:
        records = cls._device_records(data)
        devices: list[DeviceInfo] = []
        for record in records:
            hardware = record.get("hardwareProperties") or {}
            properties = record.get("deviceProperties") or {}
            connection = record.get("connectionProperties") or {}
            udid = _text(hardware.get("udid") or record.get("udid"))
            reality = _text(hardware.get("reality") or record.get("reality")).lower()
            platform = _text(hardware.get("platform") or record.get("platform")).lower()
            device_type = _text(
                hardware.get("marketingName")
                or hardware.get("deviceType")
                or record.get("deviceType")
                or "iPhone"
            )
            if not udid or (reality and reality != "physical"):
                continue
            if platform and platform not in {"ios", "iphoneos"}:
                continue
            name = _text(properties.get("name") or record.get("name") or device_type)
            os_version = _text(
                properties.get("osVersionNumber") or record.get("osVersion") or "unknown"
            )
            pairing = _text(connection.get("pairingState") or record.get("pairingState")).lower()
            developer = _text(
                properties.get("developerModeStatus")
                or properties.get("developerMode")
                or record.get("developerModeStatus")
            ).lower()
            transport = _text(connection.get("transportType") or record.get("transportType"))
            reasons: list[str] = []
            if pairing and pairing != "paired":
                reasons.append(f"pairing_state={pairing}")
            if developer and developer != "enabled":
                reasons.append(f"developer_mode={developer}")
            if not pairing:
                reasons.append("pairing_state=unknown")
            if not developer:
                reasons.append("developer_mode=unknown")
            ready = not any(
                reason.startswith("pairing_state=") and reason != "pairing_state=unknown"
                or reason.startswith("developer_mode=") and reason != "developer_mode=unknown"
                for reason in reasons
            )
            devices.append(
                DeviceInfo(
                    kind=TargetKind.CABLE,
                    udid=udid,
                    name=name,
                    os_version=os_version,
                    device_type=device_type,
                    ready=ready,
                    readiness_reasons=tuple(reasons),
                    identifier=_text(record.get("identifier")) or None,
                    transport=transport or None,
                    pairing_state=pairing or None,
                    developer_mode=developer or None,
                )
            )
        return sorted(devices, key=lambda item: (item.name.lower(), item.udid))

    @classmethod
    def _device_records(cls, data: Any) -> list[dict[str, Any]]:
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
        if not isinstance(data, dict):
            return []
        direct = data.get("devices")
        if isinstance(direct, list):
            return [item for item in direct if isinstance(item, dict)]
        result = data.get("result")
        if isinstance(result, dict) and isinstance(result.get("devices"), list):
            return [item for item in result["devices"] if isinstance(item, dict)]
        for value in data.values():
            if isinstance(value, dict):
                records = cls._device_records(value)
                if records:
                    return records
        return []

    def _list_physical_xctrace(self) -> list[DeviceInfo]:
        try:
            result = self.command_runner.run(
                ["xcrun", "xctrace", "list", "devices"],
                timeout=30,
                env=self.environment,
            )
        except (OSError, subprocess.SubprocessError):
            return []
        if result.returncode != 0:
            return []
        devices: list[DeviceInfo] = []
        in_devices = False
        pattern = re.compile(r"^(.*?)\s+\(([^()]*)\)\s+\(([A-Za-z0-9-]+)\)$")
        for raw_line in result.stdout.splitlines():
            line = raw_line.strip()
            if line == "== Devices ==":
                in_devices = True
                continue
            if line.startswith("== ") and line != "== Devices ==":
                in_devices = False
            if not in_devices:
                continue
            match = pattern.match(line)
            if not match:
                continue
            name, os_version, udid = match.groups()
            if udid.lower().startswith("mac") or "mac" in name.lower():
                continue
            devices.append(
                DeviceInfo(
                    kind=TargetKind.CABLE,
                    udid=udid,
                    name=name.strip(),
                    os_version=os_version.strip(),
                    device_type="iPhone",
                    ready=True,
                    readiness_reasons=("readiness_unverified_xctrace_fallback",),
                )
            )
        return sorted(devices, key=lambda item: (item.name.lower(), item.udid))

    def list_simulators(self) -> list[DeviceInfo]:
        try:
            result = self.command_runner.run(
                ["xcrun", "simctl", "list", "devices", "available", "--json"],
                timeout=30,
                env=self.environment,
            )
        except (OSError, subprocess.SubprocessError):
            return []
        if result.returncode != 0:
            return []
        try:
            return self.parse_simctl_json(
                loads_bounded(
                    result.stdout, maximum_bytes=16 * 1024 * 1024
                )
            )
        except (ValueError, JSONSafetyError):
            return []

    @staticmethod
    def parse_simctl_json(data: Any) -> list[DeviceInfo]:
        if not isinstance(data, dict) or not isinstance(data.get("devices"), dict):
            return []
        devices: list[DeviceInfo] = []
        for runtime, values in data["devices"].items():
            if not isinstance(values, list):
                continue
            os_version = _runtime_version(runtime)
            for value in values:
                if not isinstance(value, dict):
                    continue
                udid = _text(value.get("udid"))
                name = _text(value.get("name"))
                if not udid or not name:
                    continue
                available = bool(value.get("isAvailable", True))
                devices.append(
                    DeviceInfo(
                        kind=TargetKind.SIMULATOR,
                        udid=udid,
                        name=name,
                        os_version=os_version,
                        device_type="Simulator",
                        ready=available,
                        readiness_reasons=() if available else ("unavailable",),
                        state=_text(value.get("state")) or None,
                    )
                )
        return sorted(
            devices,
            key=lambda item: (_version_key(item.os_version), item.name.lower(), item.udid),
            reverse=True,
        )

    def resolve(self, target: Target, default_simulator_name: str) -> DeviceInfo:
        if target.kind == TargetKind.CABLE:
            return self.resolve_cable(target)
        return self.resolve_simulator(target, default_simulator_name)

    def resolve_cable(self, target: Target) -> DeviceInfo:
        devices = self.list_physical_devices()
        if target.udid:
            matches = [device for device in devices if device.udid == target.udid]
        elif target.name:
            matches = [device for device in devices if device.name == target.name]
        else:
            matches = [device for device in devices if device.ready]
        if not matches:
            raise DiscoveryError("device_unavailable", "no matching cable iPhone was discovered")
        if len(matches) > 1:
            raise DiscoveryError(
                "multiple_cable_devices",
                "multiple cable iPhones match; submit an explicit target.udid",
            )
        device = matches[0]
        if not device.ready:
            reasons = ", ".join(device.readiness_reasons) or "unknown readiness failure"
            raise DiscoveryError("device_unavailable", f"cable iPhone is not ready: {reasons}")
        return device

    def resolve_simulator(self, target: Target, default_name: str) -> DeviceInfo:
        devices = self.list_simulators()
        if target.udid:
            matches = [device for device in devices if device.udid == target.udid]
        else:
            requested_name = target.name or default_name
            matches = [device for device in devices if device.name == requested_name]
            if target.os != "latest":
                matches = [device for device in matches if device.os_version == target.os]
        matches = [device for device in matches if device.ready]
        if not matches:
            raise DiscoveryError("simulator_unavailable", "no matching available simulator was found")
        selected = sorted(
            matches,
            key=lambda item: (_version_key(item.os_version), item.name.lower(), item.udid),
            reverse=True,
        )[0]
        return selected

    def ensure_simulator_booted(self, device: DeviceInfo) -> None:
        if device.kind != TargetKind.SIMULATOR:
            raise ValueError("device is not a simulator")
        if (device.state or "").lower() != "booted":
            result = self.command_runner.run(
                ["xcrun", "simctl", "boot", device.udid],
                timeout=60,
                env=self.environment,
            )
            if result.returncode != 0 and "current state: Booted" not in (result.stderr or ""):
                raise DiscoveryError(
                    "simulator_unavailable",
                    (result.stderr or result.stdout or "simulator boot failed").strip(),
                )
        result = self.command_runner.run(
            ["xcrun", "simctl", "bootstatus", device.udid, "-b"],
            timeout=180,
            env=self.environment,
        )
        if result.returncode != 0:
            raise DiscoveryError(
                "simulator_unavailable",
                (result.stderr or result.stdout or "simulator bootstatus failed").strip(),
            )


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _runtime_version(runtime: str) -> str:
    marker = "SimRuntime.iOS-"
    if marker in runtime:
        return runtime.split(marker, 1)[1].replace("-", ".")
    tail = runtime.rsplit(".", 1)[-1]
    return tail.replace("iOS-", "").replace("-", ".")


def _version_key(version: str) -> tuple[int, ...]:
    values = re.findall(r"\d+", version)
    return tuple(int(value) for value in values) or (0,)
