from __future__ import annotations

import getpass
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from faceswap_qa_agent.config import AgentConfig
from faceswap_qa_agent.github_evidence import EvidenceAuditError, EvidenceAuditor
from faceswap_qa_agent.github_host import ActivationPolicy
from faceswap_qa_agent.github_runner import (
    DeviceLock,
    GitHubPhysicalRunner,
    GitHubRunnerError,
    WorkflowContext,
    WorkflowInputs,
    deterministic_identity,
)


class FakeAgentAPI:
    def __init__(
        self,
        trace_id: str,
        *,
        fail_after_submit: bool = False,
        never_terminal: bool = False,
    ) -> None:
        self.trace_id = trace_id
        self.job_id = str(uuid.uuid4())
        self.fail_after_submit = fail_after_submit
        self.never_terminal = never_terminal
        self.status_calls = 0
        self.cancelled = False
        self.cleanup_blocked = False
        self.requests: list[tuple[str, str]] = []
        self.device = {
            "kind": "cable",
            "udid": "00008110-TESTDEVICE",
            "name": "QA iPhone",
            "os_version": "18.1",
            "device_type": "iPhone",
            "ready": True,
            "developer_mode": "enabled",
            "transport": "wired",
            "readiness_reasons": [],
        }

    def request(self, method, path, *, payload=None, idempotency_key=None, timeout=120):
        self.requests.append((method, path))
        if path == "/health":
            return {
                "status": "ok",
                "version": "0.3.0",
                "queue_depth": 1 if self.cleanup_blocked else 0,
                "active_job_id": self.job_id if self.cleanup_blocked else None,
                "active_live_session_id": None,
                "worker_alive": True,
                "appium": {"status": "stopped"},
            }
        if path == "/devices":
            return {"devices": [self.device]}
        if method == "POST" and path == "/jobs":
            self.payload = payload
            self.idempotency_key = idempotency_key
            return {
                "created": True,
                "job": {
                    "id": self.job_id,
                    "status": "queued",
                    "session_trace_id": self.trace_id,
                },
            }
        if path == f"/jobs/{self.job_id}/cancel" and method == "POST":
            self.cancelled = True
            return {"job": {"id": self.job_id, "status": "cancelled"}}
        if path == f"/jobs/{self.job_id}":
            if self.fail_after_submit and not self.cancelled:
                raise GitHubRunnerError("injected_agent_failure", "injected polling failure")
            self.status_calls += 1
            status = "cancelled" if self.cancelled else (
                "running" if self.never_terminal or self.status_calls == 1 else "succeeded"
            )
            return {
                "job": {
                    "id": self.job_id,
                    "status": status,
                    "session_trace_id": self.trace_id,
                    "error_code": None,
                }
            }
        if path.startswith(f"/jobs/{self.job_id}/log?"):
            return {
                "log": {
                    "data": "test output token=supersecretvalue\n" if self.status_calls <= 1 else "",
                    "next_offset": 36,
                    "eof": self.status_calls > 1,
                }
            }
        if path == f"/jobs/{self.job_id}/artifacts":
            return {"job_id": self.job_id, "artifacts": []}
        if path == f"/traces/{self.trace_id}":
            return {"trace": {"session_trace_id": self.trace_id, "status": "succeeded"}}
        if path == f"/traces/{self.trace_id}/analytics":
            return {
                "analytics": {
                    "session_trace_id": self.trace_id,
                    "qualification": {"status": "pass"},
                    "invariants": {},
                }
            }
        if path == f"/traces/{self.trace_id}/recoveries":
            return {"recovery_episodes": []}
        if path == f"/traces/{self.trace_id}/evidence" and method == "POST":
            return {"evidence": {"status": "complete", "session_trace_id": self.trace_id}}
        raise AssertionError(f"unexpected request: {method} {path}")

    def download(self, path, destination, *, timeout):
        self.requests.append(("DOWNLOAD", path))
        payload = b"deterministic-evidence"
        destination.write_bytes(payload)
        destination.chmod(0o600)
        import hashlib

        return {
            "path": str(destination),
            "byte_size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "content_type": "application/gzip",
        }


class GitHubRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir(mode=0o700)
        self.config_path = self.root / "config.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "api": {"host": "127.0.0.1", "port": 8765, "token_file": "state/api-token"},
                    "paths": {
                        "ios_root": "ios",
                        "project": "App.xcodeproj",
                        "database": "state/jobs.sqlite3",
                        "artifacts": "artifacts",
                        "logs": "logs",
                    },
                    "xcode": {"scheme": "QA", "test_plan": "QA", "default_simulator_name": "iPhone"},
                    "limits": {
                        "default_timeout_seconds": 30,
                        "maximum_timeout_seconds": 7200,
                        "maximum_retries": 2,
                    },
                }
            ),
            encoding="utf-8",
        )
        self.config_path.chmod(0o600)
        self.config = AgentConfig.load(self.config_path)
        self.config.ensure_directories()
        self.config.api.token_file.write_text("x" * 48 + "\n", encoding="utf-8")
        self.config.api.token_file.chmod(0o600)
        self.context = WorkflowContext(
            repository="rogertqq-code/rork-face-swap-app-v15-clone-clone",
            sha="a" * 40,
            run_id="123456",
            run_attempt=1,
            ref="refs/heads/main",
            event_name="workflow_dispatch",
            runner_temp=self.runner_temp,
            runner_user=getpass.getuser(),
            runner_name="faceswap-mac-01",
            repository_private=True,
        )
        self.inputs = WorkflowInputs(
            operation="execute",
            scenario="canary",
            device_udid="00008110-TESTDEVICE",
            timeout_minutes=15,
            retry_count=0,
            retention_days=14,
            trace_label="ci",
            confirm_physical_device=True,
        )
        self.activation = self.root / "activation.json"
        self.activation.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "activation": "phase11-v1",
                    "repository": self.context.repository,
                    "environment": "physical-iphone-qa",
                    "runner_user": self.context.runner_user,
                    "runner_name": self.context.runner_name,
                    "device_udid": self.inputs.device_udid,
                    "labels": ["faceswap-cable-qa", "macOS", "self-hosted"],
                }
            ),
            encoding="utf-8",
        )
        self.activation.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def command_runner(command, **kwargs):
        output = "Xcode 16.4\nBuild version 16F6" if command[0] == "xcodebuild" else "/usr/bin/devicectl"
        return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

    def runner(
        self,
        api: FakeAgentAPI,
        *,
        context: WorkflowContext | None = None,
    ) -> GitHubPhysicalRunner:
        return GitHubPhysicalRunner(
            self.config,
            context or self.context,
            self.inputs,
            api=api,
            sleep=lambda _: None,
            command_runner=self.command_runner,
            activation_path=self.activation,
            installation_home=self.root,
        )

    def test_inputs_and_context_fail_closed(self) -> None:
        environment = {
            "INPUT_OPERATION": "execute",
            "INPUT_SCENARIO": "arbitrary-test",
            "INPUT_DEVICE_UDID": self.inputs.device_udid,
            "INPUT_TIMEOUT_MINUTES": "15",
            "INPUT_RETRY_COUNT": "0",
            "INPUT_RETENTION_DAYS": "14",
            "INPUT_CONFIRM_PHYSICAL_DEVICE": "true",
        }
        with self.assertRaisesRegex(GitHubRunnerError, "allowlisted"):
            WorkflowInputs.from_environment(environment)
        valid = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY_PRIVATE": "false",
            "GITHUB_REPOSITORY": self.context.repository,
        }
        with self.assertRaisesRegex(GitHubRunnerError, "private"):
            WorkflowContext.from_environment(valid, system_name="Darwin", effective_uid=501, username="qa-runner")

    def test_identity_is_deterministic_and_input_bound(self) -> None:
        first = deterministic_identity(self.context, self.inputs)
        second = deterministic_identity(self.context, self.inputs)
        self.assertEqual(first, second)
        changed = WorkflowInputs(**{**self.inputs.to_dict(), "only_testing": []}) if False else WorkflowInputs(
            operation=self.inputs.operation,
            scenario="hardware",
            device_udid=self.inputs.device_udid,
            timeout_minutes=self.inputs.timeout_minutes,
            retry_count=self.inputs.retry_count,
            retention_days=self.inputs.retention_days,
            trace_label=self.inputs.trace_label,
            confirm_physical_device=True,
        )
        self.assertNotEqual(first.session_trace_id, deterministic_identity(self.context, changed).session_trace_id)

    def test_execute_cleanup_and_audit_success(self) -> None:
        identity = deterministic_identity(self.context, self.inputs)
        api = FakeAgentAPI(identity.session_trace_id)
        runner = self.runner(api)
        with mock.patch(
            "faceswap_qa_agent.github_runner.shutil.disk_usage",
            return_value=SimpleNamespace(total=100, used=1, free=20 * 1024**3),
        ):
            summary = runner.run()
        self.assertEqual(summary["status"], "succeeded")
        self.assertEqual(api.payload["target"]["kind"], "cable")
        self.assertEqual(api.payload["session_trace_id"], identity.session_trace_id)
        self.assertEqual(len(api.payload["only_testing"]), 2)
        self.assertNotIn("supersecretvalue", (runner.run_directory / "job.log").read_text())
        cleanup = runner.cleanup()
        self.assertEqual(cleanup["status"], "clean")
        audit = EvidenceAuditor(runner.run_directory).audit("execute")
        self.assertGreater(len(audit.files), 10)
        self.assertTrue((runner.run_directory / "upload-manifest.json").is_file())
        self.assertEqual((runner.run_directory / "summary.json").stat().st_mode & 0o777, 0o600)

    def test_agent_failure_is_cancelled_and_auditable(self) -> None:
        identity = deterministic_identity(self.context, self.inputs)
        api = FakeAgentAPI(identity.session_trace_id, fail_after_submit=True)
        runner = self.runner(api)
        with mock.patch(
            "faceswap_qa_agent.github_runner.shutil.disk_usage",
            return_value=SimpleNamespace(total=100, used=1, free=20 * 1024**3),
        ):
            with self.assertRaises(GitHubRunnerError):
                runner.run()
        self.assertTrue(api.cancelled)
        runner.cleanup()
        result = EvidenceAuditor(runner.run_directory).audit("execute")
        self.assertTrue(any(item.path == "bridge-error.json" for item in result.files))

    def test_timeout_cancels_and_cleanup_quarantine_blocks_next_run(self) -> None:
        identity = deterministic_identity(self.context, self.inputs)
        clock_value = [0.0]

        def clock():
            clock_value[0] += 1000.0
            return clock_value[0]

        timeout_api = FakeAgentAPI(identity.session_trace_id, never_terminal=True)
        timeout_runner = GitHubPhysicalRunner(
            self.config,
            self.context,
            self.inputs,
            api=timeout_api,
            monotonic=clock,
            sleep=lambda _: None,
            command_runner=self.command_runner,
            activation_path=self.activation,
            installation_home=self.root,
        )
        with mock.patch(
            "faceswap_qa_agent.github_runner.shutil.disk_usage",
            return_value=SimpleNamespace(total=100, used=1, free=20 * 1024**3),
        ):
            with self.assertRaises(GitHubRunnerError) as caught:
                timeout_runner.run()
        self.assertEqual(caught.exception.code, "workflow_timeout")
        self.assertTrue(timeout_api.cancelled)
        timeout_runner.cleanup()

        quarantine_context = replace(self.context, run_attempt=2)
        quarantine_identity = deterministic_identity(quarantine_context, self.inputs)
        quarantine_api = FakeAgentAPI(quarantine_identity.session_trace_id)
        quarantine_runner = self.runner(quarantine_api, context=quarantine_context)
        with mock.patch(
            "faceswap_qa_agent.github_runner.shutil.disk_usage",
            return_value=SimpleNamespace(total=100, used=1, free=20 * 1024**3),
        ):
            quarantine_runner.run()
        quarantine_api.cleanup_blocked = True
        with self.assertRaisesRegex(GitHubRunnerError, "cleanup could not prove"):
            quarantine_runner.cleanup()
        self.assertTrue(quarantine_runner.quarantine_path.is_file())
        blocked_context = replace(self.context, run_attempt=3)
        blocked_identity = deterministic_identity(blocked_context, self.inputs)
        blocked_runner = self.runner(
            FakeAgentAPI(blocked_identity.session_trace_id), context=blocked_context
        )
        with self.assertRaisesRegex(GitHubRunnerError, "quarantined"):
            blocked_runner.run()

    def test_installation_paths_cannot_escape_dedicated_home(self) -> None:
        outside = self.root / "isolated-home"
        outside.mkdir(mode=0o700)
        identity = deterministic_identity(self.context, self.inputs)
        with self.assertRaisesRegex(GitHubRunnerError, "beneath"):
            GitHubPhysicalRunner(
                self.config,
                self.context,
                self.inputs,
                api=FakeAgentAPI(identity.session_trace_id),
                activation_path=self.activation,
                installation_home=outside,
            )

    def test_activation_mismatch_and_lock_contention_fail(self) -> None:
        policy = ActivationPolicy.load(self.activation)
        with self.assertRaisesRegex(Exception, "device_udid"):
            policy.assert_workflow(
                repository=self.context.repository,
                runner_user=self.context.runner_user,
                runner_name=self.context.runner_name,
                device_udid="00008110-WRONG",
            )
        lock_path = self.config.paths.database.parent / "manual.lock"
        with DeviceLock(lock_path, {"owner": "first"}):
            with self.assertRaisesRegex(GitHubRunnerError, "another authorized process"):
                with DeviceLock(lock_path, {"owner": "second"}):
                    pass


class EvidenceAuditorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, content: str = "{}\n") -> None:
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)

    def test_rejects_plaintext_secret_and_symlink(self) -> None:
        for name in ("inputs.json", "context.json", "preflight.json", "run-state.json", "summary.json", "cleanup.json"):
            self.write(name, '{"status":"preflight_succeeded"}\n' if name == "summary.json" else "{}\n")
        self.write("unsafe.log", "Authorization: Bearer abcdefghijklmnop\n")
        with self.assertRaisesRegex(EvidenceAuditError, "plaintext"):
            EvidenceAuditor(self.root).audit("preflight")
        (self.root / "unsafe.log").unlink()
        (self.root / "linked.txt").symlink_to(self.root / "summary.json")
        with self.assertRaisesRegex(EvidenceAuditError, "symlink"):
            EvidenceAuditor(self.root).audit("preflight")


if __name__ == "__main__":
    unittest.main()
