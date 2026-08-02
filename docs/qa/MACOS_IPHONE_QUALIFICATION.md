# Phase 10 macOS and Physical-iPhone Qualification Runbook

## Purpose

This runbook closes only the environmental gates that cannot be executed in the Linux sandbox. It qualifies the persistent LaunchAgent, Xcode simulator and cable runs, real WebDriverAgent signing and reuse, Appium live control, BiDi and MJPEG observations, iOS 18+ RemoteXPC events, trace continuity, recovery episodes, and deterministic evidence export on an authorized Mac and iPhone.

> Linux closure already covers source contracts, migrations, fault injection, deterministic evidence, Appium fake-driver HTTP/BiDi flow, and 138 Python plus 16 Node tests. Do not treat those checks as proof of physical-device behavior.

## 1. Prerequisites

Use a Mac with Xcode and its command-line tools selected. The iPhone must be trusted, unlocked, connected by USB, visible to `devicectl`, and have Developer Mode enabled. The Apple Development team must be authorized to sign the QA app and WebDriverAgent.

```bash
xcode-select -p
xcodebuild -version
xcrun devicectl list devices
xcrun xctrace list devices
python3 --version
```

The selected `python3` must be 3.11 or newer. Keep the repository on a local filesystem. Do not run the agent installation root from a shared or network-mounted directory.

## 2. Install the Persistent Agent

From the repository root:

```bash
cd mac-agent
./scripts/install.sh
```

The installer must report a healthy agent and managed Appium stack. It pins private Node 20.19.5, Appium 3.6.0, XCUITest 12.1.4, `faceswap-live` 1.0.0, and RemoteXPC 5.13.2. It must also produce a successful XCUITest doctor report unless the host was intentionally installed with the simulator-only override.

Define a reproducible operator command:

```bash
export FACESWAP_QA_AGENT_HOME="$HOME/.faceswap-qa-agent"
export FACESWAP_QA_CONFIG="$FACESWAP_QA_AGENT_HOME/config.json"
export PYTHONPATH="$FACESWAP_QA_AGENT_HOME/app"
qa_agent() {
  python3 -m faceswap_qa_agent --config "$FACESWAP_QA_CONFIG" "$@"
}
```

Verify the LaunchAgent and runtime:

```bash
launchctl print "gui/$(id -u)/com.faceswap.qa-agent"
qa_agent health
qa_agent appium-status
cat "$FACESWAP_QA_AGENT_HOME/logs/xcuitest-doctor.json"
```

## 3. Configure WebDriverAgent Signing

Edit the mode-`0600` configuration file. Set `wda.xcode_org_id` to the Apple Developer team identifier. Keep `wda.xcode_signing_id` as `Apple Development` unless the organization requires another identity. Set `wda.updated_bundle_id` to a team-owned unique bundle ID.

Example fragment:

```json
{
  "wda": {
    "updated_bundle_id": "com.example.FaceSwapQAWDA",
    "xcode_org_id": "TEAMID1234",
    "xcode_signing_id": "Apple Development",
    "xcode_config_file": "",
    "reuse": true,
    "use_preinstalled": false
  }
}
```

Validate permissions and restart:

```bash
chmod 600 "$FACESWAP_QA_CONFIG"
launchctl kickstart -k "gui/$(id -u)/com.faceswap.qa-agent"
qa_agent health
qa_agent appium-start
```

If `wda.use_preinstalled` is enabled, `wda.updated_bundle_id` remains mandatory and must identify the actually installed WebDriverAgent runner.

## 4. Discover and Fix the Target Device

```bash
qa_agent devices | tee /tmp/faceswap-devices.json
```

Record the physical iPhone UDID from the returned ready device. Use the explicit UDID in all cable work; do not rely on implicit selection when multiple devices are connected.

```bash
export FACESWAP_IPHONE_UDID="00008110-REPLACE-WITH-REAL-UDID"
```

## 5. Queued Xcode Qualification

### Simulator

```bash
qa_agent submit \
  --target simulator \
  --name "iPhone 16 Pro" \
  --only-testing FaceSwapLiveAppV17UITests/FaceSwapLiveAppV17UITests/testManifestActivationAndRootTabs \
  --label qualification=phase10 \
  --label environment=simulator
```

Poll the returned job ID:

```bash
qa_agent status JOB_ID
qa_agent tail JOB_ID --follow
```

