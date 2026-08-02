from __future__ import annotations

import gzip
import hashlib
import io
import json
import mimetypes
import os
import stat
import tarfile
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping

from .redaction import redact_structured
from .trace_context import normalize_uuid

EVIDENCE_SCHEMA_VERSION = 1
_ALLOWED_STATUS = frozenset({"complete", "partial", "corrupt"})
_ALLOWED_OWNER = frozenset({"job", "live_session"})


class EvidenceError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class EvidenceExport:
    path: str
    byte_size: int
    sha256: str
    manifest_sha256: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "byte_size": self.byte_size,
            "sha256": self.sha256,
            "manifest_sha256": self.manifest_sha256,
        }


class EvidenceBuilder:
    def __init__(self, artifacts_root: str | Path) -> None:
        self.artifacts_root = Path(artifacts_root).expanduser().resolve()
        self.artifacts_root.mkdir(parents=True, exist_ok=True)
        if self.artifacts_root.is_symlink() or not self.artifacts_root.is_dir():
            raise EvidenceError(
                "artifact_root_invalid", "artifact root must be a real directory"
            )

    def build_manifest(
        self,
        *,
        bundle_id: str,
        owner_type: str,
        owner_id: str,
        session_trace_id: str,
        run_id: str,
        artifacts: Iterable[Mapping[str, Any] | Any],
        events: Iterable[Mapping[str, Any]] = (),
        recovery_episodes: Iterable[Mapping[str, Any]] = (),
        analytics: Mapping[str, Any] | None = None,
        status: str = "complete",
        reasons: Iterable[str] = (),
        created_at: float,
        closed_at: float | None = None,
        target: Mapping[str, Any] | None = None,
        versions: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        bundle_id = normalize_uuid(bundle_id, "bundle_id")
        session_trace_id = normalize_uuid(
            session_trace_id, "session_trace_id"
        )
        run_id = normalize_uuid(run_id, "run_id")
        if owner_type not in _ALLOWED_OWNER:
            raise EvidenceError("owner_invalid", "unsupported evidence owner type")
        if not isinstance(owner_id, str) or not owner_id or len(owner_id) > 256:
            raise EvidenceError("owner_invalid", "owner ID is invalid")
        if status not in _ALLOWED_STATUS:
            raise EvidenceError("status_invalid", "unsupported evidence status")

        normalized_artifacts: list[dict[str, Any]] = []
        normalized_reasons = sorted(
            {str(reason)[:1024] for reason in reasons if str(reason).strip()}
        )
        effective_status = status
        for source in artifacts:
            record = self._artifact_mapping(source)
            try:
                normalized = self._normalize_artifact(
                    record,
                    session_trace_id=session_trace_id,
                )
            except EvidenceError as error:
                normalized = {
                    "relative_path": str(record.get("path", ""))[:4096],
                    "kind": str(record.get("kind", "unknown"))[:128],
                    "export": False,
                    "status": "unavailable",
                    "error_code": error.code,
                    "error_message": str(error)[:1024],
                }
                if effective_status != "corrupt":
                    effective_status = "partial"
                normalized_reasons.append(error.code)
            else:
                if normalized["status"] == "corrupt":
                    effective_status = "corrupt"
                    normalized_reasons.append("artifact_hash_mismatch")
            normalized_artifacts.append(normalized)

        manifest = {
            "schema_version": EVIDENCE_SCHEMA_VERSION,
            "bundle_id": bundle_id,
            "owner": {"type": owner_type, "id": owner_id},
            "run_id": run_id,
            "session_trace_id": session_trace_id,
            "created_at": float(created_at),
            "closed_at": float(closed_at) if closed_at is not None else None,
            "status": effective_status,
            "reasons": sorted(set(normalized_reasons)),
            "target": redact_structured(dict(target or {})),
            "versions": redact_structured(dict(versions or {})),
            "events": sorted(
                (redact_structured(dict(item)) for item in events),
                key=_event_sort_key,
            ),
            "recovery_episodes": sorted(
                (redact_structured(dict(item)) for item in recovery_episodes),
                key=lambda item: (
                    float(item.get("started_at", 0.0)),
                    str(item.get("recovery_id", "")),
                ),
            ),
            "artifacts": sorted(
                normalized_artifacts,
                key=lambda item: str(item.get("relative_path", "")),
            ),
            "analytics": redact_structured(dict(analytics or {})),
        }
        validate_manifest(manifest)
        return manifest

    def export_bundle(
        self, manifest: Mapping[str, Any], output_path: str | Path
    ) -> EvidenceExport:
        validate_manifest(manifest)
        output = Path(output_path).expanduser()
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists() and output.is_symlink():
            raise EvidenceError(
                "output_symlink_rejected", "evidence output cannot be a symlink"
            )
        parent = output.parent.resolve()
        if parent.is_symlink() or not parent.is_dir():
            raise EvidenceError(
                "output_parent_invalid", "evidence output parent is invalid"
            )

        manifest_bytes = canonical_manifest_bytes(manifest)
        descriptor, raw_temp = tempfile.mkstemp(
            prefix=f".{output.name}.", suffix=".tmp", dir=parent
        )
        temp = Path(raw_temp)
        try:
            os.fchmod(descriptor, 0o600)
            descriptor_stat = os.fstat(descriptor)
            expected_uid = os.geteuid()
            if not stat.S_ISREG(descriptor_stat.st_mode):
                raise EvidenceError(
                    "temporary_file_invalid",
                    "evidence temporary descriptor is not a regular file",
                )
            if descriptor_stat.st_uid != expected_uid:
                raise EvidenceError(
                    "temporary_file_invalid",
                    "evidence temporary descriptor has the wrong owner",
                )
            if stat.S_IMODE(descriptor_stat.st_mode) & 0o077:
                raise EvidenceError(
                    "temporary_file_invalid",
                    "evidence temporary descriptor permissions are not private",
                )
        except BaseException:
            os.close(descriptor)
            temp.unlink(missing_ok=True)
            raise
        try:
            with os.fdopen(descriptor, "wb") as raw:
                with gzip.GzipFile(
                    filename="", mode="wb", fileobj=raw, mtime=0
                ) as compressed:
                    with tarfile.open(
                        fileobj=compressed,
                        mode="w",
                        format=tarfile.GNU_FORMAT,
                    ) as archive:
                        self._add_bytes(
                            archive, "manifest.json", manifest_bytes
                        )
                        for artifact in manifest["artifacts"]:
                            if not artifact.get("export", False):
                                continue
                            source = self._validated_path(
                                str(artifact["relative_path"])
                            )
                            observed = _hash_file(source)
                            if observed != artifact["sha256"]:
                                raise EvidenceError(
                                    "artifact_changed_during_export",
                                    f"artifact changed during export: {artifact['relative_path']}",
                                )
                            self._add_file(
                                archive,
                                source,
                                f"artifacts/{artifact['relative_path']}",
                            )
                raw.flush()
                os.fsync(raw.fileno())
            os.chmod(temp, 0o600)
            os.replace(temp, output)
            _fsync_directory(parent)
        except BaseException:
            temp.unlink(missing_ok=True)
            raise

        return EvidenceExport(
            path=str(output),
            byte_size=output.stat().st_size,
            sha256=_hash_file(output),
            manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        )

    def _artifact_mapping(self, source: Mapping[str, Any] | Any) -> dict[str, Any]:
        if isinstance(source, Mapping):
            return dict(source)
        to_dict = getattr(source, "to_dict", None)
        if callable(to_dict):
            value = to_dict()
            if isinstance(value, Mapping):
                return dict(value)
        attributes = {
            name: getattr(source, name)
            for name in (
                "path",
                "kind",
                "byte_size",
                "sha256",
                "created_at",
                "content_type",
                "provenance",
                "session_trace_id",
                "operation_trace_id",
                "span_id",
                "redaction_state",
            )
            if hasattr(source, name)
        }
        if not attributes:
            raise EvidenceError(
                "artifact_invalid", "artifact record must be a mapping or model"
            )
        return attributes

    def _normalize_artifact(
        self, record: Mapping[str, Any], *, session_trace_id: str
    ) -> dict[str, Any]:
        relative_path = _relative_path(record.get("relative_path", record.get("path")))
        source = self._validated_path(relative_path)
        observed_sha256 = _hash_file(source)
        expected_sha256 = str(record.get("sha256", "")).lower()
        if expected_sha256 and not _sha256(expected_sha256):
            raise EvidenceError(
                "artifact_hash_invalid", f"invalid artifact hash: {relative_path}"
            )
        corrupt = bool(expected_sha256 and expected_sha256 != observed_sha256)
        operation_trace_id = record.get(
            "operation_trace_id", record.get("trace_id")
        )
        if operation_trace_id not in (None, ""):
            operation_trace_id = normalize_uuid(
                operation_trace_id, "operation_trace_id"
            )
        root = record.get("session_trace_id", session_trace_id)
        root = normalize_uuid(root, "session_trace_id")
        if root != session_trace_id:
            raise EvidenceError(
                "artifact_trace_mismatch", "artifact belongs to another trace root"
            )
        return {
            "relative_path": relative_path,
            "kind": str(record.get("kind", "unknown"))[:128],
            "content_type": str(
                record.get("content_type")
                or mimetypes.guess_type(relative_path)[0]
                or "application/octet-stream"
            )[:256],
            "byte_size": source.stat().st_size,
            "sha256": observed_sha256,
            "expected_sha256": expected_sha256 or observed_sha256,
            "created_at": float(record.get("created_at", 0.0)),
            "provenance": str(record.get("provenance", "agent"))[:128],
            "redaction_state": str(
                record.get("redaction_state", "not_applicable")
            )[:64],
            "session_trace_id": root,
            "operation_trace_id": operation_trace_id,
            "span_id": record.get("span_id"),
            "status": "corrupt" if corrupt else "verified",
            "export": not corrupt,
            "observed_sha256": observed_sha256,
        }

    def _validated_path(self, relative_path: str) -> Path:
        normalized = _relative_path(relative_path)
        current = self.artifacts_root
        for component in PurePosixPath(normalized).parts:
            current = current / component
            try:
                metadata = current.lstat()
            except FileNotFoundError as error:
                raise EvidenceError(
                    "artifact_missing", f"artifact is missing: {normalized}"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise EvidenceError(
                    "artifact_symlink_rejected",
                    f"artifact path contains a symlink: {normalized}",
                )
        resolved = current.resolve(strict=True)
        try:
            resolved.relative_to(self.artifacts_root)
        except ValueError as error:
            raise EvidenceError(
                "artifact_path_escape", f"artifact escapes root: {normalized}"
            ) from error
        if not resolved.is_file():
            raise EvidenceError(
                "artifact_not_regular", f"artifact is not a regular file: {normalized}"
            )
        return resolved

    @staticmethod
    def _add_bytes(
        archive: tarfile.TarFile, name: str, content: bytes
    ) -> None:
        information = _tar_info(name, len(content))
        archive.addfile(information, io.BytesIO(content))

    @staticmethod
    def _add_file(
        archive: tarfile.TarFile, source: Path, name: str
    ) -> None:
        information = _tar_info(name, source.stat().st_size)
        with source.open("rb") as handle:
            archive.addfile(information, handle)


def validate_manifest(manifest: Mapping[str, Any]) -> None:
    if not isinstance(manifest, Mapping):
        raise EvidenceError("manifest_invalid", "evidence manifest must be an object")
    required = {
        "schema_version",
        "bundle_id",
        "owner",
        "run_id",
        "session_trace_id",
        "created_at",
        "status",
        "reasons",
        "events",
        "recovery_episodes",
        "artifacts",
        "analytics",
    }
    missing = required - set(manifest)
    if missing:
        raise EvidenceError(
            "manifest_invalid", f"evidence manifest is missing: {sorted(missing)}"
        )
    if manifest["schema_version"] != EVIDENCE_SCHEMA_VERSION:
        raise EvidenceError(
            "manifest_version_unsupported", "unsupported evidence manifest version"
        )
    normalize_uuid(manifest["bundle_id"], "bundle_id")
    normalize_uuid(manifest["run_id"], "run_id")
    normalize_uuid(manifest["session_trace_id"], "session_trace_id")
    owner = manifest["owner"]
    if not isinstance(owner, Mapping) or owner.get("type") not in _ALLOWED_OWNER:
        raise EvidenceError("manifest_invalid", "invalid evidence owner")
    if manifest["status"] not in _ALLOWED_STATUS:
        raise EvidenceError("manifest_invalid", "invalid evidence status")
    for name in ("reasons", "events", "recovery_episodes", "artifacts"):
        if not isinstance(manifest[name], list):
            raise EvidenceError("manifest_invalid", f"{name} must be an array")


def canonical_manifest_bytes(manifest: Mapping[str, Any]) -> bytes:
    validate_manifest(manifest)
    return (
        json.dumps(
            manifest,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def _relative_path(value: Any) -> str:
    if not isinstance(value, str) or not value or "\0" in value:
        raise EvidenceError("artifact_path_invalid", "artifact path is invalid")
    path = PurePosixPath(value.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise EvidenceError(
            "artifact_path_invalid", "artifact path must be confined and relative"
        )
    normalized = path.as_posix()
    if len(normalized) > 4096:
        raise EvidenceError("artifact_path_invalid", "artifact path is too long")
    return normalized


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def _event_sort_key(item: Mapping[str, Any]) -> tuple[Any, ...]:
    return (
        float(item.get("timestamp", 0.0)),
        int(item.get("source_priority", 99)),
        int(item.get("sequence", 0)),
        int(item.get("id", item.get("event_id", 0)) or 0),
    )


def _tar_info(name: str, size: int) -> tarfile.TarInfo:
    information = tarfile.TarInfo(name=name)
    information.size = size
    information.mtime = 0
    information.uid = 0
    information.gid = 0
    information.uname = "root"
    information.gname = "root"
    information.mode = 0o644
    return information


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
