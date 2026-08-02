# Phase 11 Protected Physical-iPhone Runbook

## Scope and current activation state

This runbook activates the manual GitHub Actions path that invokes the existing loopback Mac agent to run the QA XCUITest plan on one authorized cable-connected iPhone. The committed workflow is intentionally **fail closed**. At implementation time, the connected repository is public, the `physical-iphone-qa` environment is absent, and no eligible self-hosted runner is registered; therefore, no physical-device execution can begin until every external gate below is completed by an authorized administrator and target-Mac operator.

| Layer     | Required invariant                                                                                                                                                |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitHub    | Private repository, protected environment approval, `main`-only deployment policy, read-only workflow permissions, protected branch, and exact runner visibility. |
| Mac       | Dedicated non-root account, installed Phase 10 agent, private token and config, local activation document, Xcode signing, and one eligible runner service.        |
| iPhone    | Exact activated UDID, cable transport, pairing and trust, Developer Mode, unlocked first-run readiness, and valid signing/provisioning.                           |
| Execution | Manual dispatch, explicit confirmation, closed scenario allowlist, queued concurrency, local advisory lock, and Mac-agent single owner.                           |
| Evidence  | Redacted private files only, deterministic trace bundle, manifest hashes, terminal cleanup proof, and configured retention.                                       |

## Stage 1 — GitHub administrator controls

First make the repository private. Do not register a self-hosted runner while the repository is public. In repository Actions settings, set the default workflow token permission to **Read repository contents** and disable permission for workflows to create or approve pull requests.

Create the environment `physical-iphone-qa`. Add at least one required reviewer who is not the person initiating the run. Configure a custom deployment branch policy containing exactly `main`. Define these environment variables:

| Variable                      | Example                                                |
| ----------------------------- | ------------------------------------------------------ |
| `PHYSICAL_QA_ACTIVATION`      | `phase11-v1`                                           |
| `PHYSICAL_QA_REPOSITORY`      | `rogertqq-code/rork-face-swap-app-v15-clone-clone`     |
| `PHYSICAL_QA_RUNNER_USER`     | `qa-runner`                                            |
| `FACESWAP_QA_CONFIG`          | `/Users/qa-runner/.faceswap-qa-agent/config.json`      |
| `FACESWAP_QA_ACTIVATION_FILE` | `/Users/qa-runner/.faceswap-qa-runner/activation.json` |

Protect `main`. Require pull requests, at least one approval, code-owner review, administrator enforcement, and required status checks. Disable force pushes and branch deletion. Confirm that `.github/CODEOWNERS` assigns the workflow, Mac agent, runner scripts, iOS QA bridge, UI tests, validators, and policy to an authorized owner.

The connected repository owner is a GitHub user, so organization runner groups are unavailable. Register the runner at repository scope only after the repository is private. The workflow requires `self-hosted`, `macOS`, and `faceswap-cable-qa`; do not assign `faceswap-cable-qa` to general-purpose runners. If the repository is later transferred to an organization, add a dedicated `faceswap-physical-iphone` runner group restricted to this repository and workflow before reactivation.

Run the read-only verifier from an authenticated administrator workstation after configuring these controls:

```bash
cd mac-agent
PYTHONPATH=. python3 -m faceswap_qa_agent.github_policy \
  --repository rogertqq-code/rork-face-swap-app-v15-clone-clone
```

The verifier must return `status: pass`. It performs bounded `GET` requests only and does not change repository settings.

## Stage 2 — Dedicated target-Mac preparation

Use a dedicated, non-administrator macOS account such as `qa-runner`. Do not share this account or runner with untrusted workloads. Install the repository's Mac agent using `mac-agent/scripts/install.sh`, configure WebDriverAgent signing, and complete the Phase 10 Mac/iPhone qualification runbook first.

Download the official GitHub Actions runner archive from GitHub, verify its published checksum, and extract it beneath the dedicated account's home directory, for example `/Users/qa-runner/actions-runner-faceswap`. Do not run the repository runner setup script until `config.sh` and `svc.sh` are present and executable.

Obtain a short-lived repository or runner-group registration token through the GitHub administrator interface. Place it in a runner-owned mode-`0600` file; never provide it as a workflow input, repository secret, or command-line argument. Perform a dry run:

```bash
mac-agent/runner/setup.sh \
  --repository rogertqq-code/rork-face-swap-app-v15-clone-clone \
  --runner-name faceswap-mac-01 \
  --device-udid 00008110-REPLACE-WITH-AUTHORIZED-UDID \
  --runner-user qa-runner \
  --runner-dir /Users/qa-runner/actions-runner-faceswap \
  --token-file /Users/qa-runner/runner-registration-token
```

Review the resolved repository, account, runner name, device UDID, and directory. Then add `--apply`. The script refuses root, a mismatched account, paths outside the account home, symlinks, non-private token files, a previously configured runner, or missing runner scripts. It registers only the additional label `faceswap-cable-qa`; GitHub supplies the default self-hosted and platform labels. Remove the one-time token file after registration.

The setup creates `/Users/qa-runner/.faceswap-qa-runner/activation.json` with mode `0600`. Confirm it binds the private repository, protected environment, dedicated account, exact runner name, exact iPhone UDID, and exact label set.

## Stage 3 — Host and device readiness

Connect the authorized iPhone by cable. Pair and trust it, enable Developer Mode, unlock it, and confirm Xcode can see it. Ensure signing identities and provisioning permit both the QA app and WebDriverAgent. Verify the Mac agent is running and idle.

