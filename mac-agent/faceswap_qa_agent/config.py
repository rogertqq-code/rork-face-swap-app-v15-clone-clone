from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .json_safety import JSONSafetyError, loads_bounded


@dataclass(frozen=True, slots=True)
class ApiConfig:
    host: str
    port: int
    token_file: Path


@dataclass(frozen=True, slots=True)
class PathsConfig:
    ios_root: Path
    project: str
    database: Path
    artifacts: Path
    logs: Path

    @property
    def project_path(self) -> Path:
        return (self.ios_root / self.project).resolve()


@dataclass(frozen=True, slots=True)
class XcodeConfig:
    scheme: str
    test_plan: str
    developer_dir: str
    default_simulator_name: str


@dataclass(frozen=True, slots=True)
class LimitsConfig:
    max_request_bytes: int
    default_timeout_seconds: int
    maximum_timeout_seconds: int
    maximum_retries: int
    retention_hours: int
    kill_grace_seconds: int


@dataclass(frozen=True, slots=True)
class PortRange:
    start: int
    end: int

    def __post_init__(self) -> None:
        if self.start < 1 or self.end > 65535 or self.start > self.end:
            raise ValueError("invalid port range")

    def values(self) -> range:
        return range(self.start, self.end + 1)

    def to_dict(self) -> dict[str, int]:
        return {"start": self.start, "end": self.end}


@dataclass(frozen=True, slots=True)
class AppiumConfig:
    executable: str = "appium"
    home: Path | None = None
    host: str = "127.0.0.1"
    port: int = 4723
    base_path: str = "/"
    version: str = "3.6.0"
    xcuitest_driver_version: str = "12.1.4"
    plugin_name: str = "faceswap-live"
    plugin_version: str = "1.0.0"
    remotexpc_version: str = "5.13.2"
    startup_timeout_seconds: int = 120
    request_timeout_seconds: int = 240
    shutdown_grace_seconds: int = 10

    @property
    def url(self) -> str:
        base = self.base_path.rstrip("/")
        return f"http://{self.host}:{self.port}{base}"


@dataclass(frozen=True, slots=True)
class WDAConfig:
    updated_bundle_id: str = ""
    xcode_org_id: str = ""
    xcode_signing_id: str = "Apple Development"
    xcode_config_file: Path | None = None
    derived_data_path: Path | None = None
    reuse: bool = True
    use_preinstalled: bool = False
    launch_timeout_ms: int = 120000
    connection_timeout_ms: int = 240000
    startup_retries: int = 2
    local_ports: PortRange = field(default_factory=lambda: PortRange(8100, 8199))
    mjpeg_ports: PortRange = field(default_factory=lambda: PortRange(9100, 9199))


@dataclass(frozen=True, slots=True)
class LiveConfig:
    bundle_id: str = "app.rork.face-swap-live-app-v17.qa"
    default_lease_seconds: int = 600
    maximum_lease_seconds: int = 3600
    watchdog_interval_seconds: int = 5
    event_history_limit: int = 5000
    maximum_observation_bytes: int = 8388608
    maximum_action_text_length: int = 16384
    sse_heartbeat_seconds: int = 15
    max_sse_clients: int = 16


