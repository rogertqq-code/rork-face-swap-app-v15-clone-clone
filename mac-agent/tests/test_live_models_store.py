from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path

from faceswap_qa_agent.config import PortRange
from faceswap_qa_agent.live_models import (
    ActionKind,
    LiveActionRequest,
    LiveSessionRequest,
    LiveSessionStatus,
    ObservationKind,
    ObservationRequest,
    is_valid_live_transition,
)
from faceswap_qa_agent.live_store import LiveStore, LiveStoreError
from faceswap_qa_agent.models import JobRequest, Target, TargetKind, utc_timestamp
from faceswap_qa_agent.store import JobStore


class LiveModelsStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "jobs.sqlite3"
        self.jobs = JobStore(self.database)
        self.live = LiveStore(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def request() -> LiveSessionRequest:
        return LiveSessionRequest(
            target=Target(kind=TargetKind.SIMULATOR, udid="SIM-1234"),
            lease_seconds=60,
        )

    def create(self, key: str | None = None):
        return self.live.create_session(
            self.request(),
            idempotency_key=key,
            wda_ports=PortRange(8100, 8102),
            mjpeg_ports=PortRange(9100, 9102),
        )

    def test_live_transition_contract(self) -> None:
        self.assertTrue(
            is_valid_live_transition(LiveSessionStatus.PENDING, LiveSessionStatus.STARTING)
        )
        self.assertTrue(
            is_valid_live_transition(LiveSessionStatus.ACTIVE, LiveSessionStatus.EXPIRED)
        )
        self.assertFalse(
            is_valid_live_transition(LiveSessionStatus.CLOSED, LiveSessionStatus.ACTIVE)
        )

    def test_action_and_observation_contracts_are_closed(self) -> None:
        tap = LiveActionRequest.from_dict(
            {"kind": "tap", "parameters": {"x": 10, "y": 20}},
            maximum_text_length=128,
        )
        self.assertEqual(tap.kind, ActionKind.TAP)
        self.assertEqual(tap.parameters["x"], 10.0)
        with self.assertRaisesRegex(ValueError, "either element_id or coordinates"):
            LiveActionRequest.from_dict(
                {
                    "kind": "tap",
                    "parameters": {"element_id": "e", "x": 1, "y": 2},
                },
                maximum_text_length=128,
            )
        with self.assertRaisesRegex(ValueError, "unsupported action kind"):
            LiveActionRequest.from_dict(
                {"kind": "shell", "parameters": {}}, maximum_text_length=128
            )
        with self.assertRaisesRegex(ValueError, "too large"):
            LiveActionRequest.from_dict(
                {"kind": "qa_command", "parameters": {"command": {"x": "y" * 200}}},
                maximum_text_length=32,
            )
        observation = ObservationRequest.from_dict({"kind": "combined"})
        self.assertEqual(observation.kind, ObservationKind.COMBINED)
        with self.assertRaisesRegex(ValueError, "unsupported observation"):
            ObservationRequest.from_dict({"kind": "video"})

    def test_create_hashes_lease_and_idempotency_does_not_reveal_it_twice(self) -> None:
        session, lease, created = self.create("key-1")
        self.assertTrue(created)
        self.assertIsNotNone(lease)
        self.assertNotEqual(session.lease_token_hash, lease)
        self.assertEqual(
            self.live.authorize_lease(session.id, lease or "", require_active=False).id,
            session.id,
        )
        duplicate, duplicate_lease, duplicate_created = self.create("key-1")
        self.assertFalse(duplicate_created)
        self.assertIsNone(duplicate_lease)
        self.assertEqual(duplicate.id, session.id)
        with self.assertRaisesRegex(LiveStoreError, "valid live lease"):
            self.live.authorize_lease(session.id, "wrong" * 20)

    def test_queued_job_blocks_live_session(self) -> None:
        self.jobs.create_job(JobRequest(target=self.request().target))
        with self.assertRaisesRegex(LiveStoreError, "Xcode job") as context:
            self.create()
        self.assertEqual(context.exception.code, "device_busy")

    def test_live_owner_blocks_atomic_job_claim_until_terminal(self) -> None:
        session, _, _ = self.create()
        job, _ = self.jobs.create_job(JobRequest(target=self.request().target))
        self.assertIsNone(self.jobs.claim_next_job())
        self.live.transition(session.id, LiveSessionStatus.CANCELLED)
        claimed = self.jobs.claim_next_job()
        self.assertIsNotNone(claimed)
        self.assertEqual(claimed.id if claimed else None, job.id)

    def test_ports_events_heartbeat_and_terminal_release(self) -> None:
        session, lease, _ = self.create()
        self.assertEqual(session.wda_port, 8100)
        self.assertEqual(session.mjpeg_port, 9100)
        renewed = self.live.renew_lease(
            session.id, lease or "", 120, maximum_lease_seconds=300
        )
        self.assertGreater(renewed.lease_expires_at, session.lease_expires_at)
        event = self.live.append_event(
            session.id, "test", "sample", {"ok": True}, trace_id=session.request.run_id
        )
        events = self.live.get_events(session.id, after=event.id - 1)
        self.assertEqual(events[-1].payload, {"ok": True})
        self.live.transition(session.id, LiveSessionStatus.CANCELLED)
        second, _, _ = self.create()
        self.assertEqual(second.wda_port, 8100)
        self.assertEqual(second.mjpeg_port, 9100)

    def test_event_pruning_keeps_newest_history_window(self) -> None:
        session, _, _ = self.create()
        for index in range(125):
            self.live.append_event(session.id, "bidi", "log.entryAdded", {"index": index})
        deleted = self.live.prune_events(session.id, 100)
        self.assertEqual(deleted, 26)
        events = self.live.get_events(session.id, after=0, limit=1000)
        self.assertEqual(len(events), 100)
        self.assertEqual(events[0].payload["index"], 25)
        self.assertEqual(events[-1].payload["index"], 124)
        self.assertEqual([event.id for event in events], sorted(event.id for event in events))

    def test_due_session_expires_and_releases_ownership(self) -> None:
        session, _, _ = self.create()
        expired = self.live.expire_due(now=session.lease_expires_at + 1)
        self.assertEqual([item.id for item in expired], [session.id])
        self.assertEqual(expired[0].status, LiveSessionStatus.EXPIRED)
        self.assertFalse(self.live.has_ownership())

    def test_concurrent_session_acquisition_has_one_winner(self) -> None:
        barrier = threading.Barrier(3)
        successes: list[str] = []
        errors: list[str] = []

        def create_session() -> None:
            barrier.wait()
            try:
                session, _, _ = self.create()
                successes.append(session.id)
            except LiveStoreError as error:
                errors.append(error.code)

        threads = [threading.Thread(target=create_session) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=5)
        self.assertEqual(len(successes), 1)
        self.assertEqual(errors, ["device_busy"])


if __name__ == "__main__":
    unittest.main()
