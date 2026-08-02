from __future__ import annotations

import hashlib
import io
import json
import os
import stat
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

from faceswap_qa_agent.evidence import (
    EvidenceBuilder,
    EvidenceError,
    canonical_manifest_bytes,
    validate_manifest,
)


class EvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        (self.artifacts / "session").mkdir()
        self.file = self.artifacts / "session" / "event.json"
        self.file.write_text('{"ready":true}\n', encoding="utf-8")
        self.digest = hashlib.sha256(self.file.read_bytes()).hexdigest()
        self.trace_id = str(uuid.uuid4())
        self.run_id = str(uuid.uuid4())
        self.bundle_id = str(uuid.uuid4())
        self.builder = EvidenceBuilder(self.artifacts)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def manifest(self, *, sha256: str | None = None) -> dict:
        return self.builder.build_manifest(
            bundle_id=self.bundle_id,
            owner_type="live_session",
            owner_id="session-1",
            session_trace_id=self.trace_id,
            run_id=self.run_id,
            artifacts=[
                {
                    "path": "session/event.json",
                    "kind": "telemetry",
                    "sha256": sha256 if sha256 is not None else self.digest,
                    "created_at": 123.0,
                    "session_trace_id": self.trace_id,
                    "provenance": "ios_qa",
                    "redaction_state": "redacted",
                }
            ],
            events=[{"timestamp": 2, "id": 2}, {"timestamp": 1, "id": 1}],
            created_at=100.0,
            closed_at=200.0,
        )

    def test_manifest_is_canonical_sorted_and_valid(self) -> None:
        manifest = self.manifest()
        validate_manifest(manifest)
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual([event["id"] for event in manifest["events"]], [1, 2])
        artifact = manifest["artifacts"][0]
        self.assertEqual(artifact["sha256"], self.digest)
        self.assertEqual(artifact["status"], "verified")
        self.assertTrue(artifact["export"])
        first = canonical_manifest_bytes(manifest)
        second = canonical_manifest_bytes(json.loads(first))
        self.assertEqual(first, second)

    def test_export_is_byte_for_byte_deterministic(self) -> None:
        manifest = self.manifest()
        first = self.builder.export_bundle(manifest, self.root / "first.tar.gz")
        second = self.builder.export_bundle(manifest, self.root / "second.tar.gz")
        self.assertEqual(first.sha256, second.sha256)
        self.assertEqual((self.root / "first.tar.gz").read_bytes(), (self.root / "second.tar.gz").read_bytes())
        with tarfile.open(self.root / "first.tar.gz", "r:gz") as archive:
            self.assertEqual(
                archive.getnames(), ["manifest.json", "artifacts/session/event.json"]
            )
            stored = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(stored["bundle_id"], self.bundle_id)

    def test_symlink_absolute_parent_and_trace_mismatch_are_rejected(self) -> None:
        outside = self.root / "outside.txt"
        outside.write_text("outside", encoding="utf-8")
        link = self.artifacts / "session" / "link.txt"
        link.symlink_to(outside)
        for record in (
            {"path": "session/link.txt", "kind": "link"},
            {"path": "../outside.txt", "kind": "escape"},
            {"path": str(outside), "kind": "absolute"},
            {
                "path": "session/event.json",
                "kind": "wrong-trace",
                "session_trace_id": str(uuid.uuid4()),
            },
        ):
            with self.subTest(record=record):
                manifest = self.builder.build_manifest(
                    bundle_id=str(uuid.uuid4()),
                    owner_type="live_session",
                    owner_id="session-1",
                    session_trace_id=self.trace_id,
                    run_id=self.run_id,
                    artifacts=[record],
                    created_at=1,
                )
                self.assertEqual(manifest["status"], "partial")
                self.assertFalse(manifest["artifacts"][0]["export"])

    def test_hash_mismatch_marks_corrupt_and_excludes_bytes(self) -> None:
        manifest = self.manifest(sha256="0" * 64)
        self.assertEqual(manifest["status"], "corrupt")
        self.assertFalse(manifest["artifacts"][0]["export"])
        output = self.root / "corrupt.tar.gz"
        self.builder.export_bundle(manifest, output)
        with tarfile.open(output, "r:gz") as archive:
            self.assertEqual(archive.getnames(), ["manifest.json"])

    def test_mutation_after_manifest_fails_without_replacing_existing_output(self) -> None:
        manifest = self.manifest()
        output = self.root / "bundle.tar.gz"
        output.write_bytes(b"previous")
        self.file.write_text("mutated", encoding="utf-8")
        with self.assertRaises(EvidenceError) as context:
            self.builder.export_bundle(manifest, output)
        self.assertEqual(context.exception.code, "artifact_changed_during_export")
        self.assertEqual(output.read_bytes(), b"previous")

    def test_temporary_descriptor_must_be_private_owned_regular_file(self) -> None:
        invalid = mock.Mock(st_mode=stat.S_IFDIR | 0o600, st_uid=os.geteuid())
        with mock.patch("faceswap_qa_agent.evidence.os.fstat", return_value=invalid) as check:
            with self.assertRaises(EvidenceError) as context:
                self.builder.export_bundle(self.manifest(), self.root / "invalid.tar.gz")
        self.assertEqual(context.exception.code, "temporary_file_invalid")
        check.assert_called_once()
        self.assertFalse((self.root / "invalid.tar.gz").exists())
        self.assertEqual(list(self.root.glob(".invalid.tar.gz.*.tmp")), [])

    def test_output_symlink_is_rejected(self) -> None:
        destination = self.root / "real.tar.gz"
        destination.write_bytes(b"real")
        link = self.root / "linked.tar.gz"
        link.symlink_to(destination)
        with self.assertRaises(EvidenceError) as context:
            self.builder.export_bundle(self.manifest(), link)
        self.assertEqual(context.exception.code, "output_symlink_rejected")


if __name__ == "__main__":
    unittest.main()