```bash
PYTHONPATH="$HOME/.faceswap-qa-agent/app" python3 -m \
  faceswap_qa_agent.github_host \
  --config "$HOME/.faceswap-qa-agent/config.json" \
  --activation "$HOME/.faceswap-qa-runner/activation.json" \
  verify
```

The report must pass Darwin, non-root account, runner identity, private config/token, agent health, idle ownership, and exact device readiness. Inspect quarantine separately:

```bash
mac-agent/runner/quarantine.sh status
```

A quarantined runner must not be re-enabled until the underlying fault is understood.

## Stage 4 — Protected preflight dispatch

Open **Actions → Protected Physical iPhone QA → Run workflow**. Select branch `main`, operation `preflight`, scenario `canary`, the exact activated UDID, a 15-minute timeout, zero retries, suitable retention, and no physical execution confirmation. Submit the run and approve the `physical-iphone-qa` environment only after checking the commit and inputs.

The preflight must prove private/main/manual context, protected variables, dedicated Mac identity, local activation, zero active ownership, a ready cable device, at least 10 GiB free, and the pinned Appium/XCUITest/plugin/RemoteXPC contract. Cleanup and evidence audit run even if preflight fails.

Accept the preflight only if the final workflow gate is green and the artifact contains `preflight.json`, `cleanup.json`, `summary.json`, `run-state.json`, `upload-manifest.json`, and `github-summary.md`. Verify manifest hashes locally before trusting the contents.

## Stage 5 — Cable canary and full qualification

After a successful preflight, dispatch operation `execute`, scenario `canary`, the exact activated UDID, explicit physical-device confirmation, zero retries, and a conservative timeout. Environment approval is required again. The canary runs deterministic launch identity and the cable hardware/audio outcome scenario.

Accept the canary only when the agent job succeeds, root trace continuity is preserved, trace analytics do not report `fail`, cleanup proves no queued job, active job, or active live session remains, and the audited artifact includes the deterministic `trace-evidence.tar.gz` with the SHA recorded in `bundle.json` and `upload-manifest.json`.

Then run individual scenarios as needed. Use `all` only after canary stability and sufficient maintenance time. The scenario input maps to a fixed source-code allowlist; it cannot submit arbitrary test identifiers or Xcode arguments.

## Stage 6 — Controlled fault injection

Perform these tests during a maintenance window and never against an unrelated device:

| Fault                                                                  | Expected behavior                                                                                                          |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Disconnect cable during an execute run                                 | Agent records device failure, job becomes terminal, cleanup fails readiness, and the runner is quarantined.                |
| Stop the agent during polling                                          | Bridge reports a bounded agent error, attempts cancellation, cleanup cannot prove health, and quarantine persists.         |
| Start a live Appium session before dispatch                            | Preflight rejects active ownership and no Xcode job starts.                                                                |
| Hold the host lock                                                     | A concurrent run exits with `device_lock_busy`; it does not submit a job.                                                  |
| Place a token-like file or plaintext bearer value in the run directory | Evidence audit fails and upload is blocked.                                                                                |
| Trigger timeout                                                        | Bridge requests cancellation, waits for terminal state, and records a redacted failure summary.                            |
| Restart the Mac agent after an interrupted run                         | Existing Phase 10 restart recovery creates a typed recovery episode and terminal evidence before another run is permitted. |

After restoring the Mac agent and device to a healthy idle state, clear quarantine only with the exact acknowledgement:

```bash
mac-agent/runner/quarantine.sh clear \
  --acknowledge 'I verified the dedicated Mac, agent, and cable device are safe'
```

The clear command rechecks the private activation, account, agent health, idle ownership, and exact device readiness before removing the marker.

## Stage 7 — Evidence acceptance

Every uploaded directory must be mode-private on the Mac before upload and must pass the evidence auditor. Verify these acceptance conditions:

| Check               | Acceptance criterion                                                                                                                                       |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manifest            | Every uploaded file appears exactly once with byte size and SHA-256.                                                                                       |
| Forbidden content   | No symlink, special file, database, token, lease, key, provisioning profile, config file, hidden file, or plaintext secret marker.                         |
| Correlation         | Repository SHA, GitHub run/attempt, agent run UUID, root trace UUID, job ID, device UDID, and scenario agree across context, summary, trace, and evidence. |
| Terminal cleanup    | `cleanup.json` is `clean`; queue depth is zero and no active owner remains.                                                                                |
| Trace qualification | Analytics qualification is `pass` or an explicitly reviewed environmental `incomplete`, never `fail`.                                                      |
| Retention           | Artifact retention matches the approved workflow input and organizational policy.                                                                          |

## Rollback and deactivation

To stop execution immediately, quarantine the Mac, take the runner offline, and disable or remove approvals from the protected environment. Do not weaken the workflow gates. Use the reversible uninstaller with a private short-lived removal token file:

```bash
mac-agent/runner/uninstall.sh \
  --runner-user qa-runner \
  --runner-dir /Users/qa-runner/actions-runner-faceswap \
  --token-file /Users/qa-runner/runner-removal-token
```

Review the dry run, then add `--apply`. State and work evidence are preserved by default. Add `--purge-work` only after evidence retention is complete and the confined work directory has been reviewed. Making the repository public automatically invalidates the automation; keep the runner offline before any visibility change.

## External qualification gates

Linux verification can validate the bridge, workflow contract, fake API, locking, redaction, evidence, policy, and scripts, but it cannot complete these gates: actual environment approval, private repository enforcement, runner-group restriction, macOS service registration, Xcode signing, physical pairing/Developer Mode, cable XCUITest execution, real cleanup after disconnect, and artifact upload from GitHub. Phase 11 is accepted for activation only after this runbook is executed on the intended private repository, dedicated Mac, and authorized iPhone.
