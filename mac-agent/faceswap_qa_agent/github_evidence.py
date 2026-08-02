from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

from .json_safety import JSONSafetyError, loads_bounded

SCHEMA_VERSION = 1
MAXIMUM_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024
MAXIMUM_FILE_COUNT = 10_000
MAXIMUM_TEXT_SCAN_BYTES = 4 * 1024 * 1024
PRIVATE_FILE_MODE = 0o600
PRIVATE_DIRECTORY_MODE = 0o700
FORBIDDEN_SUFFIXES = frozenset({".db", ".sqlite", ".sqlite3", ".key", ".p12", ".mobileprovision"})
FORBIDDEN_EXACT = frozenset({"config.json", "api-token", "lease-token", ".env", ".netrc"})
FORBIDDEN_NAME_MARKERS = ("password", "secret", "credential", "private-key", "private_key")
TEXT_SUFFIXES = frozenset({".json", ".txt", ".log", ".md", ".xml", ".csv"})
SECRET_PATTERNS = (
    re.compile(rb"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(rb"(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|credential)\s*[:=]\s*[^\s,;\]}]{4,}"),
    re.compile(rb"(?im)^(?:Cookie|Set-Cookie|Proxy-Authorization)\s*:\s*[^\r\n]+$"),
)

REQUIRED_COMMON = frozenset({
    "inputs.json",
    "context.json",
    "preflight.json",
    "run-state.json",
    "summary.json",
    "cleanup.json",
})
REQUIRED_EXECUTE = frozenset({
    "request.json",
    "job.json",
    "artifacts.json",
    "job.log",
    "trace.json",
    "analytics.json",
    "recoveries.json",
    "evidence.json",
    "trace-evidence.tar.gz",
    "bundle.json",
})
GENERATED = frozenset({"upload-manifest.json", "github-summary.md"})


class EvidenceAuditError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class EvidenceFile:
    path: str
    byte_size: int
    sha256: str

    def to_dict(self) -> dict[str, Any]:
        return {"path": self.path, "byte_size": self.byte_size, "sha256": self.sha256}


@dataclass(frozen=True, slots=True)
class AuditResult:
    run_directory: Path
    operation: str
    files: tuple[EvidenceFile, ...]
    total_bytes: int
    manifest_path: Path
    summary_path: Path

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "ready",
            "operation": self.operation,
            "run_directory": str(self.run_directory),
            "file_count": len(self.files),
            "total_bytes": self.total_bytes,
            "files": [item.to_dict() for item in self.files],
            "manifest_path": str(self.manifest_path),
            "summary_path": str(self.summary_path),
        }