@dataclass(frozen=True, slots=True)
class AgentConfig:
    api: ApiConfig
    paths: PathsConfig
    xcode: XcodeConfig
    limits: LimitsConfig
    config_path: Path
    appium: AppiumConfig = field(default_factory=AppiumConfig)
    wda: WDAConfig = field(default_factory=WDAConfig)
    live: LiveConfig = field(default_factory=LiveConfig)

    @property
    def config_dir(self) -> Path:
        return self.config_path.parent

    @classmethod
    def load(cls, config_path: str | Path) -> "AgentConfig":
        path = Path(config_path).expanduser().resolve()
        try:
            data = loads_bounded(path.read_bytes(), maximum_bytes=1024 * 1024)
        except JSONSafetyError as error:
            raise ValueError(f"configuration JSON was rejected: {error}") from error
        if not isinstance(data, dict):
            raise ValueError("configuration root must be an object")
        return cls.from_dict(data, config_path=path)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any], *, config_path: Path) -> "AgentConfig":
        unknown = set(data) - {"api", "paths", "xcode", "limits", "appium", "wda", "live"}
        if unknown:
            raise ValueError(f"unsupported configuration sections: {sorted(unknown)}")
        base = config_path.expanduser().resolve().parent
        api_data = _section(data, "api")
        path_data = _section(data, "paths")
        xcode_data = _section(data, "xcode")
        limits_data = _section(data, "limits")
        appium_data = _section(data, "appium")
        wda_data = _section(data, "wda")
        live_data = _section(data, "live")

        host = _loopback_host(api_data.get("host", "127.0.0.1"), "api.host")
        port = _bounded_int(api_data.get("port", 8765), "api.port", 1, 65535)

        ios_root = _resolve(path_data.get("ios_root", "../ios"), base)
        project = str(path_data.get("project", "FaceSwapLiveAppV17.xcodeproj")).strip()
        if not project.endswith(".xcodeproj") or Path(project).name != project:
            raise ValueError("paths.project must be a project basename ending in .xcodeproj")

        scheme = _safe_name(xcode_data.get("scheme", "FaceSwapLiveAppV17-QA"), "xcode.scheme")
        test_plan = _safe_name(
            xcode_data.get("test_plan", "FaceSwapLiveAppV17-QA"), "xcode.test_plan"
        )
        developer_dir = str(xcode_data.get("developer_dir", "")).strip()
        if developer_dir:
            developer_dir = str(Path(developer_dir).expanduser().resolve())
        default_simulator_name = _safe_name(
            xcode_data.get("default_simulator_name", "iPhone 16 Pro"),
            "xcode.default_simulator_name",
        )

        default_timeout = _bounded_int(
            limits_data.get("default_timeout_seconds", 1800),
            "limits.default_timeout_seconds",
            1,
            86400,
        )
        maximum_timeout = _bounded_int(
            limits_data.get("maximum_timeout_seconds", 7200),
            "limits.maximum_timeout_seconds",
            default_timeout,
            86400,
        )

        appium = AppiumConfig(
            executable=_safe_command(appium_data.get("executable", "appium"), "appium.executable"),
            home=_optional_resolve(appium_data.get("home"), base),
            host=_loopback_host(appium_data.get("host", "127.0.0.1"), "appium.host"),
            port=_bounded_int(appium_data.get("port", 4723), "appium.port", 1, 65535),
            base_path=_base_path(appium_data.get("base_path", "/")),
            version=_version(appium_data.get("version", "3.6.0"), "appium.version"),
            xcuitest_driver_version=_version(
                appium_data.get("xcuitest_driver_version", "12.1.4"),
                "appium.xcuitest_driver_version",
            ),
            plugin_name=_safe_name(
                appium_data.get("plugin_name", "faceswap-live"), "appium.plugin_name"
            ),
            plugin_version=_version(
                appium_data.get("plugin_version", "1.0.0"), "appium.plugin_version"
            ),
            remotexpc_version=_version(
                appium_data.get("remotexpc_version", "5.13.2"),
                "appium.remotexpc_version",
            ),
            startup_timeout_seconds=_bounded_int(
                appium_data.get("startup_timeout_seconds", 120),
                "appium.startup_timeout_seconds",
                5,
                900,
            ),
            request_timeout_seconds=_bounded_int(
                appium_data.get("request_timeout_seconds", 240),
                "appium.request_timeout_seconds",
                5,
                3600,
            ),
            shutdown_grace_seconds=_bounded_int(
                appium_data.get("shutdown_grace_seconds", 10),
                "appium.shutdown_grace_seconds",
                1,
                120,
            ),
        )

        wda = WDAConfig(
            updated_bundle_id=_optional_bundle_id(
                wda_data.get("updated_bundle_id", ""), "wda.updated_bundle_id"
            ),
            xcode_org_id=_optional_identifier(wda_data.get("xcode_org_id", ""), "wda.xcode_org_id"),
            xcode_signing_id=_safe_name(
                wda_data.get("xcode_signing_id", "Apple Development"),
                "wda.xcode_signing_id",
            ),
            xcode_config_file=_optional_resolve(wda_data.get("xcode_config_file"), base),
            derived_data_path=_optional_resolve(wda_data.get("derived_data_path"), base),
            reuse=_boolean(wda_data.get("reuse", True), "wda.reuse"),
            use_preinstalled=_boolean(
                wda_data.get("use_preinstalled", False), "wda.use_preinstalled"
            ),
            launch_timeout_ms=_bounded_int(
                wda_data.get("launch_timeout_ms", 120000),
                "wda.launch_timeout_ms",
                1000,
                1800000,
            ),
            connection_timeout_ms=_bounded_int(
                wda_data.get("connection_timeout_ms", 240000),
                "wda.connection_timeout_ms",
                1000,
                3600000,
            ),
            startup_retries=_bounded_int(
                wda_data.get("startup_retries", 2), "wda.startup_retries", 0, 10
            ),
            local_ports=_port_range(wda_data.get("local_ports"), 8100, 8199, "wda.local_ports"),
            mjpeg_ports=_port_range(
                wda_data.get("mjpeg_ports"), 9100, 9199, "wda.mjpeg_ports"
            ),
        )

        if wda.use_preinstalled and not wda.updated_bundle_id:
            raise ValueError(
                "wda.updated_bundle_id is required when wda.use_preinstalled is true"
            )

        default_lease = _bounded_int(
            live_data.get("default_lease_seconds", 600),
            "live.default_lease_seconds",
            30,
            86400,
        )
        maximum_lease = _bounded_int(
            live_data.get("maximum_lease_seconds", 3600),
            "live.maximum_lease_seconds",
            default_lease,
            86400,
        )
        live = LiveConfig(
            bundle_id=_bundle_id(
                live_data.get("bundle_id", "app.rork.face-swap-live-app-v17.qa"),
                "live.bundle_id",
            ),
            default_lease_seconds=default_lease,
            maximum_lease_seconds=maximum_lease,
            watchdog_interval_seconds=_bounded_int(
                live_data.get("watchdog_interval_seconds", 5),
                "live.watchdog_interval_seconds",
                1,
                60,
            ),
            event_history_limit=_bounded_int(
                live_data.get("event_history_limit", 5000),
                "live.event_history_limit",
                100,
                100000,
            ),
            maximum_observation_bytes=_bounded_int(
                live_data.get("maximum_observation_bytes", 8388608),
                "live.maximum_observation_bytes",
                65536,
                67108864,
            ),
            maximum_action_text_length=_bounded_int(
                live_data.get("maximum_action_text_length", 16384),
                "live.maximum_action_text_length",
                1,
                1048576,
            ),
            sse_heartbeat_seconds=_bounded_int(
                live_data.get("sse_heartbeat_seconds", 15),
                "live.sse_heartbeat_seconds",
                1,
                120,
            ),
            max_sse_clients=_bounded_int(
                live_data.get("max_sse_clients", 16),
                "live.max_sse_clients",
                1,
                256,
            ),
        )

        config = cls(
            api=ApiConfig(
                host=host,
                port=port,
                token_file=_resolve(api_data.get("token_file", "state/api-token"), base),
            ),
            paths=PathsConfig(
                ios_root=ios_root,
                project=project,
                database=_resolve(path_data.get("database", "state/jobs.sqlite3"), base),
                artifacts=_resolve(path_data.get("artifacts", "artifacts"), base),
                logs=_resolve(path_data.get("logs", "logs"), base),
            ),
            xcode=XcodeConfig(
                scheme=scheme,
                test_plan=test_plan,
                developer_dir=developer_dir,
                default_simulator_name=default_simulator_name,
            ),
            limits=LimitsConfig(
                max_request_bytes=_bounded_int(
                    limits_data.get("max_request_bytes", 262144),
                    "limits.max_request_bytes",
                    1024,
                    10485760,
                ),
                default_timeout_seconds=default_timeout,
                maximum_timeout_seconds=maximum_timeout,
                maximum_retries=_bounded_int(
                    limits_data.get("maximum_retries", 2),
                    "limits.maximum_retries",
                    0,
                    10,
                ),
                retention_hours=_bounded_int(
                    limits_data.get("retention_hours", 168),
                    "limits.retention_hours",
                    1,
                    8760,
                ),
                kill_grace_seconds=_bounded_int(
                    limits_data.get("kill_grace_seconds", 10),
                    "limits.kill_grace_seconds",
                    1,
                    120,
                ),
            ),
            appium=appium,
            wda=wda,
            live=live,
            config_path=config_path.expanduser().resolve(),
        )
        config._validate_path_relationships()
        return config

    def _validate_path_relationships(self) -> None:
        project_path = self.paths.project_path
        try:
            project_path.relative_to(self.paths.ios_root)
        except ValueError as error:
            raise ValueError("Xcode project escapes ios_root") from error
        if self.paths.database == self.paths.artifacts or self.paths.database == self.paths.logs:
            raise ValueError("database, artifact, and log paths must be distinct")
        if self.appium.port in self.wda.local_ports.values():
            raise ValueError("Appium port overlaps the WDA local port range")
        if self.appium.port in self.wda.mjpeg_ports.values():
            raise ValueError("Appium port overlaps the MJPEG port range")
        if set(self.wda.local_ports.values()).intersection(self.wda.mjpeg_ports.values()):
            raise ValueError("WDA and MJPEG port ranges overlap")

    def ensure_directories(self) -> None:
        self.api.token_file.parent.mkdir(parents=True, exist_ok=True)
        self.paths.database.parent.mkdir(parents=True, exist_ok=True)
        self.paths.artifacts.mkdir(parents=True, exist_ok=True)
        self.paths.logs.mkdir(parents=True, exist_ok=True)
        if self.wda.derived_data_path is not None:
            self.wda.derived_data_path.mkdir(parents=True, exist_ok=True)
        if self.appium.home is not None:
            self.appium.home.mkdir(parents=True, exist_ok=True)
            self.appium.home.chmod(0o700)

    def environment(self) -> dict[str, str]:
        environment: dict[str, str] = {}
        if self.xcode.developer_dir:
            environment["DEVELOPER_DIR"] = self.xcode.developer_dir
        if self.appium.home is not None:
            environment["APPIUM_HOME"] = str(self.appium.home)
        return environment

    def public_dict(self) -> dict[str, Any]:
        return {
            "api": {"host": self.api.host, "port": self.api.port},
            "paths": {
                "ios_root": str(self.paths.ios_root),
                "project": self.paths.project,
                "artifacts": str(self.paths.artifacts),
                "logs": str(self.paths.logs),
            },
            "xcode": {
                "scheme": self.xcode.scheme,
                "test_plan": self.xcode.test_plan,
                "default_simulator_name": self.xcode.default_simulator_name,
            },
            "appium": {
                "home": str(self.appium.home) if self.appium.home else None,
                "host": self.appium.host,
                "port": self.appium.port,
                "base_path": self.appium.base_path,
                "version": self.appium.version,
                "xcuitest_driver_version": self.appium.xcuitest_driver_version,
                "plugin_name": self.appium.plugin_name,
                "plugin_version": self.appium.plugin_version,
                "remotexpc_version": self.appium.remotexpc_version,
            },
            "wda": {
                "updated_bundle_id": self.wda.updated_bundle_id,
                "reuse": self.wda.reuse,
                "use_preinstalled": self.wda.use_preinstalled,
                "local_ports": self.wda.local_ports.to_dict(),
                "mjpeg_ports": self.wda.mjpeg_ports.to_dict(),
            },
            "live": {
                "bundle_id": self.live.bundle_id,
                "default_lease_seconds": self.live.default_lease_seconds,
                "maximum_lease_seconds": self.live.maximum_lease_seconds,
                "event_history_limit": self.live.event_history_limit,
            },
            "limits": {
                "default_timeout_seconds": self.limits.default_timeout_seconds,
                "maximum_timeout_seconds": self.limits.maximum_timeout_seconds,
                "maximum_retries": self.limits.maximum_retries,
                "retention_hours": self.limits.retention_hours,
            },
        }


