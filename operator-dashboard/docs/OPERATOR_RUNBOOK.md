# FaceSwap Remote iOS QA Operator Runbook

**Author:** Manus AI
**Status:** Software implementation complete; physical Mac and iPhone activation deferred

## 1. What this system contains

The system has three cooperating parts. The **iOS QA build** exposes registered QA features, typed commands, accessibility identifiers, built-in fixtures, and XCUITest scenarios only in the QA configuration. The **Mac USB agent** owns the connected iPhone, runs Xcode and Appium/WebDriverAgent work, publishes BiDi events, produces trace-linked evidence, and enforces quarantine and GitHub policy. The **operator dashboard** is the authenticated browser control plane for jobs, live sessions, traces, evidence, quarantine, and activation status.

| Component          | Location                                                                                       | Current status                                                                                                    |
| ------------------ | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| iOS QA application | `ios/FaceSwapLiveAppV17/`                                                                      | Implemented; device signing and physical execution require the user’s Mac and iPhone                              |
| XCUITest suite     | `ios/FaceSwapLiveAppV17UITests/`                                                               | Implemented; physical run deferred                                                                                |
| Mac USB agent      | `mac-agent/`                                                                                   | Implemented and locally qualified with 152 Python tests and 16 Node tests in the source workspace                 |
| Operator dashboard | `operator-dashboard/` in the GitHub delivery branch; managed project source during development | Implemented; 28 Vitest tests, TypeScript, production build, desktop/mobile/tablet and accessibility checks passed |

> The dashboard deliberately shows **Automation blocked fail-closed** until the private Mac-agent connection and every GitHub policy requirement are valid. This is expected before hardware setup.

## 2. Dashboard configuration

The managed dashboard already supplies its database, OAuth, storage, and owner environment values. Two additional server-only values connect it to the Mac agent.

| Environment variable  | Purpose                                                                            | Browser exposure          |
| --------------------- | ---------------------------------------------------------------------------------- | ------------------------- |
| `MAC_AGENT_BASE_URL`  | Private HTTPS URL that reaches the Mac agent, for example a private relay endpoint | Never exposed             |
| `MAC_AGENT_API_TOKEN` | Mac-agent bearer token                                                             | Never exposed             |
| `OWNER_OPEN_ID`       | Exact Manus identity permitted to use operator procedures                          | Server-side authorization |
| `JWT_SECRET`          | Session signing and AES-256-GCM live-lease encryption key                          | Never exposed             |
| `DATABASE_URL`        | Operator audit, job, live-session, evidence, policy, and quarantine persistence    | Never exposed             |

Add or update environment values through the project’s **Settings → Secrets** panel. Do not commit `.env` files. After the Mac-agent values are present, restart the dashboard service and use **Refresh** in the command center.

## 3. Mac and iPhone activation

Complete these steps on the Mac that will remain physically connected to the authorized iPhone.

1. Install the Mac agent from `mac-agent/` by following `mac-agent/README.md` and `mac-agent/docs/INSTALL.md`.
2. Install the repository’s required Xcode version, Node 20.19.5 runtime, Appium 3.6.0, XCUITest driver 12.1.4, and WebDriverAgent dependencies described in the Mac-agent documentation.
3. Connect the iPhone by USB, unlock it, trust the Mac, enable Developer Mode, and verify that the exact UDID appears in the agent readiness response.
4. Open the Xcode project, select the QA scheme, choose the correct development team, and confirm that the QA application and test targets sign for the connected device.
5. Start the Mac agent as its documented user LaunchAgent. Keep the Mac awake, online, and logged in to the dedicated runner account.
6. Expose the agent only through the approved private HTTPS route, then place that URL and its token in the dashboard’s server secrets.

The software does not fake successful pairing, signing, cable readiness, WDA health, or device telemetry. Each item must be observed from the real Mac and iPhone.

## 4. GitHub activation gate

The dashboard and agent require every named policy check to pass. A missing or unreadable check is a failure.