class EvidenceAuditor:
    def __init__(
        self,
        run_directory: Path,
        *,
        maximum_bytes: int = MAXIMUM_UPLOAD_BYTES,
        maximum_files: int = MAXIMUM_FILE_COUNT,
    ) -> None:
        self.run_directory = _owned_directory(run_directory)
        if maximum_bytes < 1 or maximum_bytes > MAXIMUM_UPLOAD_BYTES:
            raise ValueError("maximum_bytes is outside the supported range")
        if maximum_files < 1 or maximum_files > MAXIMUM_FILE_COUNT:
            raise ValueError("maximum_files is outside the supported range")
        self.maximum_bytes = maximum_bytes
        self.maximum_files = maximum_files

    def audit(self, operation: str) -> AuditResult:
        if operation not in {"preflight", "execute"}:
            raise EvidenceAuditError("invalid_operation", "operation must be preflight or execute")
        for generated in GENERATED:
            candidate = self.run_directory / generated
            if candidate.is_symlink():
                raise EvidenceAuditError("generated_symlink", f"generated output is a symlink: {generated}")
            candidate.unlink(missing_ok=True)
        paths = self._inventory()
        relative_names = {item.relative_to(self.run_directory).as_posix() for item in paths}
        summary_document = self._load_summary()
        required = set(REQUIRED_COMMON)
        if operation == "execute" and summary_document.get("status") != "failed":
            required.update(REQUIRED_EXECUTE)
        elif operation == "execute":
            required.add("bridge-error.json")
        missing = sorted(required - relative_names)
        if missing:
            raise EvidenceAuditError("required_evidence_missing", f"required evidence is missing: {missing}")

        files: list[EvidenceFile] = []
        total = 0
        for path in paths:
            relative = path.relative_to(self.run_directory).as_posix()
            self._validate_name(relative)
            file_record = self._hash_file(path, relative)
            total += file_record.byte_size
            if total > self.maximum_bytes:
                raise EvidenceAuditError("evidence_too_large", "evidence exceeds the configured upload bound")
            files.append(file_record)
        manifest_path = self.run_directory / "upload-manifest.json"
        summary_path = self.run_directory / "github-summary.md"
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "status": "ready",
            "operation": operation,
            "file_count": len(files),
            "total_bytes": total,
            "files": [item.to_dict() for item in files],
        }
        _write_private(manifest_path, json.dumps(manifest, sort_keys=True, indent=2).encode("utf-8") + b"\n")
        _write_private(summary_path, self._markdown(summary_document, manifest).encode("utf-8"))
        return AuditResult(
            run_directory=self.run_directory,
            operation=operation,
            files=tuple(files),
            total_bytes=total,
            manifest_path=manifest_path,
            summary_path=summary_path,
        )

    def _inventory(self) -> list[Path]:
        result: list[Path] = []
        stack = [self.run_directory]
        while stack:
            directory = stack.pop()
            with os.scandir(directory) as entries:
                children = sorted(entries, key=lambda item: item.name, reverse=True)
            for entry in children:
                path = Path(entry.path)
                if entry.is_symlink():
                    raise EvidenceAuditError("evidence_symlink", f"evidence contains a symlink: {path.name}")
                if entry.is_dir(follow_symlinks=False):
                    stack.append(path)
                elif entry.is_file(follow_symlinks=False):
                    relative = path.relative_to(self.run_directory).as_posix()
                    if relative not in GENERATED:
                        result.append(path)
                else:
                    raise EvidenceAuditError("evidence_special_file", f"evidence contains a special file: {path.name}")
                if len(result) > self.maximum_files:
                    raise EvidenceAuditError("evidence_file_limit", "evidence contains too many files")
        return sorted(result, key=lambda item: item.relative_to(self.run_directory).as_posix())

    def _validate_name(self, relative: str) -> None:
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise EvidenceAuditError("evidence_path_escape", f"unsafe evidence path: {relative}")
        lowered = path.name.lower()
        if lowered.startswith(".") or lowered in FORBIDDEN_EXACT:
            raise EvidenceAuditError("forbidden_evidence_file", f"forbidden evidence file: {relative}")
        if path.suffix.lower() in FORBIDDEN_SUFFIXES:
            raise EvidenceAuditError("forbidden_evidence_file", f"forbidden evidence suffix: {relative}")
        if any(marker in lowered for marker in FORBIDDEN_NAME_MARKERS):
            raise EvidenceAuditError("forbidden_evidence_file", f"sensitive evidence filename: {relative}")
        if "token" in lowered and lowered not in {"context.json"}:
            raise EvidenceAuditError("forbidden_evidence_file", f"token-like evidence filename: {relative}")
        if "lease" in lowered:
            raise EvidenceAuditError("forbidden_evidence_file", f"lease-like evidence filename: {relative}")

    def _hash_file(self, path: Path, relative: str) -> EvidenceFile:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            details = os.fstat(descriptor)
            if not stat.S_ISREG(details.st_mode):
                raise EvidenceAuditError("evidence_not_regular", f"evidence is not regular: {relative}")
            if details.st_uid != os.geteuid():
                raise EvidenceAuditError("evidence_wrong_owner", f"evidence has the wrong owner: {relative}")
            if stat.S_IMODE(details.st_mode) & 0o077:
                raise EvidenceAuditError("evidence_not_private", f"evidence is not private: {relative}")
            digest = hashlib.sha256()
            observed = 0
            scan = bytearray()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                observed += len(chunk)
                if observed > self.maximum_bytes:
                    raise EvidenceAuditError("evidence_file_too_large", f"evidence file exceeds bound: {relative}")
                digest.update(chunk)
                if Path(relative).suffix.lower() in TEXT_SUFFIXES and len(scan) < MAXIMUM_TEXT_SCAN_BYTES:
                    scan.extend(chunk[: MAXIMUM_TEXT_SCAN_BYTES - len(scan)])
            if observed != details.st_size:
                raise EvidenceAuditError("evidence_changed", f"evidence changed while reading: {relative}")
            for pattern in SECRET_PATTERNS:
                if pattern.search(bytes(scan)):
                    raise EvidenceAuditError("plaintext_secret_detected", f"plaintext secret marker found: {relative}")
            return EvidenceFile(relative, observed, digest.hexdigest())
        finally:
            os.close(descriptor)

    def _load_summary(self) -> dict[str, Any]:
        path = self.run_directory / "summary.json"
        try:
            value = loads_bounded(path.read_bytes(), maximum_bytes=1024 * 1024)
        except (OSError, JSONSafetyError) as error:
            raise EvidenceAuditError("summary_invalid", f"summary JSON is invalid: {error}") from error
        if not isinstance(value, dict):
            raise EvidenceAuditError("summary_invalid", "summary JSON must be an object")
        return value

    @staticmethod
    def _markdown(summary: dict[str, Any], manifest: dict[str, Any]) -> str:
        status = _markdown_value(summary.get("status"))
        scenario = _markdown_value(summary.get("scenario"))
        device = _markdown_value(summary.get("device_udid"))
        trace = _markdown_value(summary.get("session_trace_id"))
        job = _markdown_value(summary.get("job_id"))
        qualification = summary.get("qualification")
        if isinstance(qualification, dict):
            qualification_value = _markdown_value(qualification.get("status"))
        else:
            qualification_value = _markdown_value(qualification)
        return (
            "# Physical iPhone QA\n\n"
            "| Field | Value |\n|---|---|\n"
            f"| Status | `{status}` |\n"
            f"| Scenario | `{scenario}` |\n"
            f"| Device | `{device}` |\n"
            f"| Job | `{job}` |\n"
            f"| Root trace | `{trace}` |\n"
            f"| Qualification | `{qualification_value}` |\n"
            f"| Evidence files | `{manifest['file_count']}` |\n"
            f"| Evidence bytes | `{manifest['total_bytes']}` |\n"
        )


