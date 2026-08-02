from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Protocol, Sequence
from urllib.parse import quote

from .github_runner import ACTIVATION_VALUE, REPOSITORY_PATTERN
from .json_safety import JSONSafetyError, loads_bounded
from .redaction import redact_structured, redact_text

ENVIRONMENT_NAME = "physical-iphone-qa"
RUNNER_GROUP_NAME = "faceswap-physical-iphone"
REQUIRED_RUNNER_LABELS = frozenset({"self-hosted", "macOS", "faceswap-cable-qa"})
MAXIMUM_GITHUB_RESPONSE_BYTES = 8 * 1024 * 1024


class PolicyVerificationError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class Fetcher(Protocol):
    def __call__(self, endpoint: str) -> Any: ...


@dataclass(frozen=True, slots=True)
class PolicyCheck:
    name: str
    passed: bool
    detail: str

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "passed": self.passed, "detail": self.detail[:512]}


class GitHubAPIFetcher:
    def __init__(
        self,
        *,
        command_runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
    ) -> None:
        self.command_runner = command_runner

    def __call__(self, endpoint: str) -> Any:
        if not endpoint.startswith(("repos/", "orgs/")) or any(
            marker in endpoint for marker in ("..", "\n", "\r", "\x00")
        ):
            raise PolicyVerificationError("unsafe_endpoint", "GitHub API endpoint was rejected")
        environment = os.environ.copy()
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["TERM"] = "dumb"
        environment.pop("GH_FORCE_TTY", None)
        environment.pop("CLICOLOR_FORCE", None)
        completed = self.command_runner(
            ["gh", "api", "--method", "GET", endpoint],
            capture_output=True,
            timeout=60,
            env=environment,
            check=False,
        )
        stdout = completed.stdout if isinstance(completed.stdout, bytes) else str(completed.stdout).encode("utf-8")
        stderr = completed.stderr if isinstance(completed.stderr, bytes) else str(completed.stderr).encode("utf-8")
        if len(stdout) > MAXIMUM_GITHUB_RESPONSE_BYTES:
            raise PolicyVerificationError("github_response_too_large", "GitHub API response exceeded the safe bound")
        if completed.returncode != 0:
            detail = redact_text(stderr[:65536].decode("utf-8", errors="replace"))
            raise PolicyVerificationError("github_api_failed", f"read-only GitHub API request failed: {detail}")
        try:
            return loads_bounded(
                stdout,
                maximum_bytes=MAXIMUM_GITHUB_RESPONSE_BYTES,
                maximum_depth=64,
                maximum_nodes=100000,
            )
        except JSONSafetyError as error:
            raise PolicyVerificationError("github_json_invalid", f"GitHub API JSON rejected: {error.code}") from error


