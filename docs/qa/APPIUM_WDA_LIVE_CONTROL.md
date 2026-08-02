# Phase 9 — Mandatory Appium, WebDriverAgent, and AI Live Control

## Status

**Linux-verifiable implementation status: PASS.** Mandatory Appium, WebDriverAgent, WebDriver BiDi, MJPEG, authenticated SSE, and AI-connectable live control are implemented as extensions of the Phase 8 Mac agent. The final baseline passes **100 Python tests**, **15 Node plugin tests**, the Phase 9 static validator, shell syntax, JSON parsing, fake cable/Appium/WDA integration, concurrent BiDi stress, and a real pinned Appium custom HTTP/BiDi fake-driver smoke test.

**Environmental qualification remains open.** Real WDA signing and launch, iPhone Developer Mode and trust, launchd operation, physical MJPEG and BiDi streams, iOS 18+ RemoteXPC network samples, WDA reuse/preinstalled operation, and cable teardown evidence require the target Mac and iPhone. These are not represented as completed by Linux tests.

## Delivered architecture

The persistent Mac service remains the only execution owner. One SQLite transaction grants exactly one global execution lease: either a queued/running Xcode job or one starting/active live session. Appium, WDA, BiDi, MJPEG, SSE, AI tools, and evidence collection use the same service lifecycle, database, device discovery, API authentication, artifact root, and shutdown path. No second queue or competing device owner was created.