| Required condition                    | Operator action                                                                                      |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Private repository                    | Keep the repository visibility private                                                               |
| Protected default branch              | Apply branch protection to `main`                                                                    |
| Protected physical-device environment | Create the environment used by the QA workflow                                                       |
| Required reviewer                     | Add the designated reviewer to the protected environment                                             |
| Restricted workflow permissions       | Use least-privilege workflow permissions                                                             |
| Physical activation variable          | Set the repository/environment variable documented by the workflow                                   |
| Dedicated labeled Mac runner          | Register the Mac runner with the exact labels expected by `.github/workflows/physical-iphone-qa.yml` |
| Exact iPhone binding                  | Configure the authorized UDID on the runner and Mac agent                                            |

Do not begin a physical run until the dashboard’s **GitHub policy status** panel shows every check passing and the activation gate is open.

## 5. Normal operator workflow

### Submit a protected QA job

Choose a scenario, select or paste the ready device UDID, choose the retry budget, and retain the visible idempotency key. Select **Dispatch protected job** once. Reusing the same key loads the original job rather than starting duplicate hardware work.

### Start a guarded live session

When no job owns the device, enter the ready UDID and select **Start guarded live session**. The live controls become usable only when the session state is active, WebDriverAgent is healthy, BiDi is connected, quarantine is clear, and the activation gate remains open.

The action selector exposes only registered server-side action kinds. A `qa_command` must be a JSON object accepted by the iOS QA command router. Observation capture is separately allowlisted. Screenshot bytes are hashed on the server and receive a browser-visible storage URL only when the Mac-agent SHA-256 matches exactly.

### Inspect traces and evidence

Select a root trace to view its W3C traceparent, cross-stack timeline, recovery episodes, and analytics invariants. Select **Verify archive** to download the bounded archive to the server, verify the archive hash, inspect the manifest, verify every file hash, persist the sanitized summary, and expose links only for verified files.

### Use quarantine

Set quarantine with a clear operational reason before maintenance or containment work. Clearing requires the exact acknowledgement displayed in the panel and succeeds only after server-side readiness checks. Do not alter the acknowledgement text.

## 6. Recovery procedure

| Symptom                               | Action                                                                                               |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Dashboard says `gateway_unconfigured` | Add `MAC_AGENT_BASE_URL` and `MAC_AGENT_API_TOKEN`, then restart the dashboard                       |
| Agent telemetry is stale              | Confirm the Mac is awake, the agent LaunchAgent is running, and the private HTTPS route is reachable |
| Device is blocked                     | Unlock and trust the iPhone, verify Developer Mode, USB transport, pairing, signing, and exact UDID  |
| WDA is offline or degraded            | Stop the live session, inspect Mac-agent and WDA logs, rebuild/sign WDA, then open a new session     |
| BiDi is disconnected                  | End the session and open a new guarded session; controls remain disabled while BiDi is absent        |
| Evidence is rejected                  | Use the displayed verification reason; never bypass a hash, path, size, or manifest failure          |
| Quarantine cannot clear               | Confirm the agent is idle and the cable device is ready, then enter the exact acknowledgement again  |
| GitHub gate is blocked                | Correct every failed item in the policy panel; missing information remains a failure                 |

## 7. Qualification evidence

The dashboard qualification commands are:

```bash
pnpm check
pnpm test
pnpm build
git diff --check
```

The final dashboard pass produced **28 passing Vitest tests**, a clean TypeScript check, a successful production bundle, a clean whitespace check, no post-restart browser-console error, and responsive full-page captures at 1440 × 1100 and 390 × 844. An authenticated Chromium audit at 768 × 1024 inspected 30 interactive controls, found no missing accessible names, observed 20 unique keyboard tab stops with no focus-visibility failure, checked 165 text elements with no contrast failure, and detected no horizontal overflow. The production build reports a non-blocking JavaScript chunk-size advisory; it does not prevent compilation or operation.

## 8. Deliberately deferred work

Only actions requiring the user’s physical environment remain: entering the private Mac-agent URL and token, registering the dedicated Mac runner, selecting the Apple signing team, attaching and trusting the iPhone, binding its UDID, running Xcode/XCUITest/Appium/WDA against that device, and approving the protected GitHub environment. Until then, the system remains visibly and intentionally blocked.