def _owned_directory(path: Path) -> Path:
    if path.is_symlink():
        raise EvidenceAuditError("run_directory_symlink", "run directory must not be a symlink")
    resolved = path.expanduser().resolve(strict=True)
    details = resolved.stat()
    if not stat.S_ISDIR(details.st_mode):
        raise EvidenceAuditError("run_directory_invalid", "run directory must be a directory")
    if details.st_uid != os.geteuid():
        raise EvidenceAuditError("run_directory_owner", "run directory has the wrong owner")
    resolved.chmod(PRIVATE_DIRECTORY_MODE)
    if stat.S_IMODE(resolved.stat().st_mode) & 0o077:
        raise EvidenceAuditError("run_directory_mode", "run directory is not private")
    return resolved


def _write_private(path: Path, data: bytes) -> None:
    if path.is_symlink():
        raise EvidenceAuditError("output_symlink", f"output is a symlink: {path.name}")
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        try:
            os.fchmod(descriptor, PRIVATE_FILE_MODE)
            details = os.fstat(descriptor)
            if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid():
                raise EvidenceAuditError("output_descriptor_invalid", "output descriptor is unsafe")
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


def _markdown_value(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("`", "'").replace("|", "/").replace("\r", " ").replace("\n", " ")[:256]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Audit physical-device GitHub evidence")
    subparsers = parser.add_subparsers(dest="command", required=True)
    audit = subparsers.add_parser("audit")
    audit.add_argument("--run-dir", required=True)
    audit.add_argument("--operation", choices=("preflight", "execute"), required=True)
    audit.add_argument("--maximum-bytes", type=int, default=MAXIMUM_UPLOAD_BYTES)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = EvidenceAuditor(
            Path(args.run_dir), maximum_bytes=args.maximum_bytes
        ).audit(args.operation)
        print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
        return 0
    except EvidenceAuditError as error:
        print(json.dumps({"error": {"code": error.code, "message": str(error)}}, sort_keys=True), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
