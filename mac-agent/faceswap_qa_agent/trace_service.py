from __future__ import annotations

import hashlib
import uuid
from pathlib import Path
from typing import Any, Iterable, Mapping

from .analytics import AnalyticsError, build_analytics
from .config import AgentConfig
from .evidence import EvidenceBuilder, EvidenceError, EvidenceExport
from .live_models import LiveSession, LiveSessionStatus
from .live_store import LiveStore
from .models import Artifact, Job, JobStatus
from .recovery import RecoveryCause, RecoveryEpisode, RecoveryOutcome
from .store import JobStore
from .trace_context import normalize_uuid


class TraceServiceError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class TraceService:
    def __init__(
        self,
        config: AgentConfig,
        jobs: JobStore,
        live: LiveStore,
    ) -> None:
        self.config = config
        self.jobs = jobs
        self.live = live
        self.builder = EvidenceBuilder(config.paths.artifacts)

    def list_traces(
        self,
        *,
        owner_type: str | None = None,
        status: str | None = None,
        since: float | None = None,
        until: float | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        if owner_type not in {None, "job", "live_session"}:
            raise TraceServiceError("trace_filter_invalid", "invalid trace owner type")
        allowed_statuses = (
            {item.value for item in JobStatus}
            if owner_type == "job"
            else {item.value for item in LiveSessionStatus}
            if owner_type == "live_session"
            else {item.value for item in JobStatus} | {item.value for item in LiveSessionStatus}
        )
        if status is not None and status not in allowed_statuses:
            raise TraceServiceError("trace_filter_invalid", "invalid trace status")
        if since is not None and until is not None and since > until:
            raise TraceServiceError("trace_filter_invalid", "since must not exceed until")
        offset = max(0, min(int(offset), 10000))
        limit = max(1, min(int(limit), 500))
        summaries: list[dict[str, Any]] = []
        if owner_type in {None, "job"}:
            summaries.extend(
                self._trace_summary("job", job)
                for job in self.jobs.list_jobs(limit=500)
            )
        if owner_type in {None, "live_session"}:
            summaries.extend(
                self._trace_summary("live_session", session)
                for session in self.live.list_sessions(limit=500)
            )
        if status is not None:
            summaries = [item for item in summaries if item["status"] == status]
        if since is not None:
            summaries = [item for item in summaries if item["created_at"] >= since]
        if until is not None:
            summaries = [item for item in summaries if item["created_at"] <= until]
        summaries.sort(
            key=lambda item: (item["updated_at"], item["owner_id"]),
            reverse=True,
        )
        total = len(summaries)
        page = summaries[offset : offset + limit]
        return {
            "traces": page,
            "offset": offset,
            "limit": limit,
            "total": total,
            "next_offset": offset + len(page) if offset + len(page) < total else None,
        }

    def document(self, session_trace_id: str) -> dict[str, Any]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        job = self.jobs.get_job_by_trace(root)
        session = self.live.get_session_by_trace(root)
        if job is None and session is None:
            raise TraceServiceError("trace_not_found", "trace root was not found")
        if job is not None and session is not None:
            raise TraceServiceError(
                "trace_owner_conflict", "trace root has more than one owner"
            )
        owner_type, owner = ("job", job) if job is not None else ("live_session", session)
        assert owner is not None
        events = self.events(root, limit=5000)
        recoveries = [item.to_dict() for item in self.live.list_recoveries(session_trace_id=root, limit=1000)]
        artifacts = self._artifacts(owner_type, owner)
        manifest = self._manifest(
            root=root,
            owner_type=owner_type,
            owner=owner,
            events=events,
            recoveries=recoveries,
            artifacts=artifacts,
            analytics=None,
        )
        analytics = build_analytics(
            events=events,
            recovery_episodes=recoveries,
            evidence_manifest=manifest,
            expected_session_trace_id=root,
            active_device_owner_count=self._active_owner_count(),
            environmental_gates=self._environmental_gates(owner_type, owner),
        )
        return {
            "schema_version": 1,
            "session_trace_id": root,
            "owner_type": owner_type,
            "owner": owner.to_dict(),
            "events": events,
            "recovery_episodes": recoveries,
            "artifacts": [item.to_dict() for item in artifacts],
            "analytics": analytics,
            "evidence": {
                "status": manifest["status"],
                "reasons": manifest["reasons"],
                "bundle": self._existing_export(artifacts),
            },
        }

    def events(
        self,
        session_trace_id: str,
        *,
        after: int = 0,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        limit = max(1, min(int(limit), 5000))
        job = self.jobs.get_job_by_trace(root)
        if job is not None:
            source_events = self.jobs.get_events(job.id, offset=after, limit=limit)
            return [self._job_event_document(item, index) for index, item in enumerate(source_events)]
        session = self.live.get_session_by_trace(root)
        if session is None:
            raise TraceServiceError("trace_not_found", "trace root was not found")
        return [
            self._live_event_document(item.to_dict(), index)
            for index, item in enumerate(
                self.live.get_events_by_trace(root, after=after, limit=limit)
            )
        ]

    def analytics(self, session_trace_id: str) -> dict[str, Any]:
        return self.document(session_trace_id)["analytics"]

    def recoveries(self, session_trace_id: str) -> list[dict[str, Any]]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        if self.jobs.get_job_by_trace(root) is None and self.live.get_session_by_trace(root) is None:
            raise TraceServiceError("trace_not_found", "trace root was not found")
        return [
            episode.to_dict()
            for episode in self.live.list_recoveries(
                session_trace_id=root,
                limit=1000,
            )
        ]

    def list_recoveries(
        self,
        *,
        session_trace_id: str | None = None,
        owner_type: str | None = None,
        cause: str | None = None,
        outcome: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        if owner_type not in {None, "job", "live_session"}:
            raise TraceServiceError("recovery_filter_invalid", "invalid recovery owner type")
        if cause is not None and cause not in {item.value for item in RecoveryCause}:
            raise TraceServiceError("recovery_filter_invalid", "invalid recovery cause")
        if outcome is not None and outcome not in {item.value for item in RecoveryOutcome}:
            raise TraceServiceError("recovery_filter_invalid", "invalid recovery outcome")
        root = (
            normalize_uuid(session_trace_id, "session_trace_id")
            if session_trace_id is not None
            else None
        )
        offset = max(0, min(int(offset), 10000))
        limit = max(1, min(int(limit), 500))
        episodes = self.live.list_recoveries(
            session_trace_id=root,
            limit=1000,
        )
        documents = [item.to_dict() for item in episodes]
        if owner_type is not None:
            documents = [item for item in documents if item["owner_type"] == owner_type]
        if cause is not None:
            documents = [item for item in documents if item["cause"] == cause]
        if outcome is not None:
            documents = [item for item in documents if item["outcome"] == outcome]
        total = len(documents)
        page = documents[offset : offset + limit]
        return {
            "recovery_episodes": page,
            "offset": offset,
            "limit": limit,
            "total": total,
            "next_offset": offset + len(page) if offset + len(page) < total else None,
        }

    def recovery(self, recovery_id: str) -> dict[str, Any]:
        normalized = normalize_uuid(recovery_id, "recovery_id")
        episode = self.live.get_recovery(normalized)
        if episode is None:
            raise TraceServiceError("recovery_not_found", "recovery episode was not found")
        return episode.to_dict()

    def record_recovery(self, episode: RecoveryEpisode) -> RecoveryEpisode:
        try:
            return self.live.record_recovery(episode)
        except Exception as error:
            if isinstance(error, TraceServiceError):
                raise
            code = getattr(error, "code", "recovery_store_failed")
            raise TraceServiceError(code, str(error)) from error

    def export_evidence(self, session_trace_id: str) -> dict[str, Any]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        job = self.jobs.get_job_by_trace(root)
        session = self.live.get_session_by_trace(root)
        if job is None and session is None:
            raise TraceServiceError("trace_not_found", "trace root was not found")
        if job is not None and session is not None:
            raise TraceServiceError(
                "trace_owner_conflict", "trace root has more than one owner"
            )
        owner_type, owner = ("job", job) if job is not None else ("live_session", session)
        assert owner is not None
        events = self.events(root, limit=5000)
        recoveries = [item.to_dict() for item in self.live.list_recoveries(session_trace_id=root, limit=1000)]
        artifacts = [
            item
            for item in self._artifacts(owner_type, owner)
            if item.kind != "trace-evidence-bundle"
        ]
        preliminary = self._manifest(
            root=root,
            owner_type=owner_type,
            owner=owner,
            events=events,
            recoveries=recoveries,
            artifacts=artifacts,
            analytics=None,
        )
        analytics = build_analytics(
            events=events,
            recovery_episodes=recoveries,
            evidence_manifest=preliminary,
            expected_session_trace_id=root,
            active_device_owner_count=self._active_owner_count(),
            environmental_gates=self._environmental_gates(owner_type, owner),
        )
        manifest = self._manifest(
            root=root,
            owner_type=owner_type,
            owner=owner,
            events=events,
            recoveries=recoveries,
            artifacts=artifacts,
            analytics=analytics,
        )
        output = self.config.paths.artifacts / "traces" / root / "evidence.tar.gz"
        try:
            exported = self.builder.export_bundle(manifest, output)
        except (EvidenceError, AnalyticsError, OSError) as error:
            raise TraceServiceError(
                getattr(error, "code", "evidence_export_failed"), str(error)
            ) from error
        relative = str(output.resolve().relative_to(self.config.paths.artifacts.resolve()))
        record = Artifact(
            path=relative,
            kind="trace-evidence-bundle",
            byte_size=exported.byte_size,
            sha256=exported.sha256,
            session_trace_id=root,
            content_type="application/gzip",
            provenance="trace-service",
            redaction_state="manifest_redacted",
        )
        if owner_type == "job":
            current = [item for item in self.jobs.get_artifacts(owner.id) if item.kind != record.kind]
            self.jobs.replace_artifacts(owner.id, [*current, record])
        else:
            self.live.add_artifact(owner.id, record)
        return {
            "session_trace_id": root,
            "manifest": manifest,
            "export": exported.to_dict(),
            "relative_path": relative,
            "analytics": analytics,
        }

    def evidence_bundle(self, session_trace_id: str) -> tuple[Path, Artifact]:
        root = normalize_uuid(session_trace_id, "session_trace_id")
        job = self.jobs.get_job_by_trace(root)
        session = self.live.get_session_by_trace(root)
        if job is None and session is None:
            raise TraceServiceError("trace_not_found", "trace root was not found")
        if job is not None and session is not None:
            raise TraceServiceError(
                "trace_owner_conflict", "trace root has more than one owner"
            )
        owner_type, owner = ("job", job) if job is not None else ("live_session", session)
        assert owner is not None
        record = next(
            (
                item
                for item in self._artifacts(owner_type, owner)
                if item.kind == "trace-evidence-bundle"
            ),
            None,
        )
        if record is None:
            raise TraceServiceError(
                "evidence_not_found", "trace evidence bundle has not been exported"
            )
        root_path = self.config.paths.artifacts.resolve()
        unresolved = root_path / record.path
        if unresolved.is_symlink():
            raise TraceServiceError(
                "artifact_symlink_rejected", "evidence bundle path is a symlink"
            )
        candidate = unresolved.resolve()
        try:
            candidate.relative_to(root_path)
        except ValueError as error:
            raise TraceServiceError(
                "artifact_path_escape", "evidence bundle escaped the artifact root"
            ) from error
        if not candidate.is_file():
            raise TraceServiceError(
                "artifact_missing", "evidence bundle is missing or not a regular file"
            )
        if candidate.stat().st_size != record.byte_size:
            raise TraceServiceError(
                "artifact_size_mismatch", "evidence bundle size no longer matches metadata"
            )
        if sha256_file(candidate) != record.sha256:
            raise TraceServiceError(
                "artifact_hash_mismatch", "evidence bundle hash no longer matches metadata"
            )
        return candidate, record

    def _trace_summary(
        self, owner_type: str, owner: Job | LiveSession
    ) -> dict[str, Any]:
        artifacts = self._artifacts(owner_type, owner)
        root = (
            owner.request.session_trace_id
            if owner_type == "job"
            else owner.request.session_trace_id
        )
        updated_at = owner.updated_at if isinstance(owner, Job) else (owner.closed_at or owner.updated_at)
        return {
            "session_trace_id": root,
            "owner_type": owner_type,
            "owner_id": owner.id,
            "status": owner.status.value,
            "terminal": owner.status.terminal,
            "created_at": owner.created_at,
            "updated_at": updated_at,
            "run_id": owner.request.run_id,
            "target": owner.request.target.to_dict(),
            "evidence": self._existing_export(artifacts),
        }

    def _manifest(
        self,
        *,
        root: str,
        owner_type: str,
        owner: Job | LiveSession,
        events: Iterable[Mapping[str, Any]],
        recoveries: Iterable[Mapping[str, Any]],
        artifacts: Iterable[Artifact],
        analytics: Mapping[str, Any] | None,
    ) -> dict[str, Any]:
        terminal = owner.status.terminal
        status = "complete" if terminal else "partial"
        reasons = [] if terminal else ["owner_not_terminal"]
        if owner_type == "job":
            assert isinstance(owner, Job)
            run_id = owner.request.run_id
            created_at = owner.created_at
            closed_at = owner.updated_at if owner.status.terminal else None
            target = owner.request.target.to_dict()
        else:
            assert isinstance(owner, LiveSession)
            run_id = owner.request.run_id
            created_at = owner.created_at
            closed_at = owner.closed_at
            target = owner.request.target.to_dict()
        bundle_id = str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"faceswap-evidence:{root}:{owner_type}:{owner.id}",
            )
        )
        return self.builder.build_manifest(
            bundle_id=bundle_id,
            owner_type=owner_type,
            owner_id=owner.id,
            session_trace_id=root,
            run_id=run_id,
            artifacts=artifacts,
            events=events,
            recovery_episodes=recoveries,
            analytics=analytics,
            status=status,
            reasons=reasons,
            created_at=created_at,
            closed_at=closed_at,
            target=target,
            versions={
                "agent": "0.3.0",
                "appium": self.config.appium.version,
                "xcuitest": self.config.appium.xcuitest_driver_version,
                "plugin": self.config.appium.plugin_version,
                "remotexpc": self.config.appium.remotexpc_version,
            },
        )

    def _artifacts(
        self, owner_type: str, owner: Job | LiveSession
    ) -> list[Artifact]:
        if owner_type == "job":
            assert isinstance(owner, Job)
            return self.jobs.get_artifacts(owner.id)
        assert isinstance(owner, LiveSession)
        return self.live.get_artifacts(owner.id)

    @staticmethod
    def _existing_export(artifacts: Iterable[Artifact]) -> dict[str, Any] | None:
        for artifact in artifacts:
            if artifact.kind == "trace-evidence-bundle":
                return artifact.to_dict()
        return None

    def _active_owner_count(self) -> int:
        return int(self.jobs.active_job_id() is not None) + int(
            self.live.nonterminal_session() is not None
        )

    @staticmethod
    def _environmental_gates(
        owner_type: str, owner: Job | LiveSession
    ) -> list[str]:
        if owner.status.terminal:
            return []
        return [f"{owner_type}_not_terminal"]

    @staticmethod
    def _job_event_document(item: Mapping[str, Any], sequence: int) -> dict[str, Any]:
        return {
            "id": item["id"],
            "event_id": f"job:{item['id']}",
            "timestamp": item["timestamp"],
            "sequence": sequence,
            "source": "xcode" if item["type"] in {"completed", "failed", "retrying"} else "agent",
            "category": "job",
            "name": item["type"],
            "type": item["type"],
            "session_trace_id": item.get("session_trace_id"),
            "operation_trace_id": item.get("operation_trace_id"),
            "trace_id": item.get("operation_trace_id"),
            "span_id": item.get("span_id"),
            "payload": item.get("details", {}),
        }

    @staticmethod
    def _live_event_document(item: Mapping[str, Any], sequence: int) -> dict[str, Any]:
        document = dict(item)
        document["event_id"] = f"live:{item.get('id', sequence)}"
        document["sequence"] = sequence
        category = str(item.get("category", "agent"))
        document["source"] = category if category in {"appium", "wda", "bidi", "ios", "mjpeg"} else "agent"
        document["operation_trace_id"] = item.get("trace_id")
        return document


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