### Cable Device

```bash
qa_agent submit \
  --target cable \
  --udid "$FACESWAP_IPHONE_UDID" \
  --only-testing FaceSwapLiveAppV17UITests/FaceSwapLiveAppV17UITests/testCableDeviceHardwareMediaAndNativeWebRTC \
  --label qualification=phase10 \
  --label environment=cable
```

The job must reach `succeeded` or produce a typed, evidence-backed failure. Retrieve the root trace from the job document and inspect it:

```bash
qa_agent trace TRACE_UUID
qa_agent trace-events TRACE_UUID --limit 5000
qa_agent trace-analytics TRACE_UUID
qa_agent trace-recoveries TRACE_UUID
qa_agent trace-download TRACE_UUID --output "/tmp/${TRACE_UUID}-queued-evidence.tar.gz"
shasum -a 256 "/tmp/${TRACE_UUID}-queued-evidence.tar.gz"
```

Confirm one immutable root crosses the job, xcodebuild environment, XCUITest launch, iOS QA result, events, and artifact manifest.

## 6. Live Appium/WDA Session

Open a live cable session:

```bash
qa_agent live-open \
  --target cable \
  --udid "$FACESWAP_IPHONE_UDID" \
  --lease-seconds 1200 \
  --language en \
  --locale en_US \
  --timeout 600 | tee /tmp/faceswap-live-open.json
```

Write the returned lease token to a private file without placing it on the command line:

```bash
umask 077
printf '%s\n' 'RETURNED_LEASE_TOKEN' > /tmp/faceswap-live.lease
export FACESWAP_LIVE_LEASE_FILE=/tmp/faceswap-live.lease
```

Record the live session UUID and root trace UUID. Exercise observations and actions using the exact CLI help emitted by the installed build:

```bash
qa_agent live-status LIVE_SESSION_UUID
qa_agent live-observe LIVE_SESSION_UUID --kind combined --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
qa_agent live-action LIVE_SESSION_UUID --kind find --parameters '{"using":"id","value":"qa.banner","multiple":false}' --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
qa_agent live-action LIVE_SESSION_UUID --kind qa_command --parameters '{"command":{"version":2,"command":"snapshotState","payload":{}}}' --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
qa_agent live-events LIVE_SESSION_UUID --limit 500 --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
qa_agent live-stream LIVE_SESSION_UUID --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
```

Use `qa_agent --help`, `qa_agent live-action --help`, and `qa_agent live-observe --help` if a parser option differs on the target installation. Do not invent an unlisted action or free-form mobile command.

Acceptance requirements:

| Surface       | Required evidence                                                                     |
| ------------- | ------------------------------------------------------------------------------------- |
| WDA           | Real signed WDA session, stable `/status`, expected bundle identity                   |
| Appium        | Managed PID and pinned versions; no unknown server adoption                           |
| BiDi          | Connected WebSocket, custom plugin event, context/log event where supported           |
| MJPEG         | At least one parsed frame with dimensions and SHA-256, or a typed screenshot fallback |
| iOS QA router | Version-2 command result with matching root, operation UUID, span, and traceparent    |
| Accessibility | Persistent root/operation/span/traceparent probes match the command result            |
| Evidence      | Screenshot/source/log artifacts carry root trace and provenance metadata              |

## 7. iOS 18+ RemoteXPC Network Monitor

This check is cable-only and requires iOS 18 or newer.

```bash
qa_agent live-action LIVE_SESSION_UUID \
  --kind start_network_monitor \
  --parameters '{}' \
  --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"

# Exercise one browser/media request, then inspect events.
qa_agent live-events LIVE_SESSION_UUID \
  --limit 1000 \
  --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"

qa_agent live-action LIVE_SESSION_UUID \
  --kind stop_network_monitor \
  --parameters '{}' \
  --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
```

Require at least one `appium:xcuitest.networkMonitor` event with the owning root trace, or record the exact typed platform/RemoteXPC failure and preserve its logs.

## 8. WDA Reuse and Preinstalled Mode

Close the live session, then open another live session against the same UDID with `wda.reuse=true`. Verify the expected WDA identity and that the second session reuses a healthy WDA path without port collision or stale ownership.

If preinstalled WDA is an approved deployment mode, install/sign the runner first, set `wda.use_preinstalled=true`, retain the explicit `wda.updated_bundle_id`, restart the service, and repeat the cable session. A missing or mismatched identity must fail closed.

