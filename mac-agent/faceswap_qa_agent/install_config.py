from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
from typing import Any, Mapping, Sequence

from .json_safety import JSONSafetyError, loads_bounded


def build_config(
    existing: Mapping[str, Any],
    *,
    repository_root: Path,
    appium_executable: Path,
    appium_home: Path,
) -> dict[str, Any]:
    data = copy.deepcopy(dict(existing)) if existing else {}
    if not isinstance(data, dict):
        raise ValueError("configuration root must be an object")

    api = _section(data, "api")
    api.setdefault("host", "127.0.0.1")
    api.setdefault("port", 8765)
    api.setdefault("token_file", "state/api-token")

    paths = _section(data, "paths")
    paths.setdefault("ios_root", str((repository_root / "ios").resolve()))
    paths.setdefault("project", "FaceSwapLiveAppV17.xcodeproj")
    paths.setdefault("database", "state/jobs.sqlite3")
    paths.setdefault("artifacts", "artifacts")
    paths.setdefault("logs", "logs")

    xcode = _section(data, "xcode")
    xcode.setdefault("scheme", "FaceSwapLiveAppV17-QA")
    xcode.setdefault("test_plan", "FaceSwapLiveAppV17-QA")
    xcode.setdefault("developer_dir", "")
    xcode.setdefault("default_simulator_name", "iPhone 16 Pro")

    appium = _section(data, "appium")
    appium.update(
        {
            "executable": str(appium_executable.resolve()),
            "home": str(appium_home.resolve()),
            "host": "127.0.0.1",
            "version": "3.6.0",
            "xcuitest_driver_version": "12.1.4",
            "plugin_name": "faceswap-live",
            "plugin_version": "1.0.0",
            "remotexpc_version": "5.13.2",
        }
    )
    appium.setdefault("port", 4723)
    appium.setdefault("base_path", "/")
    appium.setdefault("startup_timeout_seconds", 120)
    appium.setdefault("request_timeout_seconds", 240)
    appium.setdefault("shutdown_grace_seconds", 10)

    wda = _section(data, "wda")
    wda.setdefault("updated_bundle_id", "")
    wda.setdefault("xcode_org_id", "")
    wda.setdefault("xcode_signing_id", "Apple Development")
    wda.setdefault("xcode_config_file", "")
    wda.setdefault("derived_data_path", "state/DerivedData-WebDriverAgent")
    wda.setdefault("reuse", True)
    wda.setdefault("use_preinstalled", False)
    wda.setdefault("launch_timeout_ms", 120000)
    wda.setdefault("connection_timeout_ms", 240000)
    wda.setdefault("startup_retries", 2)
    wda.setdefault("local_ports", {"start": 8100, "end": 8199})
    wda.setdefault("mjpeg_ports", {"start": 9100, "end": 9199})

    live = _section(data, "live")
    live.update({"bundle_id": "app.rork.face-swap-live-app-v17.qa"})
    live.setdefault("default_lease_seconds", 600)
    live.setdefault("maximum_lease_seconds", 3600)
    live.setdefault("watchdog_interval_seconds", 5)
    live.setdefault("event_history_limit", 5000)
    live.setdefault("maximum_observation_bytes", 8 * 1024 * 1024)
    live.setdefault("maximum_action_text_length", 16384)
    live.setdefault("sse_heartbeat_seconds", 15)
    live.setdefault("max_sse_clients", 16)

    limits = _section(data, "limits")
    limits.setdefault("max_request_bytes", 262144)
    limits.setdefault("default_timeout_seconds", 1800)
    limits.setdefault("maximum_timeout_seconds", 7200)
    limits.setdefault("maximum_retries", 2)
    limits.setdefault("retention_hours", 168)
    limits.setdefault("kill_grace_seconds", 10)
    return data


def migrate(
    path: Path,
    *,
    repository_root: Path,
    appium_executable: Path,
    appium_home: Path,
) -> dict[str, Any]:
    existing: dict[str, Any] = {}
    if path.exists():
        try:
            value = loads_bounded(path.read_bytes(), maximum_bytes=1024 * 1024)
        except JSONSafetyError as error:
            raise ValueError(f"existing configuration JSON was rejected: {error}") from error
        if not isinstance(value, dict):
            raise ValueError("configuration root must be an object")
        existing = value
    data = build_config(
        existing,
        repository_root=repository_root,
        appium_executable=appium_executable,
        appium_home=appium_home,
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    path.chmod(0o600)
    return data


def _section(data: dict[str, Any], name: str) -> dict[str, Any]:
    value = data.setdefault(name, {})
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--appium-executable", type=Path, required=True)
    parser.add_argument("--appium-home", type=Path, required=True)
    args = parser.parse_args(argv)
    migrate(
        args.path.expanduser().resolve(),
        repository_root=args.repository_root.expanduser().resolve(),
        appium_executable=args.appium_executable.expanduser().resolve(),
        appium_home=args.appium_home.expanduser().resolve(),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
