from __future__ import annotations

import getpass
import json
import os
import pwd
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.github_host import (
    ACKNOWLEDGEMENT,
    ActivationPolicy,
    HostPolicyError,
    clear_quarantine,
    quarantine_status,
    set_quarantine,
    verify_host,
)
from faceswap_qa_agent.github_policy import GitHubAPIFetcher, PolicyVerifier


class PolicyVerifierTests(unittest.TestCase):
    def test_fetcher_disables_forced_color_and_parses_bounded_json(self) -> None:
        captured = {}

        def command_runner(command, **kwargs):
            captured.update(kwargs)
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=b'{"private":true,"visibility":"private"}',
                stderr=b"",
            )

        with mock.patch.dict(
            os.environ,
            {"GH_FORCE_TTY": "100%", "CLICOLOR_FORCE": "1"},
            clear=False,
        ):
            result = GitHubAPIFetcher(command_runner=command_runner)("repos/owner/name")
        self.assertTrue(result["private"])
        self.assertEqual(captured["env"]["NO_COLOR"], "1")
        self.assertNotIn("GH_FORCE_TTY", captured["env"])
        self.assertNotIn("CLICOLOR_FORCE", captured["env"])
        self.assertEqual(command_runner.__name__, "command_runner")

    def documents(self) -> dict[str, dict]:
        repository = "rogertqq-code/rork-face-swap-app-v15-clone-clone"
        return {
            f"repos/{repository}": {
                "private": True,
                "visibility": "private",
                "default_branch": "main",
            },
            f"repos/{repository}/environments/physical-iphone-qa": {
                "protection_rules": [
                    {
                        "type": "required_reviewers",
                        "reviewers": [{"type": "User", "reviewer": {"login": "reviewer"}}],
                    }
                ],
                "deployment_branch_policy": {
                    "protected_branches": False,
                    "custom_branch_policies": True,
                },
            },
            f"repos/{repository}/environments/physical-iphone-qa/deployment-branch-policies": {
                "branch_policies": [{"name": "main", "type": "branch"}]
            },
            f"repos/{repository}/environments/physical-iphone-qa/variables": {
                "variables": [
                    {"name": "PHYSICAL_QA_ACTIVATION", "value": "phase11-v1"},
                    {"name": "PHYSICAL_QA_REPOSITORY", "value": repository},
                    {"name": "PHYSICAL_QA_RUNNER_USER", "value": "qa-runner"},
                ]
            },
            f"repos/{repository}/branches/main/protection": {
                "required_pull_request_reviews": {
                    "require_code_owner_reviews": True,
                    "required_approving_review_count": 1,
                },
                "enforce_admins": {"enabled": True},
                "allow_force_pushes": {"enabled": False},
                "allow_deletions": {"enabled": False},
            },
            f"repos/{repository}/actions/permissions/workflow": {
                "default_workflow_permissions": "read",
                "can_approve_pull_request_reviews": False,
            },
            f"repos/{repository}/actions/runners": {
                "runners": [
                    {
                        "name": "faceswap-mac-01",
                        "status": "online",
                        "busy": False,
                        "labels": [
                            {"name": "self-hosted"},
                            {"name": "macOS"},
                            {"name": "faceswap-cable-qa"},
                        ],
                    }
                ]
            },
        }

    def test_full_policy_passes_and_public_repository_fails(self) -> None:
        documents = self.documents()
        report = PolicyVerifier(
            "rogertqq-code/rork-face-swap-app-v15-clone-clone", fetcher=lambda endpoint: documents[endpoint]
        ).verify()
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["failed_checks"], [])
        documents["repos/rogertqq-code/rork-face-swap-app-v15-clone-clone"]["private"] = False
        documents["repos/rogertqq-code/rork-face-swap-app-v15-clone-clone"]["visibility"] = "public"
        report = PolicyVerifier(
            "rogertqq-code/rork-face-swap-app-v15-clone-clone", fetcher=lambda endpoint: documents[endpoint]
        ).verify()
        self.assertEqual(report["status"], "fail")
        self.assertIn("repository_private", report["failed_checks"])

    def test_main_only_and_exact_runner_are_fail_closed(self) -> None:
        documents = self.documents()
        documents[
            "repos/rogertqq-code/rork-face-swap-app-v15-clone-clone/environments/physical-iphone-qa/deployment-branch-policies"
        ]["branch_policies"].append({"name": "release/*", "type": "branch"})
        documents["repos/rogertqq-code/rork-face-swap-app-v15-clone-clone/actions/runners"]["runners"].append(
            documents["repos/rogertqq-code/rork-face-swap-app-v15-clone-clone/actions/runners"]["runners"][0].copy()
        )
        report = PolicyVerifier(
            "rogertqq-code/rork-face-swap-app-v15-clone-clone", fetcher=lambda endpoint: documents[endpoint]
        ).verify()
        self.assertIn("environment_main_only", report["failed_checks"])
        self.assertIn("eligible_runner", report["failed_checks"])


class HostVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        config_path = self.root / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "api": {"host": "127.0.0.1", "port": 8765, "token_file": "state/token"},
                    "paths": {
                        "ios_root": "ios",
                        "project": "App.xcodeproj",
                        "database": "state/jobs.sqlite3",
                        "artifacts": "artifacts",
                        "logs": "logs",
                    },
                    "xcode": {"scheme": "QA", "test_plan": "QA"},
                    "limits": {"default_timeout_seconds": 30, "maximum_timeout_seconds": 60},
                }
            ),
            encoding="utf-8",
        )
        config_path.chmod(0o600)
        self.config = AgentConfig.load(config_path)
        self.config.ensure_directories()
        self.config.api.token_file.write_text("x" * 48, encoding="utf-8")
        self.config.api.token_file.chmod(0o600)
        activation_path = self.root / "activation.json"
        activation_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "activation": "phase11-v1",
                    "repository": "rogertqq-code/rork-face-swap-app-v15-clone-clone",
                    "environment": "physical-iphone-qa",
                    "runner_user": "qa-runner",
                    "runner_name": "faceswap-mac-01",
                    "device_udid": "00008110-TESTDEVICE",
                    "labels": ["self-hosted", "macOS", "faceswap-cable-qa"],
                }
            ),
            encoding="utf-8",
        )
        activation_path.chmod(0o600)
        self.policy = ActivationPolicy.load(activation_path)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_host_verification_passes_only_for_idle_ready_bound_host(self) -> None:
        class API:
            def request(self, method, path, **kwargs):
                if path == "/health":
                    return {
                        "status": "ok",
                        "worker_alive": True,
                        "active_job_id": None,
                        "active_live_session_id": None,
                        "queue_depth": 0,
                    }
                return {
                    "devices": [
                        {
                            "kind": "cable",
                            "udid": "00008110-TESTDEVICE",
                            "ready": True,
                        }
                    ]
                }

        report = verify_host(
            self.config,
            self.policy,
            api=API(),
            system_name="Darwin",
            effective_uid=501,
            username="qa-runner",
            runner_name="faceswap-mac-01",
        )
        self.assertEqual(report["status"], "pass")
        self.policy.assert_workflow(
            repository="rogertqq-code/rork-face-swap-app-v15-clone-clone",
            runner_user="qa-runner",
            runner_name="faceswap-mac-01",
            device_udid="00008110-TESTDEVICE",
        )

    def test_canonical_quarantine_marker_is_private_and_typed(self) -> None:
        result = set_quarantine(self.config, self.policy, "runner-maintenance")
        self.assertTrue(result["quarantined"])
        marker = self.config.paths.database.parent / "github-physical-device.quarantine.json"
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        status = quarantine_status(self.config)
        self.assertTrue(status["quarantined"])
        self.assertEqual(status["document"]["reason"], "runner-maintenance")
        with self.assertRaises(HostPolicyError):
            set_quarantine(self.config, self.policy, "arbitrary")
        with self.assertRaises(HostPolicyError):
            clear_quarantine(
                self.config,
                self.policy,
                "wrong acknowledgement",
                api=object(),
                verifier=lambda *args, **kwargs: {"status": "pass", "failed_checks": []},
            )
        cleared = clear_quarantine(
            self.config,
            self.policy,
            ACKNOWLEDGEMENT,
            api=object(),
            verifier=lambda *args, **kwargs: {"status": "pass", "failed_checks": []},
        )
        self.assertTrue(cleared["cleared"])
        self.assertFalse(marker.exists())
        set_quarantine(self.config, self.policy, "manual")
        with self.assertRaisesRegex(HostPolicyError, "host verification failed"):
            clear_quarantine(
                self.config,
                self.policy,
                ACKNOWLEDGEMENT,
                api=object(),
                verifier=lambda *args, **kwargs: {
                    "status": "fail",
                    "failed_checks": ["agent_idle"],
                },
            )


class RunnerScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name)
        self.runner = self.home / "actions-runner-faceswap"
        self.runner.mkdir()
        for name in ("config.sh", "svc.sh"):
            script = self.runner / name
            script.write_text("#!/bin/bash\nexit 99\n", encoding="utf-8")
            script.chmod(0o755)
        self.token = self.home / "registration-token"
        self.token.write_text("t" * 64 + "\n", encoding="utf-8")
        self.token.chmod(0o600)
        self.scripts = Path(__file__).parents[1] / "runner"
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "TEST_MODE": "1",
            "FACESWAP_QA_RUNNER_HOME": str(self.home / ".faceswap-qa-runner"),
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_setup_and_uninstall_test_mode_have_no_external_calls(self) -> None:
        common = [
            "--runner-user",
            pwd.getpwuid(os.geteuid()).pw_name,
            "--runner-dir",
            str(self.runner),
            "--token-file",
            str(self.token),
        ]
        setup = subprocess.run(
            [
                str(self.scripts / "setup.sh"),
                "--repository",
                "rogertqq-code/rork-face-swap-app-v15-clone-clone",
                "--runner-name",
                "faceswap-mac-01",
                "--device-udid",
                "00008110-TESTDEVICE",
                *common,
                "--apply",
            ],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(setup.returncode, 0, setup.stderr)
        activation = self.home / ".faceswap-qa-runner" / "activation.json"
        self.assertTrue(activation.is_file())
        self.assertEqual(activation.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(activation.read_text())["runner_name"], "faceswap-mac-01")
        (self.runner / "_work").mkdir()
        uninstall = subprocess.run(
            [str(self.scripts / "uninstall.sh"), *common, "--apply", "--purge-work"],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
        self.assertFalse(activation.exists())
        self.assertFalse((self.runner / "_work").exists())
        quarantine = subprocess.run(
            [str(self.scripts / "quarantine.sh"), "set", "--reason", "manual"],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(quarantine.returncode, 0)
        self.assertIn("mode=test", quarantine.stdout)


if __name__ == "__main__":
    unittest.main()
