# Phase 11: Protected GitHub Physical-Device Workflow

**Author:** Manus AI
**Status:** Code-complete and fail-closed; external GitHub administrator and target-Mac/iPhone activation gates remain.

## Executive Summary

Phase 11 adds a protected, manual-only GitHub Actions path for executing the existing FaceSwap QA system on one authorized cable-connected iPhone through one dedicated self-hosted Mac. GitHub warns that public-repository workflows can expose persistent self-hosted runners to untrusted pull-request code, so the workflow and local bridge both reject public repository execution.[1] The connected repository is currently public; therefore, the implementation is intentionally **non-activatable** until it is made private and the remaining administrator controls are configured.

The workflow does not create a second device-control system. It invokes the existing authenticated loopback Mac-agent API, preserves the canonical job and trace schemas, serializes physical-device ownership, and retains deterministic Phase 10 evidence. The target Mac additionally binds the repository, dedicated account, runner name, and iPhone UDID in a private local activation document.

| Area             | Implemented result                                                                                                                                                          |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Trigger          | `workflow_dispatch` only, with closed choice inputs and a validated UDID.                                                                                                   |
| Authorization    | Private repository, `main` branch/workflow ref, protected `physical-iphone-qa` environment, activation variables, local activation document, and dedicated labels.          |
| Runner           | Exact `self-hosted`, `macOS`, `faceswap-cable-qa` label set; reversible setup/uninstall scripts and quarantine control.                                                     |
| Device ownership | Repository-wide GitHub concurrency plus a nonblocking target-Mac advisory lock and existing job/live-session exclusion.                                                     |
| Execution        | Existing Mac-agent `/jobs` contract, exact cable target, allowlisted XCUITest selectors, bounded retry and timeout.                                                         |
| Evidence         | Redacted bridge state, bounded logs, device and trace context, deterministic trace bundle, analytics, recovery history, SHA-256 inventory, and sanitized job summary.       |
| Recovery         | Owner-scoped cancellation, always-running cleanup, persistent quarantine on any unproven idle/device state, exact acknowledgement and full re-verification before clearing. |
| Activation       | Blocked by current public visibility and unconfigured GitHub/runner controls.                                                                                               |

## Protected Workflow Contract

The workflow is stored at `.github/workflows/physical-iphone-qa.yml`. It uses the protected environment, exact dedicated labels, `contents: read`, a repository-wide physical-device concurrency group, and `cancel-in-progress: false`. GitHub routes a self-hosted job only when all requested labels match, so the custom label prevents unrelated Macs from accepting the job.[2] GitHub concurrency permits one running and one pending job for a group; the local advisory lock remains the authoritative device-ownership safeguard on the persistent machine.[3]

All third-party workflow steps are GitHub-owned actions pinned to immutable full commit SHAs. The job checks out only the requested `main` commit, validates the checked-out SHA, runs the Python bridge directly, executes cleanup under `always()`, audits the resulting evidence, uploads only the audited directory, and ends with a final gate that fails if execution, cleanup, or evidence auditing failed.

GitHub environments can impose required reviewers, deployment branch restrictions, and secret release only after protection rules pass.[4] The workflow references `physical-iphone-qa`, but the live policy verifier confirms that this environment and its required controls are not currently observable. Referencing an environment in YAML is therefore not accepted as proof of protection; administrator verification is mandatory before activation.

## Canonical Mac-Agent Bridge

`faceswap_qa_agent.github_runner` is the only workflow-to-agent bridge. It performs the following sequence:

| Stage            | Fail-closed behavior                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Context          | Requires the exact repository, private visibility, `main` ref and workflow ref, dedicated account, dedicated runner name, and runner temp directory.                                                    |
| Inputs           | Accepts only named operation/scenario/retry choices and a strict cable-device UDID. Unknown fields are rejected.                                                                                        |
| Local activation | Loads a private owned regular JSON file and matches repository, environment, account, runner, labels, and iPhone UDID.                                                                                  |
| Filesystem       | Confines configuration, token, database, activation, and lock state beneath the dedicated account; confines each run beneath `RUNNER_TEMP`; rejects symlinks and unsafe ownership or modes.             |
| Device lock      | Acquires a nonblocking `flock` lock with private metadata; concurrent attempts fail immediately.                                                                                                        |
| Agent preflight  | Requires healthy worker, empty queue, no active job, no active live session, stopped Appium ownership, sufficient free space, supported Xcode, and exactly one ready matching cable device.             |
| Submission       | Creates a deterministic run ID/root trace, submits the existing closed `JobRequest`, uses a bounded idempotency key, and selects only allowlisted tests.                                                |
| Monitoring       | Polls a single recorded job, writes bounded redacted logs through an exclusive private descriptor, enforces a workflow deadline, and cancels only that job on timeout, interruption, or bridge failure. |
| Evidence         | Requests deterministic trace export, downloads through existing SHA-verified APIs, and records trace, analytics, recovery, and device documents.                                                        |
| Cleanup          | Rechecks terminal job state, agent health, queue depth, live ownership, Appium ownership, and exact cable readiness. Any uncertainty writes quarantine and blocks future runs.                          |

## Evidence and Secret Controls

`faceswap_qa_agent.github_evidence` traverses only the deterministic run directory. It rejects symlinks, special files, hidden files, path escapes, databases, token/config/lease/signing material, mobile provisioning and key formats, private keys, plaintext secret markers, oversized files, excess file counts, and excess aggregate size. It hashes the exact open descriptor used for each accepted file, produces a deterministic inventory, and emits a sanitized Markdown summary.

