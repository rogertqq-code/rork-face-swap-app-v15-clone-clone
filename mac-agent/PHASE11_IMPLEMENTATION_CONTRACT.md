# Phase 11 Implementation Contract: Protected GitHub Physical-Device Workflow

## Goal

Provide an auditable, manual-only GitHub Actions entry point for authorized physical-iPhone QA on one dedicated self-hosted Mac. The workflow must reuse the existing loopback Mac-agent API, device ownership transaction, trace/evidence pipeline, and recovery ledger. It must never create a second Xcode/Appium owner.

## Current Activation State

The connected repository is public. No configured `physical-iphone-qa` environment, Actions variables, or eligible self-hosted runner could be confirmed; runner enumeration returned HTTP 403 for the current integration token. Therefore the workflow must be checked in **disabled by policy**: it will fail before checkout or device access unless all activation assertions below are present and the repository is private.

## Trust Boundary

Trusted components are the protected default-branch workflow, protected environment approval, dedicated runner service, repository-local Phase 11 bridge, loopback authenticated Mac agent, explicit cable-device UDID, and deterministic evidence archive. Pull-request content, fork code, arbitrary refs, workflow inputs, environment text, workspace residue, and remote artifacts are untrusted until validated.

## Activation Assertions

The physical job may proceed only when all conditions are true:

1. `github.event_name` is `workflow_dispatch`.
2. `github.ref` is exactly `refs/heads/main` and `github.sha` belongs to the dispatch event.
3. `github.event.repository.private` is true.
4. The protected environment is exactly `physical-iphone-qa`.
5. Environment variable `PHYSICAL_QA_ACTIVATION` equals `phase11-v1` and `PHYSICAL_QA_REPOSITORY` equals `github.repository`; their absence fails closed if GitHub implicitly creates an unprotected environment.
6. The job routes only to labels `self-hosted`, `macOS`, and `faceswap-cable-qa`.
7. The runner is Darwin, non-root, and the configured dedicated account (default `qa-runner`).
8. The local agent configuration and bearer-token file are private regular files and the API is loopback-only.
9. The explicit UDID resolves to one ready cable device with no readiness reasons.
10. The agent reports no conflicting active job or live session, and the repository-local advisory lock is acquired.
11. Required free disk, pinned Appium/XCUITest/plugin/RemoteXPC versions, Xcode, and `devicectl` are available.

## Workflow Contract

The only trigger is `workflow_dispatch`. Workflow permissions are `contents: read`. The job references the protected environment, has a fixed maximum timeout, and uses repository-wide concurrency `faceswap-physical-iphone` with queued execution and no in-progress cancellation. The workflow checks out exactly `github.sha` with credentials disabled and cleanup enabled. Every `uses:` dependency is pinned to a verified 40-character Git commit SHA.

Inputs are closed choices except the explicit UDID and optional trace label. Inputs are passed as environment variables, never interpolated into generated shell source. The repository-local Python bridge validates all values before API calls.

| Input | Contract |
|---|---|
| `operation` | `preflight` or `execute` |
| `scenario` | One allowlisted XCUITest scenario or `all` |
| `device_udid` | 4–128 ASCII alphanumeric/hyphen characters; explicit and required |
| `timeout_minutes` | Choice: 15, 30, 45, 60, 90, or 120 |
| `retry_count` | Choice: 0, 1, or 2 |
| `retention_days` | Choice: 1, 3, 7, 14, or 30 |
| `trace_label` | Empty or 1–64 characters from `[A-Za-z0-9_.-]` |
| `confirm_physical_device` | Must be true for `execute` |

The bridge maps the scenario to fixed `only_testing` identifiers. It generates deterministic UUIDv5 run and trace identities from repository, commit, GitHub run ID, attempt, UDID, and scenario; constructs one canonical job request; submits with a deterministic idempotency key; polls to a terminal state; streams bounded logs; requests deterministic trace evidence; validates and writes a private evidence bundle; and emits a bounded summary JSON. It never uses `eval`, `exec`, `shell=True`, arbitrary test identifiers, free-form artifact paths, or caller-controlled commands.

## Exclusive Ownership

GitHub concurrency is the outer queue. The bridge opens one private regular lock file under the agent state root and holds an exclusive non-blocking `flock` for the complete preflight, submission, polling, evidence, and cleanup sequence. The lock metadata contains only bounded run identity, PID, commit, scenario, and UDID. The Mac agent remains authoritative for SQLite job/live-session exclusivity.

## Cleanup and Quarantine

A workflow `always()` step invokes the bridge cleanup command. Cleanup may cancel only the job ID recorded in the current private run state, waits for a terminal state, closes only agent-owned live sessions/processes, requests agent recovery/health, removes the run-state file, and releases the advisory lock through process exit. It never uses broad `pkill`, kills unknown PIDs, resets unrelated simulators, deletes the persistent agent database, or removes evidence.

If cleanup cannot prove a healthy agent, no conflicting ownership, and a ready requested device, it writes a private quarantine marker. Future executions fail until an authorized operator runs the inspected `quarantine-clear` command after remediation. Workflow cleanup failure fails the job.

## Evidence Contract

The run directory is a private, non-symlink path under `RUNNER_TEMP`. It contains input validation, preflight, request, job, bounded logs, trace document, analytics, recovery, evidence metadata, verified bundle, SHA-256, cleanup report, and final summary. Sensitive bearer and lease values never enter the workspace, summary, logs, or artifacts. GitHub upload uses a deterministic name containing run ID and attempt, fails if the required evidence set is absent for an execute run, rejects hidden/token/lease/config/database files through a pre-upload audit, and uses validated retention days.

## Repository Controls

`.github/CODEOWNERS` covers the physical workflow, Phase 11 bridge and tests, runner lifecycle assets, installer/launchd files, and Mac-agent authentication, live control, trace, evidence, recovery, persistence, and API code. Dependabot monitors GitHub Actions weekly; updates remain subject to CODEOWNERS and branch protection. The protected environment requires reviewers, prevents self-review, disables admin bypass, and allows only `main`. Default workflow permissions remain read-only and Actions cannot approve pull requests.

## Verification

Linux verification includes strict YAML/static validation, input and schema tests, fake loopback agent integration, lock contention, cancellation, timeout, cleanup/quarantine, evidence audit, exact action SHA checks, public-repository fail-closed behavior, CODEOWNERS coverage, and shell/Python compilation. Target-Mac verification additionally covers the dedicated runner account/service, environment approval, queued concurrency, real device preflight, canary XCUITest, cancellation/USB/WDA/Appium faults, automatic evidence, and quarantine recovery.

## External Gates

No repository visibility change, environment creation, branch-protection mutation, runner registration, secret/variable write, workflow dispatch, or target-Mac service installation is performed without explicit operator confirmation. These are sensitive external operations and remain documented activation tasks.
