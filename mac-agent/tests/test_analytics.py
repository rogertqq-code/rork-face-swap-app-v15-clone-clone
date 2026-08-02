from __future__ import annotations

import unittest
import uuid

from faceswap_qa_agent.analytics import AnalyticsError, build_analytics, nearest_rank


class AnalyticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.trace = str(uuid.uuid4())
        self.manifest = {
            "status": "complete",
            "session_trace_id": self.trace,
            "reasons": [],
            "artifacts": [
                {
                    "relative_path": "session/a.json",
                    "status": "verified",
                    "expected_sha256": "a" * 64,
                    "observed_sha256": "a" * 64,
                    "session_trace_id": self.trace,
                }
            ],
        }

    def test_nearest_rank(self) -> None:
        values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        self.assertEqual(nearest_rank(values, 0), 1)
        self.assertEqual(nearest_rank(values, 50), 5)
        self.assertEqual(nearest_rank(values, 90), 9)
        self.assertEqual(nearest_rank(values, 99), 10)
        self.assertIsNone(nearest_rank([], 50))
        with self.assertRaises(AnalyticsError):
            nearest_rank(values, 101)

    def test_deterministic_timeline_and_pass(self) -> None:
        operation = str(uuid.uuid4())
        events = [
            {
                "timestamp": 2,
                "source": "ios",
                "sequence": 2,
                "id": 2,
                "session_trace_id": self.trace,
                "operation_trace_id": operation,
                "name": "qa_command_result",
                "elapsed_ms": 20,
                "payload": {"success": True},
            },
            {
                "timestamp": 1,
                "source": "agent",
                "sequence": 1,
                "id": 1,
                "session_trace_id": self.trace,
                "operation_trace_id": operation,
                "name": "qa_command_started",
                "elapsed_ms": 10,
                "payload": {"trace_id": operation},
            },
        ]
        result = build_analytics(
            events=events,
            evidence_manifest=self.manifest,
            expected_session_trace_id=self.trace,
            active_device_owner_count=1,
        )
        self.assertEqual([item["id"] for item in result["timeline"]], [1, 2])
        self.assertEqual(result["latency_ms"]["p50"], 10)
        self.assertEqual(result["latency_ms"]["p90"], 20)
        self.assertEqual(result["qualification"]["status"], "pass")
        self.assertTrue(all(item["passed"] for item in result["invariants"].values()))

    def test_errors_recoveries_and_incomplete_environment(self) -> None:
        events = [
            {
                "timestamp": 1,
                "source": "wda",
                "sequence": 1,
                "session_trace_id": self.trace,
                "payload": {"error_code": "wda_unhealthy"},
            }
        ]
        recoveries = [
            {
                "recovery_id": str(uuid.uuid4()),
                "session_trace_id": self.trace,
                "cause": "wda_unhealthy",
                "outcome": "recovered",
                "started_at": 1,
                "finished_at": 2,
            }
        ]
        result = build_analytics(
            events=events,
            recovery_episodes=recoveries,
            evidence_manifest=self.manifest,
            expected_session_trace_id=self.trace,
            environmental_gates=["physical_mjpeg"],
        )
        self.assertEqual(result["errors"]["by_code"], {"wda_unhealthy": 1})
        self.assertEqual(result["recovery"]["causes"], {"wda_unhealthy": 1})
        self.assertEqual(result["recovery"]["latency_ms"]["p50"], 1000)
        self.assertEqual(result["qualification"]["status"], "incomplete")

    def test_hash_trace_recovery_owner_and_redaction_failures_fail(self) -> None:
        wrong_trace = str(uuid.uuid4())
        manifest = {
            **self.manifest,
            "status": "corrupt",
            "artifacts": [
                {
                    "relative_path": "a",
                    "status": "corrupt",
                    "expected_sha256": "a" * 64,
                    "observed_sha256": "b" * 64,
                    "session_trace_id": self.trace,
                }
            ],
        }
        events = [
            {
                "timestamp": 1,
                "source": "agent",
                "sequence": 2,
                "id": 1,
                "session_trace_id": self.trace,
                "name": "qa_command_result",
                "payload": {"password": "plaintext"},
            },
            {
                "timestamp": 2,
                "source": "agent",
                "sequence": 1,
                "id": 2,
                "session_trace_id": wrong_trace,
                "payload": {},
            },
        ]
        recoveries = [
            {
                "recovery_id": str(uuid.uuid4()),
                "session_trace_id": self.trace,
                "cause": "appium_crashed",
                "outcome": "observed",
                "started_at": 1,
                "finished_at": None,
            }
        ]
        result = build_analytics(
            events=events,
            recovery_episodes=recoveries,
            evidence_manifest=manifest,
            expected_session_trace_id=self.trace,
            active_device_owner_count=2,
        )
        self.assertEqual(result["qualification"]["status"], "fail")
        for name in (
            "root_trace_continuity",
            "monotonic_per_source_sequences",
            "no_artifact_hash_mismatch",
            "no_unclosed_recovery_episode",
            "no_plaintext_secret_marker_in_summaries",
            "one_active_device_owner",
            "command_result_correlation",
        ):
            self.assertFalse(result["invariants"][name]["passed"])

    def test_missing_timeline_and_evidence_is_incomplete(self) -> None:
        result = build_analytics(events=[], evidence_manifest={})
        self.assertEqual(result["qualification"]["status"], "fail")
        self.assertFalse(result["invariants"]["terminal_evidence_generation"]["passed"])

    def test_nonfinite_values_are_rejected(self) -> None:
        with self.assertRaises(AnalyticsError):
            build_analytics(events=[{"timestamp": float("nan")}])


if __name__ == "__main__":
    unittest.main()
