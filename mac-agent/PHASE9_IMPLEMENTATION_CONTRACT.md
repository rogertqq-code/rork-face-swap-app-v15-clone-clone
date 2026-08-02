# Phase 9 Implementation Contract

## Objective

Appium, the XCUITest driver, WebDriverAgent, and AI-connectable live control are mandatory. The implementation extends the existing `faceswap_qa_agent` instead of creating a second queue or a competing device owner.

## Ownership Model

The agent remains the sole owner of Xcode jobs and live sessions. Exactly one execution lease may exist globally in Phase 9: either one running Xcode job or one starting/active live session. A live session may start only when no queued or running job exists. While a live session exists, the worker does not claim jobs. Session teardown releases ownership and wakes the job worker.

## Components

| Component | Responsibility |
|---|---|
| `appium_manager.py` | Start, health-check, reuse, and stop the pinned Appium server process; verify PID identity; retain logs. |
| `webdriver.py` | Standard-library WebDriver HTTP client, session negotiation, deterministic command allowlist, response normalization, and bounded retries. |
| `live_models.py` | Live-session, lease, action, observation, event, capability, and error contracts. |
| `live_store.py` | SQLite live-session schema, atomic exclusivity, idempotency, events, lease renewal, expiry, and recovery. |
| `live_control.py` | Session orchestration, capabilities, Appium/WDA lifecycle, actions, observations, QA command-router flow, and watchdog cleanup. |
| `live_tools.py` | Exact JSON Schemas for AI-connectable tools and normalized results. |
| `mjpeg.py` | MJPEG frame parsing, latest-frame cache, metadata, bounded backpressure, and screenshot fallback. |
| `api.py` | Authenticated `/api/v1/live` resources, SSE event stream, action, observation, schema, and session lifecycle. |
| `cli.py` | Appium status, live create/list/get/heartbeat/observe/action/events/close commands. |
| `appium-plugin-faceswap-live/` | Local Appium plugin with custom HTTP and WebDriver BiDi command maps for schema, observation, and action forwarding. |

## Runtime Process Model

The Python launchd service owns one persistent Appium process on the configured loopback port. Appium owns the XCUITest driver and WDA lifecycle. Real-device sessions default to WDA reuse with `appium:useNewWDA=false`. The agent allocates a WDA local port and MJPEG port from configured bounded ranges, supplies the device UDID and fixed app bundle identifier, and optionally supplies either a configured Xcode configuration file or configured signing team and identity.

WDA liveness is observed through the Appium session plus the WDA status path. Appium and WDA logs are retained per session. A preinstalled WDA mode is available only when explicitly configured and the target OS supports it.

## Live Session State

`pending -> starting -> active -> stopping -> closed`

Failure terminals are `failed`, `expired`, and `cancelled`. Every active session has a server-generated lease token and expiration timestamp. Heartbeat extends the lease within configured bounds. The watchdog expires abandoned sessions and tears down their WebDriver session and process-owned resources.

## API

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/v1/live/tools` | AI tool JSON Schemas. |
| `GET` | `/api/v1/live/appium` | Appium process and health state. |
| `POST` | `/api/v1/live/appium/start` | Ensure the managed Appium server is healthy. |
| `POST` | `/api/v1/live/sessions` | Atomically acquire ownership and start a session. |
| `GET` | `/api/v1/live/sessions` | List sessions. |
| `GET` | `/api/v1/live/sessions/{id}` | Session state, lease, ports, and last error. |
| `POST` | `/api/v1/live/sessions/{id}/heartbeat` | Renew the live lease. |
| `POST` | `/api/v1/live/sessions/{id}/observations` | Screenshot, source, context, device, battery, or combined observation. |
| `POST` | `/api/v1/live/sessions/{id}/actions` | Execute one allowlisted action. |
| `GET` | `/api/v1/live/sessions/{id}/events` | Bounded JSON event history. |
| `GET` | `/api/v1/live/sessions/{id}/stream` | Authenticated server-sent event stream with sequence resume. |
| `DELETE` | `/api/v1/live/sessions/{id}` | Close and release ownership. |

## AI Action Allowlist

The initial allowlist is `tap`, `double_tap`, `touch_and_hold`, `swipe`, `drag`, `type_text`, `clear_text`, `press_key`, `find`, `get_attribute`, `set_context`, `alert`, `launch_app`, `activate_app`, `terminate_app`, `query_app_state`, `background_app`, `qa_command`, and `settings`. Every action has a closed JSON object schema, bounded strings and numbers, and session/device ownership validation.

## Observations

The initial observation types are `screenshot`, `source_xml`, `source_json`, `contexts`, `orientation`, `window_rect`, `device_info`, `battery_info`, and `combined`. Screenshots contain base64 plus SHA-256, dimensions when available, timestamp, sequence, and trace identity. Source trees may be returned inline within limits or persisted as session artifacts. MJPEG provides a low-latency latest-frame source with per-session port allocation; regular WebDriver screenshots remain the fallback.

## Real-Time Transport

The Mac agent provides authenticated SSE with monotonic sequence IDs, replay from `after`, heartbeat comments, bounded subscriber queues, and event categories for lifecycle, action, observation, Appium, WDA, syslog, and errors. The local Appium plugin provides custom HTTP and WebDriver BiDi command maps for AI schema, action, and observation. Native Appium syslog broadcast and XCUITest BiDi log events are used when available. SSE is the compatibility fallback and canonical dashboard stream.

## Evidence

Every action and observation records a trace ID, session ID, sequence, timestamp, request type, normalized result, elapsed time, and error. Large binary content is stored in a confined session artifact directory and referenced by hash and relative path. Raw secrets and bearer tokens are never written to evidence.

## Testing

Linux verification uses fake Appium and fake WDA HTTP servers, a fake Appium executable, deterministic MJPEG fixtures, SQLite lease races, HTTP and SSE clients, Appium plugin Node tests, and process recovery tests. macOS qualification installs the pinned Appium and XCUITest driver, validates WDA signing, starts simulator and cable sessions, exercises every action and observation family, verifies BiDi and SSE, confirms MJPEG, expires a lease, restarts the service, and retains evidence.
