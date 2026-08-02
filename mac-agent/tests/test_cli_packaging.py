from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from faceswap_qa_agent.cli import base_url, build_parser, command_submit, load_token
from faceswap_qa_agent.config import AgentConfig, ApiConfig, LimitsConfig, PathsConfig, XcodeConfig


class CLIPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.config = AgentConfig(
            api=ApiConfig("127.0.0.1", 8765, root / "token"),
            paths=PathsConfig(root / "ios", "App.xcodeproj", root / "db", root / "artifacts", root / "logs"),
            xcode=XcodeConfig("QA", "QA", "", "iPhone"),
            limits=LimitsConfig(4096, 30, 60, 2, 168, 1),
            config_path=root / "config.json",
        )
        self.config.api.token_file.write_text("x" * 43 + "\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_parser_exposes_all_commands(self) -> None:
        parser = build_parser()
        for command in ("serve", "health", "devices", "submit", "jobs", "status", "cancel", "tail"):
            arguments = [command]
            if command == "submit":
                arguments += ["--target", "simulator"]
            elif command in {"status", "cancel", "tail"}:
                arguments += ["00000000-0000-0000-0000-000000000000"]
            self.assertEqual(parser.parse_args(arguments).command, command)

    def test_load_token_and_base_url(self) -> None:
        self.assertEqual(load_token(self.config), "x" * 43)
        self.assertEqual(base_url(self.config), "http://127.0.0.1:8765/api/v1")

    def test_submit_builds_declarative_payload(self) -> None:
        parser = build_parser()
        args = parser.parse_args(
            [
                "submit",
                "--target",
                "cable",
                "--udid",
                "00008110-TEST",
                "--only-testing",
                "UITests/Test/testFlow",
                "--label",
                "source=cli",
                "--idempotency-key",
                "same",
            ]
        )
        captured = {}

        def fake_request(config, method, path, **kwargs):
            captured.update({"method": method, "path": path, **kwargs})
            return {"created": True}

        with patch("faceswap_qa_agent.cli.AgentConfig.load", return_value=self.config), patch(
            "faceswap_qa_agent.cli.api_request", side_effect=fake_request
        ), patch("faceswap_qa_agent.cli._print"):
            self.assertEqual(command_submit(args), 0)
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["payload"]["target"]["kind"], "cable")
        self.assertEqual(captured["payload"]["only_testing"], ["UITests/Test/testFlow"])
        self.assertEqual(captured["idempotency_key"], "same")

    def test_install_and_uninstall_contract(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "scripts" / "install.sh").read_text(encoding="utf-8")
        uninstall = (root / "scripts" / "uninstall.sh").read_text(encoding="utf-8")
        template = (root / "launchd" / "com.faceswap.qa-agent.plist.template").read_text(encoding="utf-8")
        for token in (
            "launchctl bootstrap",
            "launchctl kickstart -k",
            "chmod 600",
            "chmod 644 \"$PLIST_PATH.new\"",
            "plutil -lint",
            'REMOTEXPC_VERSION="5.13.2"',
            "appium-ios-remotexpc@$REMOTEXPC_VERSION",
            "FACESWAP_QA_SIMULATOR_ONLY",
            "SWAPPED_NODE=1",
            "cfed7503d8d99fbcf2f52e408ec52f616058eb0867b34dbc3437259993ef5cba",
            "f9cff058f2766d4d0631dc69b5f7f27664b3a42ff186e25ac7e1ac269af7e696",
        ):
            self.assertIn(token, install)
        self.assertIn("launchctl bootout", uninstall)
        self.assertIn("--purge", uninstall)
        self.assertIn("KeepAlive", template)
        self.assertIn("RunAtLoad", template)

    def test_installer_escape_sed_round_trips_special_paths(self) -> None:
        script = Path(__file__).parents[1] / "scripts" / "install.sh"
        value = str(Path.home() / "QA Root" / "slash\\name&pipe|tail\\")
        environment = dict(os.environ)
        environment["FACESWAP_QA_INSTALL_LIB_ONLY"] = "1"
        command = r'''
source "$1"
escaped="$(escape_sed "$2")"
printf '__TOKEN__' | sed "s|__TOKEN__|$escaped|g"
'''
        completed = subprocess.run(
            ["bash", "-c", command, "bash", str(script), value],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, value)


if __name__ == "__main__":
    unittest.main()
