from __future__ import annotations

import hashlib
import io
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from faceswap_qa_agent.cli import (
    _live_lease,
    build_parser,
    command_live_stream,
    command_trace_download,
)
from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.install_config import build_config, migrate


class InstallConfigLiveCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repo"
        (self.repository / "ios" / "FaceSwapLiveAppV17.xcodeproj").mkdir(parents=True)
        self.appium = self.root / "runtime" / "appium"
        self.appium.parent.mkdir(parents=True)
        self.appium.write_text("binary")
        self.home = self.root / "appium-home"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_migration_preserves_signing_and_enforces_pinned_live_runtime(self) -> None:
        existing = {
            "wda": {
                "xcode_org_id": "TEAM123456",
                "updated_bundle_id": "com.example.WDA",
                "reuse": False,
            },
            "appium": {"version": "0.0.1", "host": "0.0.0.0"},
            "live": {"bundle_id": "com.example.release"},
        }
        data = build_config(
            existing,
            repository_root=self.repository,
            appium_executable=self.appium,
            appium_home=self.home,
        )
        self.assertEqual(data["wda"]["xcode_org_id"], "TEAM123456")
        self.assertEqual(data["wda"]["updated_bundle_id"], "com.example.WDA")
        self.assertFalse(data["wda"]["reuse"])
        self.assertEqual(data["appium"]["version"], "3.6.0")
        self.assertEqual(data["appium"]["xcuitest_driver_version"], "12.1.4")
        self.assertEqual(data["appium"]["host"], "127.0.0.1")
        self.assertEqual(data["appium"]["executable"], str(self.appium.resolve()))
        self.assertEqual(data["appium"]["home"], str(self.home.resolve()))
        self.assertEqual(data["live"]["bundle_id"], "app.rork.face-swap-live-app-v17.qa")

    def test_atomic_migration_is_mode_0600_and_loadable(self) -> None:
        path = self.root / "config.json"
        migrate(
            path,
            repository_root=self.repository,
            appium_executable=self.appium,
            appium_home=self.home,
        )
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        config = AgentConfig.load(path)
        self.assertEqual(config.appium.home, self.home.resolve())
        self.assertEqual(config.environment()["APPIUM_HOME"], str(self.home.resolve()))
        self.assertEqual(config.live.bundle_id, "app.rork.face-swap-live-app-v17.qa")

    def test_parser_exposes_all_live_commands_without_plaintext_lease_flag(self) -> None:
        parser = build_parser()
        commands = {
            "trace-index",
            "trace",
            "trace-events",
            "trace-analytics",
            "trace-recoveries",
            "trace-export",
            "trace-download",
            "recovery-list",
            "recovery-show",
            "appium-status",
            "appium-start",
            "live-tools",
            "live-open",
            "live-sessions",
            "live-status",
            "live-heartbeat",
            "live-action",
            "live-observe",
            "live-events",
            "live-stream",
            "live-close",
        }
        help_text = parser.format_help()
        for command in commands:
            self.assertIn(command, help_text)
        live_action = parser.parse_args(
            ["live-action", "00000000-0000-4000-8000-000000000000", "--kind", "tap"]
        )
        self.assertFalse(hasattr(live_action, "lease_token"))
        self.assertTrue(hasattr(live_action, "lease_token_file"))
        live_stream = parser.parse_args(
            [
                "live-stream",
                "00000000-0000-4000-8000-000000000000",
                "--max-reconnects",
                "2",
                "--reconnect-delay",
                "0",
            ]
        )
        self.assertEqual(live_stream.max_reconnects, 2)
        self.assertEqual(live_stream.reconnect_delay, 0.0)
        trace_events = parser.parse_args(
            [
                "trace-events",
                "00000000-0000-4000-8000-000000000000",
                "--after",
                "41",
                "--limit",
                "250",
            ]
        )
        self.assertEqual(trace_events.after, 41)
        self.assertEqual(trace_events.limit, 250)
        trace_export = parser.parse_args(
            ["trace-export", "00000000-0000-4000-8000-000000000000"]
        )
        self.assertEqual(trace_export.timeout, 600)
        trace_index = parser.parse_args(
            ["trace-index", "--owner-type", "job", "--offset", "5", "--limit", "25"]
        )
        self.assertEqual(trace_index.owner_type, "job")
        self.assertEqual(trace_index.offset, 5)
        self.assertEqual(trace_index.limit, 25)
        recovery_list = parser.parse_args(
            ["recovery-list", "--cause", "wda_unhealthy", "--limit", "10"]
        )
        self.assertEqual(recovery_list.cause, "wda_unhealthy")
        self.assertEqual(recovery_list.limit, 10)

    def test_trace_download_is_atomic_hash_verified_and_mode_0600(self) -> None:
        config_path = self.root / "config.json"
        migrate(
            config_path,
            repository_root=self.repository,
            appium_executable=self.appium,
            appium_home=self.home,
        )
        config = AgentConfig.load(config_path)
        config.api.token_file.parent.mkdir(parents=True, exist_ok=True)
        config.api.token_file.write_text("t" * 48, encoding="utf-8")
        body = b"deterministic-evidence-bundle"
        digest = hashlib.sha256(body).hexdigest()

        class Response:
            def __init__(self):
                self.headers = {
                    "Content-Length": str(len(body)),
                    "X-Content-SHA256": digest,
                }
                self.offset = 0

            def __enter__(self):
                return self

            def __exit__(self, *unused):
                return False

            def read(self, length=-1):
                if length is None or length < 0:
                    length = len(body) - self.offset
                result = body[self.offset : self.offset + length]
                self.offset += len(result)
                return result

        output = self.root / "downloads" / "trace.tar.gz"
        args = build_parser().parse_args(
            [
                "--config",
                str(config_path),
                "trace-download",
                "12345678-1234-4234-9234-1234567890ab",
                "--output",
                str(output),
            ]
        )
        with mock.patch("urllib.request.urlopen", return_value=Response()), mock.patch(
            "sys.stdout", new=io.StringIO()
        ):
            self.assertEqual(command_trace_download(args), 0)
        self.assertEqual(output.read_bytes(), body)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(list(output.parent.glob("*.part")), [])

        rejected = self.root / "downloads" / "rejected.tar.gz"
        rejected_args = build_parser().parse_args(
            [
                "--config",
                str(config_path),
                "trace-download",
                "12345678-1234-4234-9234-1234567890ab",
                "--output",
                str(rejected),
            ]
        )
        invalid = mock.Mock(st_mode=stat.S_IFDIR | 0o600, st_uid=os.geteuid())
        with mock.patch("urllib.request.urlopen", return_value=Response()), mock.patch(
            "faceswap_qa_agent.cli.os.fstat", return_value=invalid
        ), mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "not a regular file"):
                command_trace_download(rejected_args)
        self.assertFalse(rejected.exists())
        self.assertEqual(list(rejected.parent.glob("*.part")), [])

    def test_live_stream_resumes_after_disconnect_with_last_event_id(self) -> None:
        config_path = self.root / "config.json"
        migrate(
            config_path,
            repository_root=self.repository,
            appium_executable=self.appium,
            appium_home=self.home,
        )
        args = build_parser().parse_args(
            [
                "--config",
                str(config_path),
                "live-stream",
                "00000000-0000-4000-8000-000000000000",
                "--max-reconnects",
                "2",
                "--reconnect-delay",
                "0",
            ]
        )

        class Stream:
            def __init__(self, lines):
                self.lines = iter(lines)

            def __enter__(self):
                return self

            def __exit__(self, *unused):
                return False

            def readline(self):
                return next(self.lines, b"")

        requests = []
        streams = iter(
            [
                Stream([b"id: 7\n", b"event: action.completed\n", b"data: {}\n", b"\n"]),
                Stream([b"event: stream.closed\n", b"data: {}\n", b"\n"]),
            ]
        )

        def open_stream(request, timeout=None):
            requests.append(request)
            return next(streams)

        output = io.StringIO()
        with mock.patch(
            "faceswap_qa_agent.cli.load_token", return_value="api-token"
        ), mock.patch(
            "faceswap_qa_agent.cli._live_lease", return_value="lease-token"
        ), mock.patch(
            "faceswap_qa_agent.cli.urllib.request.urlopen", side_effect=open_stream
        ), mock.patch(
            "faceswap_qa_agent.cli.time.sleep"
        ), mock.patch(
            "faceswap_qa_agent.cli.sys.stdout", output
        ):
            self.assertEqual(command_live_stream(args), 0)

        self.assertEqual(len(requests), 2)
        self.assertIsNone(requests[0].get_header("Last-event-id"))
        self.assertEqual(requests[1].get_header("Last-event-id"), "7")
        self.assertIn("event: action.completed", output.getvalue())
        self.assertIn("event: stream.closed", output.getvalue())

    def test_live_stream_rejects_invalid_reconnect_controls(self) -> None:
        config_path = self.root / "config.json"
        migrate(
            config_path,
            repository_root=self.repository,
            appium_executable=self.appium,
            appium_home=self.home,
        )
        parser = build_parser()
        with mock.patch(
            "faceswap_qa_agent.cli.load_token", return_value="api-token"
        ), mock.patch(
            "faceswap_qa_agent.cli._live_lease", return_value="lease-token"
        ), mock.patch(
            "faceswap_qa_agent.cli.urllib.request.urlopen"
        ) as open_stream:
            invalid_count = parser.parse_args(
                [
                    "--config",
                    str(config_path),
                    "live-stream",
                    "00000000-0000-4000-8000-000000000000",
                    "--max-reconnects",
                    "-2",
                ]
            )
            with self.assertRaisesRegex(ValueError, "max_reconnects"):
                command_live_stream(invalid_count)

            invalid_delay = parser.parse_args(
                [
                    "--config",
                    str(config_path),
                    "live-stream",
                    "00000000-0000-4000-8000-000000000000",
                    "--reconnect-delay",
                    "61",
                ]
            )
            with self.assertRaisesRegex(ValueError, "reconnect_delay"):
                command_live_stream(invalid_delay)
            open_stream.assert_not_called()

    def test_live_lease_reads_file_or_environment(self) -> None:
        path = self.root / "lease"
        path.write_text("x" * 40)
        path.chmod(0o600)
        args = type("Args", (), {"lease_token_file": str(path)})()
        self.assertEqual(_live_lease(args), "x" * 40)
        environment_args = type("Args", (), {"lease_token_file": None})()
        previous = os.environ.get("FACESWAP_LIVE_LEASE")
        os.environ["FACESWAP_LIVE_LEASE"] = "y" * 40
        try:
            self.assertEqual(_live_lease(environment_args), "y" * 40)
        finally:
            if previous is None:
                os.environ.pop("FACESWAP_LIVE_LEASE", None)
            else:
                os.environ["FACESWAP_LIVE_LEASE"] = previous


if __name__ == "__main__":
    unittest.main()
