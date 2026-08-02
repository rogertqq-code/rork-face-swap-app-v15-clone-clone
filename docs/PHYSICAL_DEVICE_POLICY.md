# Physical iPhone QA Automation Policy

## Purpose and authorization boundary

This policy governs automated access to the FaceSwapLiveAppV17 QA build on an authorized physical iPhone connected to a dedicated self-hosted Mac. The automation exists exclusively for defensive quality assurance, reproducible diagnostics, and evidence-backed release qualification. It does not authorize access to third-party devices, production user accounts, or non-QA application builds.

> Physical-device automation is disabled unless the repository is private, the workflow runs from `main` through `workflow_dispatch`, the protected `physical-iphone-qa` environment approves the deployment, and the target Mac's private activation document independently binds the repository, runner account, runner name, and iPhone UDID.

## Required controls

| Control | Required policy |
|---|---|
| Repository visibility | Private only; public visibility is an immediate fail-closed condition. |
| Trigger | Manual `workflow_dispatch` only. Push, pull-request, scheduled, reusable, and repository-dispatch triggers are prohibited. |
| Branch | `main` only, with branch protection, code-owner review, at least one approval, administrator enforcement, and no force pushes or deletion. |
| Environment | `physical-iphone-qa`, with required reviewers and a custom deployment branch policy permitting only `main`. |
| Workflow permissions | Repository default `read`; workflow explicitly grants only `contents: read`. |
| Runner | Exactly one dedicated non-root macOS runner carrying `self-hosted`, `macOS`, and `faceswap-cable-qa`. General-purpose jobs must not target this label set. |
| Local activation | A mode-`0600`, runner-owned activation document binds repository, environment, runner user, runner name, labels, and the authorized cable-device UDID. |
| Device ownership | GitHub concurrency, the Mac agent's SQLite owner checks, and a nonblocking advisory host lock serialize access. |
| Input handling | Closed choices, strict UDID and label syntax, bounded timeouts, explicit physical-device confirmation, and a fixed test allowlist. |
| Tool execution | The bridge calls only the existing loopback Mac-agent API. Arbitrary shell, arbitrary Xcode arguments, arbitrary tests, and arbitrary Appium commands are prohibited. |
| Evidence | Only an audited private run directory may be uploaded. Symlinks, special files, databases, credentials, tokens, lease data, provisioning material, plaintext secret markers, and path escapes are rejected. |
| Cleanup | An always-running cleanup must prove the job is terminal, the agent is healthy and idle, and the authorized device remains ready. Failure creates a persistent quarantine marker. |

## Protected environment variables

The protected environment must define the following non-secret variables. Their values are treated as policy assertions and are checked again by the target Mac.

| Variable | Required value |
|---|---|
| `PHYSICAL_QA_ACTIVATION` | `phase11-v1` |
| `PHYSICAL_QA_REPOSITORY` | Exact `OWNER/REPOSITORY` identity |
| `PHYSICAL_QA_RUNNER_USER` | Dedicated non-root macOS account |
| `FACESWAP_QA_CONFIG` | Private installed agent configuration path |
| `FACESWAP_QA_ACTIVATION_FILE` | Private local activation-document path |

The API bearer token and any GitHub runner registration or removal token remain local files on the Mac. They must never be configured as workflow inputs, workflow variables, workflow secrets, command-line values, or uploaded artifacts.

## Review and dependency policy

Changes to the physical-device workflow, Mac agent, runner scripts, iOS QA bridge, XCUITest scenarios, evidence validators, and this policy require the designated code owner. Third-party actions must use immutable commit SHAs. Dependabot may propose GitHub Actions updates, but a maintainer must verify the upstream release and replace the pinned commit only through reviewed source changes.

## Quarantine and recovery

Cleanup failure, an unexplained active owner, an unhealthy agent, a missing or unready cable device, evidence-audit failure, or local activation mismatch blocks subsequent runs. The runner must remain quarantined until an operator investigates the retained evidence, restores an idle healthy agent and ready device, and invokes the explicit quarantine-clear command with the documented acknowledgement. Removing a marker without satisfying the verifier is prohibited.

## Prohibited practices

The following practices are prohibited: enabling this workflow while the repository is public; allowing fork or pull-request code onto the dedicated runner; using mutable action tags; sharing the runner with untrusted workloads; granting write permissions; exposing tokens in logs or artifacts; bypassing the local activation document; broad `rm -rf` cleanup outside confined directories; disabling the single-owner lock; submitting non-allowlisted test identifiers; or clearing quarantine without a successful readiness verification.

## Activation and rollback

The workflow file may exist before activation because every execution path fails closed until external controls are complete. Activation requires the administrator checklist and target-Mac runbook. Rollback consists of disabling the protected environment, taking the runner offline, applying quarantine, stopping the Mac agent if necessary, and using the reversible runner uninstaller. Evidence and state are preserved by default; destructive purge requires a separate explicit operator action.
