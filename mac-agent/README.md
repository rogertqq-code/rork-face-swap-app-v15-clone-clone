# FaceSwap QA Mac Agent

The **FaceSwap QA Mac Agent** is a persistent, per-user macOS service that serializes simulator and USB-connected iPhone QA jobs for `FaceSwapLiveAppV17-QA`. It provides a versioned loopback HTTP API, a local operator CLI, SQLite-backed restart recovery, deterministic Xcode command construction, device readiness discovery, bounded retries, cancellation, retained `.xcresult` bundles, and reversible `launchd` installation.

The implementation uses **Python 3.11 or newer and the standard library only**. It never accepts arbitrary commands, project paths, schemes, test plans, environment variables, or output locations from API clients. Every run uses the configured project plus the fixed QA scheme and test plan.

## Architecture

| Component | Responsibility |
|---|---|
| `models.py` | Validated job, target, device, artifact, result, and state-transition contracts. |
| `config.py` | Immutable loopback, path, Xcode, and execution-limit configuration. |
| `store.py` | WAL-mode SQLite queue, idempotency, atomic claims, audit events, retries, cancellation, restart recovery, artifacts, and retention. |
| `discovery.py` | `devicectl` JSON discovery, `xctrace` fallback, simulator discovery and deterministic selection, readiness classification, boot, and boot-status waits. |
| `runner.py` | Fixed `xcodebuild test` invocation, named test-plan configuration, destination selection, process-group cancellation, timeouts, logs, failure classification, and SHA-256 artifact inventory. |
| `service.py` | One-at-a-time worker, token lifecycle, verified stale-process recovery, pruning, HTTP lifecycle, and graceful shutdown. |
| `api.py` | Authenticated `/api/v1` loopback API with bounded bodies, queries, logs, and deterministic errors. |
| `cli.py` | Local `serve`, `health`, `devices`, `submit`, `jobs`, `status`, `cancel`, and `tail` commands. |
| `scripts/` | Upgrade-safe per-user install and reversible uninstall. |

## Prerequisites

The target Mac must have Xcode, Xcode command-line tools, Python 3.11 or newer, and a logged-in user session. Cable jobs additionally require an attached, paired, trusted, unlocked iPhone with Developer Mode enabled and valid signing credentials for the QA bundle identifiers.

## Install

From the repository root on the target Mac:

```bash
cd mac-agent
./scripts/install.sh
```

The installer copies the package to `~/.faceswap-qa-agent/app`, creates owner-only state, log, and artifact directories, writes `~/.faceswap-qa-agent/config.json`, generates a mode-`0600` bearer token, renders `~/Library/LaunchAgents/com.faceswap.qa-agent.plist`, validates the plist, bootstraps the service, and waits for API health.

The retained paths are:

| Path | Content |
|---|---|
| `~/.faceswap-qa-agent/config.json` | Agent configuration. |
| `~/.faceswap-qa-agent/state/api-token` | Local API bearer token. |
| `~/.faceswap-qa-agent/state/jobs.sqlite3` | Persistent job, event, and artifact metadata. |
| `~/.faceswap-qa-agent/artifacts/<job-id>/attempt-XX/` | Request, resolution, command, log, failure, and `.xcresult` evidence. |
| `~/.faceswap-qa-agent/logs/` | launchd stdout and stderr. |

## CLI

All client commands read the token file automatically:

```bash
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json health
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json devices
```

Submit a simulator run:

```bash
python3 -m faceswap_qa_agent \
  --config ~/.faceswap-qa-agent/config.json \
  submit \
  --target simulator \
  --name 'iPhone 16 Pro' \
  --idempotency-key simulator-regression-001
```

Submit an explicit cable-device run:

```bash
python3 -m faceswap_qa_agent \
  --config ~/.faceswap-qa-agent/config.json \
  submit \
  --target cable \
  --udid '00008110-EXAMPLE' \
  --max-retries 1 \
  --label source=operator
```

Restrict a run to one test identifier:

```bash
python3 -m faceswap_qa_agent \
  --config ~/.faceswap-qa-agent/config.json \
  submit \
  --target cable \
  --udid '00008110-EXAMPLE' \
  --only-testing 'FaceSwapLiveAppV17UITests/FaceSwapLiveAppV17UITests/test08CableDevicePublishesPhysicalCaptureAndAudioOutcome'
```

Inspect and control jobs:

```bash
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json jobs --limit 20
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json status <job-id>
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json tail <job-id> --follow
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json cancel <job-id>
```

## API

Every route requires:

```http
Authorization: Bearer <contents-of-state/api-token>
```

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/v1/health` | Service, worker, queue, and active-job state. |
| `GET` | `/api/v1/devices` | Normalized cable and simulator inventory. |
| `POST` | `/api/v1/jobs` | Create an idempotent declarative job. |
| `GET` | `/api/v1/jobs` | List jobs with optional `status` and `limit`. |
| `GET` | `/api/v1/jobs/{id}` | Retrieve job, events, and artifacts. |
| `POST` | `/api/v1/jobs/{id}/cancel` | Request idempotent cancellation. |
| `DELETE` | `/api/v1/jobs/{id}` | Cancellation alias. |
| `GET` | `/api/v1/jobs/{id}/log` | Read a bounded log range by byte offset. |
| `GET` | `/api/v1/jobs/{id}/artifacts` | List artifact paths, sizes, kinds, and hashes. |

Example job body:

```json
{
  "target": {
    "kind": "simulator",
    "udid": null,
    "name": "iPhone 16 Pro",
    "os": "latest"
  },
  "only_testing": [],
  "skip_testing": [],
  "timeout_seconds": 1800,
  "max_retries": 0,
  "labels": {
    "source": "operator"
  }
}
```

## Execution and Recovery

A single worker claims jobs in FIFO order. Simulator jobs select the named available runtime deterministically and wait for boot completion. Cable jobs require a unique ready device unless a UDID is supplied. The runner starts `xcodebuild` in a new process group and writes a separate attempt directory for each retry.

Cancellation sends `SIGTERM`, waits the configured grace period, then escalates to `SIGKILL`. At service startup, stale running records are reconciled. A recorded PID is terminated only when `ps` confirms that it is the expected Xcode process containing the configured project and scheme, preventing unrelated PID reuse from being acted on.

Transient failures may retry within the submitted budget. Signing and provisioning failures are terminal. Retention removes terminal database rows and their artifact directories after the configured age.

## Service Operations

```bash
launchctl print "gui/$(id -u)/com.faceswap.qa-agent"
launchctl kickstart -k "gui/$(id -u)/com.faceswap.qa-agent"
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.faceswap.qa-agent.plist"
```

Uninstall while retaining configuration, database, logs, and artifacts:

```bash
./scripts/uninstall.sh
```

Permanently remove retained state only when intended:

```bash
./scripts/uninstall.sh --purge
```

## Verification

Linux-hosted deterministic verification uses fake `xcrun` and `xcodebuild` executables while exercising real subprocess groups, SQLite, service threads, HTTP requests, timeouts, retries, cancellation, and artifact hashing:

```bash
cd mac-agent
PYTHONPATH=. python3 -m unittest discover -s tests -v
bash -n scripts/install.sh scripts/uninstall.sh
python3 -m py_compile faceswap_qa_agent/*.py tests/*.py
```

Final macOS qualification must run the installer, inspect the launchd service, submit a real simulator job, submit a real cable job, cancel a deliberately long job, restart the service during a queued/running sequence, and retain the resulting `.xcresult` bundles.

## Mandatory Appium, WebDriverAgent, and AI Live Control

The same persistent service owns both queued Xcode jobs and live sessions. A SQLite transaction grants exactly one global device execution lease: either an Xcode job or one Appium/WDA live session. There is no second queue and no competing device owner.

The staged installer pins **Node 20.19.5**, **Appium 3.6.0**, **XCUITest driver 12.1.4**, local **faceswap-live plugin 1.0.0**, and **appium-ios-remotexpc 5.13.2** in a private runtime and isolated `APPIUM_HOME`. Node archives are checked against reviewed, embedded official SHA-256 values. Appium startup fails if the exact driver, plugin, or RemoteXPC package is missing or mismatched, or if the driver/plugin fails to load. The installer fails closed when `appium driver doctor xcuitest` reports unmet prerequisites; `FACESWAP_QA_SIMULATOR_ONLY=1` is the explicit non-cable override.

For cable devices, configure `wda.xcode_org_id` and optionally `wda.updated_bundle_id` or `wda.xcode_config_file`. When `wda.use_preinstalled` is true, `wda.updated_bundle_id` is mandatory. WDA reuse is enabled by default. Every agent-created session is confined to the QA bundle `app.rork.face-swap-live-app-v17.qa`, requests `webSocketUrl`, allocates non-overlapping WDA and MJPEG ports, and carries the vendor capability `faceswap:liveControl=true` required by the local plugin.

| Interface | Purpose |
|---|---|
| `GET /api/v1/live/tools` | Closed JSON Schemas for AI-connectable session, action, observation, network-monitor, and QA-command tools. |
| `GET /api/v1/live/appium` | Managed Appium process, version, PID, and health. |
| `POST /api/v1/live/appium/start` | Verify and start the pinned Appium stack. |
| `POST /api/v1/live/sessions` | Atomically acquire the device and create Appium, WDA, BiDi, and MJPEG state. |
| `POST /api/v1/live/sessions/{id}/actions` | Execute an allowlisted element, gesture, text, alert, context, app, settings, network-monitor, or QA-router action. |
| `POST /api/v1/live/sessions/{id}/observations` | Capture screenshot, XML/JSON source, contexts, orientation, window, device, battery, or combined state. |
| `GET /api/v1/live/sessions/{id}/stream` | Authenticated SSE with monotonic IDs, replay, heartbeat, reconnect hint, and terminal event. |
| `DELETE /api/v1/live/sessions/{id}` | Tear down BiDi, MJPEG, WDA/Appium session state, retain logs, and release queue ownership. |

A typical cable session is operated as follows. Store the returned live lease in a mode-0600 file or `FACESWAP_LIVE_LEASE`; it is intentionally not accepted as a command-line flag.

```bash
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json appium-start
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json live-open \
  --target cable --udid 00008110-REPLACE-ME --lease-seconds 600
export FACESWAP_LIVE_LEASE='REPLACE-WITH-RETURNED-LEASE'
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json live-observe SESSION_ID \
  --kind combined --persist
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json live-action SESSION_ID \
  --kind tap --parameters '{"x":180,"y":420}'
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json live-stream SESSION_ID \
  --after 0 --max-reconnects -1
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json live-close SESSION_ID
```

WebDriver BiDi is mandatory on every live session. The agent subscribes to plugin action/observation events, XCUITest context changes, network-monitor samples, and log events, then persists a bounded recent history for resumable SSE clients. The dependency-free BiDi client validates the RFC 6455 handshake, masks client frames, serializes writes, correlates concurrent commands, responds to ping with pong, bounds messages, and shuts down deterministically. MJPEG provides the latest low-latency frame with backpressure; standard WebDriver screenshot observations remain deterministic and independent.

Experimental network monitoring is a closed pair of `start_network_monitor` and `stop_network_monitor` tools. Both the Python agent and direct Appium HTTP/BiDi plugin paths reject it unless XCUITest reports a **real cable-connected iOS 18+ device**. RemoteXPC 5.13.2 is installed and version-checked because this feature is mandatory.

The watchdog expires leases, fails unhealthy managed Appium immediately, and fails WDA after three consecutive loopback `/status` probe failures. Teardown always attempts Appium session deletion, closes BiDi and MJPEG, releases SQLite ownership, and writes a bounded, SHA-256-indexed per-session `appium-wda.log` artifact. Action summaries redact text, QA command bodies, tokens, passwords, authorization values, cookies, credentials, and secrets; observation summaries never embed raw observation values.

Linux qualification runs the full Python suite, Node plugin suite, real local Appium custom HTTP/BiDi fake-driver smoke test, static validator, shell syntax checks, JSON validation, and safeguard scan. The remaining macOS gate is real WDA signing and launch, Developer Mode/trust, physical MJPEG and BiDi streams, iOS 18+ RemoteXPC samples, launchd restart behavior, and cable teardown evidence.

## Protected GitHub Physical-Device Workflow

Phase 11 adds a manual, protected GitHub Actions entry point at `.github/workflows/physical-iphone-qa.yml`. It is intentionally inactive unless the repository is private, the dispatch is from `main`, the `physical-iphone-qa` environment approves the job, the protected activation variables match, and exactly one dedicated runner is available with `self-hosted`, `macOS`, and `faceswap-cable-qa`.

The repository bridge is `faceswap_qa_agent.github_runner`. It validates closed workflow inputs, binds execution to a mode-`0600` local activation document, acquires a private nonblocking host lock, confirms an idle Mac agent and one ready cable device, generates deterministic UUIDv5 run and trace identities, and submits only the fixed `JobRequest` schema. Scenarios map to source-controlled XCUITest identifiers; no caller can provide arbitrary tests, Xcode flags, Appium methods, commands, or artifact paths.

```bash
PYTHONPATH=mac-agent python3 -m faceswap_qa_agent.github_policy \
  --repository rogertqq-code/rork-face-swap-app-v15-clone-clone

PYTHONPATH="$HOME/.faceswap-qa-agent/app" python3 -m \
  faceswap_qa_agent.github_host \
  --config "$HOME/.faceswap-qa-agent/config.json" \
  --activation "$HOME/.faceswap-qa-runner/activation.json" \
  verify
```

The first command performs read-only GitHub checks for private visibility, environment reviewers, a `main`-only deployment policy, activation variables, branch protection, read-only workflow permissions, and one eligible runner. The second verifies the target Mac, local activation, private files, agent health, idle ownership, and exact device readiness.

The runner lifecycle scripts are `runner/setup.sh`, `runner/uninstall.sh`, and `runner/quarantine.sh`. Setup and uninstall are dry-run by default, require a private short-lived token file instead of a token argument, refuse root and paths outside the dedicated account's home, and expose `TEST_MODE=1` for zero-side-effect Linux verification. The local activation file binds repository, environment, runner account, runner name, label set, and iPhone UDID.

Every workflow completion invokes cleanup and then `faceswap_qa_agent.github_evidence`. The auditor requires operation-specific artifacts, opens files without following symlinks, verifies ownership and private modes, rejects special files, path escapes, databases, config, credentials, tokens, leases, signing material, and plaintext secret markers, and generates a SHA-256 upload manifest plus a sanitized GitHub summary. Cleanup failure writes a persistent quarantine marker; clearing it requires the documented exact acknowledgement and a fresh healthy-idle-device verification.

See `../docs/PHYSICAL_DEVICE_POLICY.md`, `../remote-qa-artifacts/phase-11-physical-device-runbook.md`, and `../remote-qa-artifacts/phase-11-github-admin-checklist.md`. Repository visibility changes, environment configuration, branch-protection changes, runner registration, workflow dispatch, and target-Mac/iPhone execution are external privileged gates and are never performed automatically by this implementation.