class PolicyVerifier:
    def __init__(
        self,
        repository: str,
        *,
        fetcher: Fetcher | None = None,
        environment_name: str = ENVIRONMENT_NAME,
    ) -> None:
        if not REPOSITORY_PATTERN.fullmatch(repository):
            raise ValueError("repository must be an owner/name identifier")
        if environment_name != ENVIRONMENT_NAME:
            raise ValueError("environment_name must match the protected Phase 11 environment")
        self.repository = repository
        self.owner, self.name = repository.split("/", 1)
        self.fetcher = fetcher or GitHubAPIFetcher()
        self.environment_name = environment_name
        self.fetch_errors: list[dict[str, str]] = []

    def verify(self) -> dict[str, Any]:
        checks: list[PolicyCheck] = []
        repository = self._document(f"repos/{self.repository}")
        checks.append(
            PolicyCheck(
                "repository_private",
                repository.get("private") is True and repository.get("visibility") == "private",
                f"visibility={repository.get('visibility')!r}",
            )
        )
        checks.append(
            PolicyCheck(
                "default_branch_main",
                repository.get("default_branch") == "main",
                f"default_branch={repository.get('default_branch')!r}",
            )
        )

        environment = self._optional_document(
            f"repos/{self.repository}/environments/{quote(self.environment_name, safe='')}"
        )
        rules = environment.get("protection_rules")
        rules = rules if isinstance(rules, list) else []
        reviewer_rule = next(
            (item for item in rules if isinstance(item, dict) and item.get("type") == "required_reviewers"),
            None,
        )
        reviewers = reviewer_rule.get("reviewers") if isinstance(reviewer_rule, dict) else None
        checks.append(
            PolicyCheck(
                "environment_required_reviewers",
                isinstance(reviewers, list) and len(reviewers) >= 1,
                f"required_reviewer_count={len(reviewers) if isinstance(reviewers, list) else 0}",
            )
        )
        branch_policy = environment.get("deployment_branch_policy")
        checks.append(
            PolicyCheck(
                "environment_custom_branch_policy",
                isinstance(branch_policy, dict)
                and branch_policy.get("protected_branches") is False
                and branch_policy.get("custom_branch_policies") is True,
                f"deployment_branch_policy={redact_structured(branch_policy)}",
            )
        )
        branch_policies = self._optional_document(
            f"repos/{self.repository}/environments/{quote(self.environment_name, safe='')}/deployment-branch-policies"
        )
        branches = branch_policies.get("branch_policies")
        allowed_names = sorted(
            item.get("name")
            for item in branches
            if isinstance(branches, list) and isinstance(item, dict) and isinstance(item.get("name"), str)
        ) if isinstance(branches, list) else []
        checks.append(
            PolicyCheck(
                "environment_main_only",
                allowed_names == ["main"],
                f"allowed_branches={allowed_names}",
            )
        )

        variables = self._optional_document(
            f"repos/{self.repository}/environments/{quote(self.environment_name, safe='')}/variables"
        )
        variable_list = variables.get("variables")
        variable_values = {
            str(item.get("name")): item.get("value")
            for item in variable_list
            if isinstance(variable_list, list) and isinstance(item, dict)
        } if isinstance(variable_list, list) else {}
        checks.append(
            PolicyCheck(
                "environment_activation_variables",
                variable_values.get("PHYSICAL_QA_ACTIVATION") == ACTIVATION_VALUE
                and variable_values.get("PHYSICAL_QA_REPOSITORY") == self.repository
                and isinstance(variable_values.get("PHYSICAL_QA_RUNNER_USER"), str)
                and bool(str(variable_values.get("PHYSICAL_QA_RUNNER_USER")).strip()),
                "activation, repository binding, and dedicated runner-user variables are required",
            )
        )

        protection = self._optional_document(f"repos/{self.repository}/branches/main/protection")
        reviews = protection.get("required_pull_request_reviews")
        checks.append(
            PolicyCheck(
                "main_pull_request_reviews",
                isinstance(reviews, dict)
                and reviews.get("require_code_owner_reviews") is True
                and int(reviews.get("required_approving_review_count", 0)) >= 1,
                f"review_policy={redact_structured(reviews)}",
            )
        )
        enforce_admins = protection.get("enforce_admins")
        allow_force = protection.get("allow_force_pushes")
        allow_delete = protection.get("allow_deletions")
        checks.append(
            PolicyCheck(
                "main_admin_and_history_protection",
                isinstance(enforce_admins, dict)
                and enforce_admins.get("enabled") is True
                and (not isinstance(allow_force, dict) or allow_force.get("enabled") is False)
                and (not isinstance(allow_delete, dict) or allow_delete.get("enabled") is False),
                "administrator enforcement required; force pushes and deletions forbidden",
            )
        )

        workflow_permissions = self._optional_document(
            f"repos/{self.repository}/actions/permissions/workflow"
        )
        checks.append(
            PolicyCheck(
                "default_workflow_read_only",
                workflow_permissions.get("default_workflow_permissions") == "read"
                and workflow_permissions.get("can_approve_pull_request_reviews") is False,
                f"workflow_permissions={redact_structured(workflow_permissions)}",
            )
        )

        runners = self._optional_document(f"repos/{self.repository}/actions/runners")
        runner_list = runners.get("runners")
        eligible = []
        if isinstance(runner_list, list):
            for runner in runner_list:
                if not isinstance(runner, dict):
                    continue
                labels = {
                    str(item.get("name"))
                    for item in runner.get("labels", [])
                    if isinstance(item, dict)
                }
                if REQUIRED_RUNNER_LABELS.issubset(labels):
                    eligible.append(runner)
        checks.append(
            PolicyCheck(
                "eligible_runner",
                len(eligible) == 1
                and eligible[0].get("status") == "online"
                and eligible[0].get("busy") is False,
                f"eligible_runner_count={len(eligible)} online_idle={bool(eligible and eligible[0].get('status') == 'online' and eligible[0].get('busy') is False)}",
            )
        )

        passed = all(item.passed for item in checks)
        return {
            "schema_version": 1,
            "repository": self.repository,
            "environment": self.environment_name,
            "status": "pass" if passed else "fail",
            "checks": [item.to_dict() for item in checks],
            "failed_checks": [item.name for item in checks if not item.passed],
            "fetch_errors": list(self.fetch_errors),
        }

    def _document(self, endpoint: str) -> dict[str, Any]:
        value = self.fetcher(endpoint)
        if not isinstance(value, dict):
            raise PolicyVerificationError("github_document_invalid", f"GitHub endpoint returned a non-object: {endpoint}")
        return value

    def _optional_document(self, endpoint: str) -> dict[str, Any]:
        try:
            return self._document(endpoint)
        except PolicyVerificationError as error:
            self.fetch_errors.append({"endpoint": endpoint, "code": error.code})
            return {}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only Phase 11 GitHub policy verifier")
    parser.add_argument("--repository", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = PolicyVerifier(args.repository).verify()
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["status"] == "pass" else 1
    except (PolicyVerificationError, ValueError) as error:
        code = error.code if isinstance(error, PolicyVerificationError) else "invalid_policy_input"
        print(json.dumps({"error": {"code": code, "message": redact_text(str(error))}}, sort_keys=True), file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
