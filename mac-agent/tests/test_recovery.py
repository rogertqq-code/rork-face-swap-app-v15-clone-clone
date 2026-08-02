from __future__ import annotations

import json
import unittest
import uuid

from faceswap_qa_agent.recovery import (
    RecoveryCause,
    RecoveryEpisode,
    RecoveryError,
    RecoveryOutcome,
    summarize_recoveries,
)


class RecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.trace = str(uuid.uuid4())

    def test_start_and_finish_preserve_trace_and_redact_details(self) -> None:
        episode = RecoveryEpisode.start(
            owner_type="live_session",
            owner_id="session-1",
            session_trace_id=self.trace,
            cause=RecoveryCause.WDA_UNHEALTHY,
            started_at=10,
            details={"attempt": 1, "token": "plaintext-secret"},
        )
        self.assertEqual(episode.session_trace_id, self.trace)
        self.assertEqual(episode.outcome, RecoveryOutcome.OBSERVED)
        self.assertTrue(episode.details["token"]["redacted"])

        finished = episode.finish(
            outcome=RecoveryOutcome.RECOVERED,
            finished_at=12.5,
            details={"probe": "healthy"},
            evidence_paths=["session/appium-wda.log"],
        )
        self.assertEqual(finished.duration_ms, 2500)
        self.assertEqual(finished.evidence_paths, ("session/appium-wda.log",))
        self.assertEqual(finished.details["probe"], "healthy")
        with self.assertRaises(RecoveryError):
            finished.finish(outcome="failed", finished_at=13)

    def test_invalid_causes_outcomes_timestamps_and_paths_fail_closed(self) -> None:
        with self.assertRaises(RecoveryError):
            RecoveryEpisode.start(
                owner_type="unknown",
                owner_id="x",
                session_trace_id=self.trace,
                cause="wda_unhealthy",
                started_at=0,
            )
        with self.assertRaises(RecoveryError):
            RecoveryEpisode.start(
                owner_type="live_session",
                owner_id="x",
                session_trace_id=self.trace,
                cause="not-real",
                started_at=0,
            )
        episode = RecoveryEpisode.start(
            owner_type="live_session",
            owner_id="x",
            session_trace_id=self.trace,
            cause="appium_crashed",
            started_at=2,
        )
        with self.assertRaises(RecoveryError):
            episode.finish(outcome="observed", finished_at=3)
        with self.assertRaises(RecoveryError):
            episode.finish(outcome="failed", finished_at=1)
        with self.assertRaises(RecoveryError):
            episode.finish(
                outcome="failed",
                finished_at=3,
                evidence_paths=["../escape.log"],
            )

    def test_round_trip_and_summary(self) -> None:
        first = RecoveryEpisode.start(
            owner_type="job",
            owner_id="job-1",
            session_trace_id=self.trace,
            cause="agent_restarted",
            started_at=1,
        ).finish(outcome="failed", finished_at=2, error_code="agent_restarted")
        second = RecoveryEpisode.start(
            owner_type="live_session",
            owner_id="session-1",
            session_trace_id=self.trace,
            cause="mjpeg_disconnected",
            started_at=3,
        ).finish(outcome="degraded", finished_at=3.5)
        restored = RecoveryEpisode.from_dict(first.to_dict())
        self.assertEqual(restored, first)
        summary = summarize_recoveries([first, second])
        self.assertEqual(summary["count"], 2)
        self.assertEqual(summary["open"], 0)
        self.assertEqual(summary["outcomes"], {"degraded": 1, "failed": 1})
        self.assertEqual(summary["duration_ms"]["average"], 750)

    def test_details_are_bounded(self) -> None:
        with self.assertRaises(RecoveryError) as context:
            RecoveryEpisode.start(
                owner_type="live_session",
                owner_id="session-1",
                session_trace_id=self.trace,
                cause="evidence_corrupt",
                started_at=1,
                details={"payload": "x" * 70000},
            )
        self.assertEqual(context.exception.code, "details_too_large")


if __name__ == "__main__":
    unittest.main()