def _section(data: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    value = data.get(name, {})
    if not isinstance(value, Mapping):
        raise ValueError(f"{name} must be an object")
    return value


def _resolve(value: Any, base: Path) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("configured paths must be non-empty strings")
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def _optional_resolve(value: Any, base: Path) -> Path | None:
    if value in (None, ""):
        return None
    return _resolve(value, base)


def _bounded_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    try:
        number = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{name} must be an integer") from error
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def _boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _safe_name(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise ValueError(f"{name} must be a non-empty string")
    value = value.strip()
    if any(character in value for character in ("/", "\\", "\0")):
        raise ValueError(f"{name} must not contain path separators")
    return value


def _safe_command(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 1024:
        raise ValueError(f"{name} must be a command name or absolute path")
    value = value.strip()
    if "\0" in value or any(character.isspace() for character in value):
        raise ValueError(f"{name} contains invalid characters")
    if "/" in value:
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise ValueError(f"{name} path must be absolute")
        return str(path.resolve())
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", value):
        raise ValueError(f"{name} contains invalid characters")
    return value


def _loopback_host(value: Any, name: str) -> str:
    host = str(value).strip()
    if host not in {"127.0.0.1", "::1", "localhost"}:
        raise ValueError(f"{name} must be a loopback address")
    return host


def _base_path(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("/") or ".." in value:
        raise ValueError("appium.base_path must be an absolute URL path")
    normalized = "/" + value.strip("/") if value != "/" else "/"
    if not re.fullmatch(r"/[A-Za-z0-9._~/-]*", normalized):
        raise ValueError("appium.base_path contains invalid characters")
    return normalized


def _version(value: Any, name: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", value):
        raise ValueError(f"{name} must be a semantic version")
    return value


def _bundle_id(value: Any, name: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9.-]{2,254}", value
    ):
        raise ValueError(f"{name} must be a valid bundle identifier")
    return value


def _optional_bundle_id(value: Any, name: str) -> str:
    return "" if value in (None, "") else _bundle_id(value, name)


def _optional_identifier(value: Any, name: str) -> str:
    if value in (None, ""):
        return ""
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", value):
        raise ValueError(f"{name} contains invalid characters")
    return value


def _port_range(value: Any, default_start: int, default_end: int, name: str) -> PortRange:
    if value is None:
        return PortRange(default_start, default_end)
    if not isinstance(value, Mapping):
        raise ValueError(f"{name} must be an object")
    unknown = set(value) - {"start", "end"}
    if unknown:
        raise ValueError(f"{name} has unsupported fields: {sorted(unknown)}")
    start = _bounded_int(value.get("start", default_start), f"{name}.start", 1, 65535)
    end = _bounded_int(value.get("end", default_end), f"{name}.end", start, 65535)
    return PortRange(start, end)