| Component                            | Delivered responsibility                                                                                                                                                                                          |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appium_manager.py`                  | Exact runtime verification, managed Appium process ownership, unknown-listener rejection, health, PID records, verified stale-process recovery, bounded log checkpoints, and shutdown.                            |
| `webdriver.py`                       | Strict W3C Appium client, QA-only capabilities, bounded request/response handling, normalized errors, element and gesture commands, app lifecycle, observations, and settings.                                    |
| `bidi.py`                            | Dependency-free RFC 6455 client with loopback confinement, handshake validation, masked frames, fragmentation, concurrent command correlation, subscriptions, ping/pong, message limits, and deterministic close. |
| `mjpeg.py`                           | WDA MJPEG ingestion, incremental JPEG parsing, dimensions and hashes, latest-frame backpressure, reconnect, and bounded lifecycle.                                                                                |
| `live_models.py` and `live_tools.py` | Closed live-session, action, observation, event, and AI JSON Schema contracts.                                                                                                                                    |
| `live_store.py`                      | Hashed leases, idempotency, ports, atomic Xcode/live exclusivity, transitions, event retention, artifacts, expiry, and restart recovery.                                                                          |
| `live_control.py`                    | Device acquisition, Appium/WDA creation, BiDi/MJPEG wiring, actions, observations, QA-router reuse, WDA health, evidence, lease watchdog, and cleanup.                                                            |
| `api.py` and `cli.py`                | Authenticated live routes, resumable SSE, bounded JSON and query handling, Appium controls, and operator commands.                                                                                                |
| `appium-plugin-faceswap-live/`       | Appium custom HTTP and WebDriver BiDi schema/action/observation methods with custom trace-correlated events and direct QA-bundle confinement.                                                                     |
| `json_safety.py`                     | Single audited decoder for byte, nesting-depth, and node-count limits across every production JSON parse path.                                                                                                    |

## Pinned private runtime

| Dependency          | Exact version or identity            |
| ------------------- | ------------------------------------ |
| Node                | `20.19.5`                            |
| Appium              | `3.6.0`                              |
| XCUITest driver     | `12.1.4`                             |
| Local Appium plugin | `faceswap-live` `1.0.0`              |
| RemoteXPC           | `appium-ios-remotexpc` `5.13.2`      |
| App bundle          | `app.rork.face-swap-live-app-v17.qa` |

The staged installer uses embedded reviewed SHA-256 values for the Darwin Node archives, an isolated `APPIUM_HOME`, exact extension version checks, a private runtime path, rollback-protected directory swaps, path confinement beneath the current user’s home, functional plist escaping, standard 0644 LaunchAgent permissions, mode-0600 secret/config files, and a fail-closed XCUITest doctor. `FACESWAP_QA_SIMULATOR_ONLY=1` is the explicit override when cable prerequisites are intentionally unavailable.

## Live control contract

Every agent-created XCUITest session requests `webSocketUrl`, carries `faceswap:liveControl=true`, uses the exact QA bundle, and receives unique WDA and MJPEG ports. WDA reuse is enabled by default. Preinstalled WDA is rejected unless an explicit updated WDA bundle identifier is configured.

The allowlist covers element lookup and interaction, coordinate gestures, text and keys, alerts, contexts, orientation, app lifecycle, settings, screenshots, XML/JSON source, device and battery information, combined observations, in-app typed QA commands, and experimental network monitoring. There is no arbitrary shell, free-form mobile command, unrestricted bundle, or unconstrained Appium proxy tool.

Experimental network monitoring is exposed only as `start_network_monitor` and `stop_network_monitor`. Both the Python service and direct Appium HTTP/BiDi plugin enforce a real cable-connected **iOS 18+** target. RemoteXPC is installed and version-checked before managed Appium can start.

## Real-time transport and evidence

WebDriver BiDi is mandatory for every live session. The agent subscribes to plugin action/observation events, XCUITest context changes, logs, and network-monitor samples. Events are retained in a bounded SQLite history and exposed through authenticated SSE with monotonic IDs, replay, `Last-Event-ID`, reconnect hints, heartbeats, and terminal events. The CLI resumes after disconnect and rejects invalid reconnect controls.

MJPEG supplies a low-latency latest frame with backpressure, while normal WebDriver screenshots remain a deterministic independent observation. Every action and observation has a trace identifier, sequence, timestamps, duration, normalized result, and typed failure. Large evidence is confined to a per-session artifact directory and indexed by relative path, size, and SHA-256. Teardown retains a bounded per-session `appium-wda.log` slice, including startup-failure paths.

The watchdog fails a live session immediately when managed Appium becomes unhealthy and after three consecutive WDA `/status` failures. Lease expiry, shutdown, partial startup failure, and explicit close all attempt BiDi, MJPEG, Appium session, port, runtime, and SQLite ownership cleanup.

## Safeguards retained

The live API remains loopback-only and bearer-authenticated. Live actions additionally require a 256-bit lease whose stored form is a hash and whose comparison uses constant-time verification. The plugin requires the exact QA bundle and agent vendor capability. Device, target, path, identifier, payload, action, observation, settings, port, retry, timeout, and state-transition inputs are allowlisted and bounded.

All production JSON decoding now routes through `json_safety.py`; direct `json.loads` elsewhere is rejected by the static validator. The shared decoder limits bytes, nesting depth, and node count across API, BiDi, WebDriver, Appium/WDA, CLI, configuration, device discovery, and SQLite reads. Text, QA command bodies, tokens, passwords, authorization values, cookies, credentials, and secrets are removed or hashed in summaries. Observation summaries never embed raw values.

The refreshed safeguard inventory reports **319 files scanned**, **3,818 heuristic repository findings**, and **1,194 Mac-agent/plugin findings**, with no truncation or warnings. These are retained evidence, not edit instructions. No safeguard removal was requested or performed.

## Verification evidence

| Gate                                                |                                                               Result |
| --------------------------------------------------- | -------------------------------------------------------------------: |
| Python compilation                                  |                                                                 PASS |
| Python tests                                        |                                                       **100 passed** |
| Node plugin tests                                   |                                                        **15 passed** |
| Phase 9 static validator                            |                                                                 PASS |
| `bash -n` installer/uninstaller                     |                                                                 PASS |
| Example configuration JSON                          |                                                                 PASS |
| 64-thread BiDi correlation stress                   |                                                                 PASS |
| Fake simulator and cable live control               |                                                                 PASS |
| WDA three-strike health and Appium failure watchdog |                                                                 PASS |
| SSE replay and CLI reconnection                     |                                                                 PASS |
| Sensitive-summary redaction                         |                                                                 PASS |
| Installer path round trip and rollback contracts    |                                                                 PASS |
| Real Appium custom HTTP/BiDi fake-driver smoke      |                                                                 PASS |
| Ten-agent closure audit                             | Eight initial PASS; two findings triaged and remediated/corroborated |
| Four-agent focused re-audit                         |                                         **Four PASS, zero blockers** |

The real Appium smoke used the pinned private Node runtime, Appium, XCUITest driver, official fake driver, and local plugin. It created an authorized session, invoked the custom schema and action methods, subscribed over WebDriver BiDi, received `faceswap:live.actionCompleted`, correlated the fixed trace ID, and deleted the session. The returned Appium double-slash WebSocket URL was normalized to the verified single-slash endpoint.

## Target Mac and iPhone qualification

Run the following on the authorized target Mac after setting the WDA team/signing values in the mode-0600 configuration:

```bash
cd mac-agent
./scripts/install.sh
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json health
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json devices
python3 -m faceswap_qa_agent --config ~/.faceswap-qa-agent/config.json appium-start
```

Create one simulator session and one explicit-UDID cable session, preserve each returned lease in a mode-0600 file or `FACESWAP_LIVE_LEASE`, then exercise combined observations, element lookup, tap, text, QA command, live SSE, MJPEG, heartbeat, and close. On the iOS 18+ cable device, additionally start and stop network monitoring and confirm `appium:xcuitest.networkMonitor` events. Inspect the per-session screenshot/source artifacts and `appium-wda.log`, restart the LaunchAgent, verify recovery, and rerun WDA reuse or preinstalled-WDA mode if configured.

The Phase 7 simulator and cable XCUITest commands remain documented in `phase-07-xcuitest-scenarios.md`; execute those alongside the live-control run.

## Evidence index

| Evidence                            | Purpose                                                                                |
| ----------------------------------- | -------------------------------------------------------------------------------------- |
| `phase-09-research-notes.md`        | Official Appium/XCUITest/plugin/BiDi/RemoteXPC research and live package verification. |
| `phase-09-bidi-smoke-result.json`   | Real Appium custom HTTP/BiDi success record.                                           |
| `phase-09-parallel-audit-triage.md` | Twelve-agent audit triage and final closure resolution.                                |
| `phase-09-safeguard-inventory.json` | Full mixed-language repository inventory.                                              |
| `phase-09-safeguard-findings.json`  | Machine-readable heuristic safeguard evidence.                                         |
| `phase-09-safeguard-summary.md`     | Retained controls, upstream effects, capability levels, and limits.                    |
| `phase9_final_closure_audit.json`   | Ten independent closure reviews.                                                       |
| `phase9_closure_reaudit.json`       | Four focused post-remediation PASS reviews.                                            |
| `build/validate_mac_agent.py`       | Deterministic Phase 8–9 static contract gate.                                          |
| `build/verify_appium_bidi.cjs`      | Reproducible real custom HTTP/BiDi verifier.                                           |

## Phase outcome

Phase 9 is complete for the Linux-verifiable implementation and evidence scope. There are no known remaining source blockers in the mandatory Appium, WebDriverAgent, BiDi, MJPEG, SSE, RemoteXPC, AI tool, installer, persistence, authentication, recovery, or evidence contracts. The open items are the explicit Mac/iPhone qualification gates above.