## 9. Recovery and Fault Qualification

Perform each fault separately and preserve its trace before continuing.

| Fault                        | Action                                                            | Required outcome                                                                                 |
| ---------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Appium crash                 | Terminate only the agent-owned Appium process                     | Typed `appium_crashed` episode, terminal session cleanup, Appium/WDA log evidence, queue release |
| WDA loss                     | Stop/uninstall the active WDA runner or interrupt the WDA channel | Three consecutive failed health probes before `wda_unhealthy`, retained evidence                 |
| BiDi disconnect              | Interrupt the BiDi socket without killing the API                 | Typed `bidi_disconnected` episode and deterministic session outcome                              |
| Lease expiry                 | Stop heartbeats until expiry                                      | Typed lease-expiry recovery, terminal release, automatic evidence                                |
| USB disconnect               | Unplug and reconnect the cable during an active session           | Typed device/WDA failure, no competing ownership, evidence retained                              |
| Trust or Developer Mode loss | Revoke trust or disable Developer Mode for a controlled run       | Device readiness must fail closed with a specific reason; no untrusted session starts            |
| Agent restart                | `launchctl kickstart -k` during a running job or live session     | Verified stale-process handling, no unrelated PID termination, persisted recovery history        |

After each terminal owner:

```bash
qa_agent recovery-list --session-trace-id TRACE_UUID --limit 100
qa_agent trace TRACE_UUID
qa_agent trace-analytics TRACE_UUID
qa_agent trace-download TRACE_UUID --output "/tmp/${TRACE_UUID}-fault-evidence.tar.gz"
```

## 10. Determinism and Bundle Integrity

Export the same terminal trace twice:

```bash
qa_agent trace-export TRACE_UUID
qa_agent trace-download TRACE_UUID --output /tmp/evidence-a.tar.gz
qa_agent trace-export TRACE_UUID
qa_agent trace-download TRACE_UUID --output /tmp/evidence-b.tar.gz
shasum -a 256 /tmp/evidence-a.tar.gz /tmp/evidence-b.tar.gz
cmp /tmp/evidence-a.tar.gz /tmp/evidence-b.tar.gz
```

The hashes and bytes must match when source artifacts are unchanged. Inspect `manifest.json` inside the archive and confirm every exported artifact path is confined, every hash validates, no plaintext bearer/lease/text credential is present, and the qualification status is `pass`, `fail`, or `incomplete` for explicit reasons rather than inferred success.

## 11. Close and Clean Up

```bash
qa_agent live-close LIVE_SESSION_UUID --lease-token-file "$FACESWAP_LIVE_LEASE_FILE"
rm -f "$FACESWAP_LIVE_LEASE_FILE"
qa_agent health
launchctl print "gui/$(id -u)/com.faceswap.qa-agent"
```

Do not purge state until all evidence has been copied to an approved destination. The default uninstaller preserves state and artifacts; use its explicit purge option only after acceptance.

## 12. Final Acceptance Matrix

| Gate               | Pass condition                                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| LaunchAgent        | Survives logout/login or controlled restart and reports healthy                                                           |
| Simulator XCUITest | Selected Phase 10 scenario succeeds with one root trace and automatic evidence                                            |
| Cable XCUITest     | Explicit-UDID hardware scenario succeeds or produces typed evidence-backed failure                                        |
| WDA                | Signing, launch, identity, health, teardown, and configured reuse/preinstalled path verified                              |
| Live control       | Observations, element action, QA command, BiDi event, MJPEG/screenshot, SSE, heartbeat, and close verified                |
| RemoteXPC          | iOS 18+ network samples observed or a typed prerequisite failure retained                                                 |
| Recovery           | Appium, WDA, BiDi, lease, restart, and USB faults produce typed terminal episodes and release ownership                   |
| Trace              | Root continuity holds across API, persistence, Appium/WDA, iOS, events, analytics, and evidence                           |
| Evidence           | Automatic bundle exists, verifies, redacts secrets, and is deterministic on repeat export                                 |
| Safeguards         | Authentication, lease secrecy, command allowlisting, path/JSON bounds, process ownership, and private files remain active |

Record every command, returned ID, timestamp, device UDID, Xcode version, iOS version, signing team, outcome, trace UUID, recovery UUID, evidence SHA-256, and unresolved environmental issue in the qualification report.