Successful execute runs require the complete core evidence set. Failed runs require redacted failure evidence rather than fabricated success artifacts. Upload occurs only after the independent evidence audit passes, and GitHub artifact retention is bounded.

## Runner and Repository Controls

The dedicated runner scripts under `mac-agent/runner/` are reversible and dry-run by default. Setup requires a non-root dedicated account and a private one-time registration token, writes the local activation document privately, applies exact labels, installs the runner as a user service, and rolls back incomplete setup. Uninstall preserves state and evidence unless explicit confined purge is requested. Manual quarantine creation and clearing delegate to the canonical Python host controller rather than writing state in shell.

GitHub recommends least-privilege token permissions, immutable action references, protected environments, and avoiding privileged workflows that execute untrusted code.[5] The repository therefore adds explicit `CODEOWNERS`, weekly GitHub Actions Dependabot monitoring, read-only workflow permissions, no fork/PR/push triggers, and a read-only administrator verifier.

## Verification Results

| Gate                                        |                                                                                                                     Result |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------: |
| Python tests                                |                                                                                                             **152 passed** |
| Appium plugin Node tests                    |                                                                                                              **16 passed** |
| Phase 10 Mac-agent static contract          |                                                                                                                       PASS |
| Phase 11 protected-workflow static contract |                                                                                                                       PASS |
| Independent workflow YAML parser            |                                                                                                                       PASS |
| Swift syntax baseline comparison            |                                                                                                        **146 files, PASS** |
| Accessibility contract                      |                                                                               **293 patterns, 14 persistent probes, PASS** |
| UI scenarios                                |                                                                     **8 simulator/cable scenarios plus launch test, PASS** |
| Xcode project parser                        |                                                                                                                       PASS |
| QA test-plan JSON and shared-scheme XML     |                                                                                                                       PASS |
| Installer and runner shell syntax           |                                                                                                                       PASS |
| Focused cleanup/quarantine remediation      |                                                                                                        **14 tests passed** |
| Safeguard inventory and scans               | **589 files inventoried; 4,584 generic findings; 270 Phase 11-scoped findings; 42 plugin structural findings; no removal** |

The tests cover successful and failed fake-agent execution, deterministic identity, exact device selection, active-owner rejection, lock contention, timeout cancellation, cleanup failure, quarantine persistence, blocked reruns, path escape rejection, evidence symlink and secret rejection, policy pass/fail documents, ANSI-free bounded GitHub API parsing, canonical quarantine creation and clearing, and zero-external-operation runner test mode.

## Independent Audit Disposition

Seven checksum-verified audits completed before the user stopped the wide-research wave. Six reported PASS with no blockers across bridge ownership, evidence security, GitHub policy, repository controls, adversarial filesystem behavior, and holistic architecture. One cleanup/quarantine report returned FAIL with only two line citations and no defect description. The unsupported claim was not counted as proof, but the cited area was conservatively remediated by unifying clear behavior behind the canonical host verifier and extending direct fault tests. Three unfinished scopes were skipped at the user's request and are not represented as PASS evidence. Full details are in `phase-11-audit-triage.md`.

## Current Fail-Closed State

The live read-only report in `phase-11-live-github-policy.json` returns `status: fail`. The current blockers are:

| External control                      | Current result              |
| ------------------------------------- | --------------------------- |
| Repository private                    | FAIL: repository is public. |
| Protected environment reviewers       | FAIL or not observable.     |
| Environment custom branch policy      | FAIL or not observable.     |
| Environment restricted to `main`      | FAIL or not observable.     |
| Environment activation variables      | FAIL or not observable.     |
| `main` pull-request review protection | FAIL or not observable.     |
| Administrator/history protection      | FAIL or not observable.     |
| Default workflow permission `read`    | FAIL or not observable.     |
| Eligible dedicated self-hosted runner | FAIL or not observable.     |

This is the intended result. No physical-device workflow should be approved while these checks fail.

## Activation Sequence

1. Make the repository private. GitHub explicitly advises private repositories for self-hosted runner safety.[1]
2. Create the `physical-iphone-qa` environment with required reviewers, no self-review, no administrator bypass, and `main`-only deployment policy.[4]
3. Set the exact repository/environment activation variables described in `phase-11-github-admin-checklist.md`.
4. Configure branch protection and read-only default workflow permissions.
5. Install and qualify the Mac agent using the Phase 10 runbook.
6. Register the dedicated repository-scoped runner under the non-root account with exact labels and matching local activation.
7. Connect, trust, and pair the authorized iPhone; enable Developer Mode; complete WDA signing.
8. Run the read-only GitHub policy verifier and local host verifier; both must report PASS.
9. Approve and run the `canary` scenario first. Review evidence before enabling broader scenarios.
10. Use the quarantine and rollback procedures immediately on cleanup uncertainty, runner drift, device mismatch, or evidence failure.

> **Activation decision:** The source implementation is complete, but the workflow remains intentionally disabled by policy and runtime gates until an authorized administrator and target-Mac operator complete the external controls.

## References

[1]: https://docs.github.com/en/actions/reference/runners/self-hosted-runners "GitHub Docs: Self-hosted runners reference"
[2]: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow "GitHub Docs: Use self-hosted runners in a workflow"
[3]: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency "GitHub Docs: Control workflow concurrency"
[4]: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments "GitHub Docs: Manage deployment environments"
[5]: https://docs.github.com/en/actions/reference/security/secure-use "GitHub Docs: Secure use reference"
