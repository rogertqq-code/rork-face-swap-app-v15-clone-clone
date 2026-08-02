# FaceSwap QA Mac Agent — Implementation Contract

## Runtime and Constraints

The implementation uses Python 3.11 or newer and the standard library only. It runs as a per-user `launchd` agent on macOS with Xcode installed, binds to `127.0.0.1` by default, persists state in SQLite, and invokes `xcrun` and `xcodebuild` without a shell. All production code resides in `faceswap_qa_agent/`; deterministic Linux tests reside in `tests/`.

## Package Layout

```text
mac-agent/
  pyproject.toml
  config.example.json
  faceswap_qa_agent/
    __init__.py
    __main__.py
    config.py
    models.py
    store.py
    discovery.py
    runner.py
    service.py
    api.py
    cli.py
  launchd/
    com.faceswap.qa-agent.plist.template
  scripts/
    install.sh
    uninstall.sh
  tests/
```

## Configuration

`AgentConfig` loads JSON and resolves relative paths against the configuration file directory. Required effective values are:

```json
{
  "api": {"host": "127.0.0.1", "port": 8765, "token_file": "state/api-token"},
  "paths": {
    "ios_root": "../ios",
    "project": "FaceSwapLiveAppV17.xcodeproj",
    "database": "state/jobs.sqlite3",
    "artifacts": "artifacts",
    "logs": "logs"
  },
  "xcode": {
    "scheme": "FaceSwapLiveAppV17-QA",
    "test_plan": "FaceSwapLiveAppV17-QA",
    "developer_dir": "",
    "default_simulator_name": "iPhone 16 Pro"
  },
  "limits": {
    "max_request_bytes": 262144,
    "default_timeout_seconds": 1800,
    "maximum_timeout_seconds": 7200,
    "maximum_retries": 2,
    "retention_hours": 168,
    "kill_grace_seconds": 10
  }
}
```

The token file must be mode `0600`; the installer generates a 32-byte URL-safe token when absent.

## Job API

All routes are under `/api/v1` and require `Authorization: Bearer <token>`.

| Method | Path | Contract |
|---|---|---|
| `GET` | `/health` | Agent health, version, queue depth, active job ID. |
| `GET` | `/devices` | Simulator and cable device inventory with normalized readiness. |
| `POST` | `/jobs` | Validate and create an idempotent test job. |
| `GET` | `/jobs` | List newest jobs with optional `status` and bounded `limit`. |
| `GET` | `/jobs/{id}` | Full job record and artifact metadata. |
| `POST` | `/jobs/{id}/cancel` | Request cancellation; idempotent. |
| `DELETE` | `/jobs/{id}` | Alias for cancellation. |
| `GET` | `/jobs/{id}/log?offset=N&limit=N` | Bounded log tail with next offset. |
| `GET` | `/jobs/{id}/artifacts` | Artifact metadata and checksums. |

`POST /jobs` accepts an optional `Idempotency-Key` header and this JSON body:

```json
{
  "target": {
    "kind": "simulator",
    "udid": null,
    "name": "iPhone 16 Pro",
    "os": "latest"
  },
  "run_id": "optional UUID",
  "only_testing": [],
  "skip_testing": [],
  "timeout_seconds": 1800,
  "max_retries": 0,
  "labels": {"source": "operator"}
}
```

`target.kind` is `simulator` or `cable`. Cable jobs use test-plan configuration `Cable Device`; simulator jobs use `Simulator`. Test identifiers must match `[A-Za-z0-9_.\-/]+`. `run_id` is generated when absent. Arbitrary commands, schemes, plans, projects, environment variables, and output paths are not accepted from clients.

## State Machine

Statuses are `queued`, `running`, `succeeded`, `failed`, and `cancelled`. Valid transitions are:

```text
queued -> running | cancelled
running -> succeeded | failed | cancelled | queued(retry)
```

A single worker serializes all jobs. On startup, stale `running` jobs have their recorded process groups terminated when still alive and are either requeued within their retry budget or marked failed with `agent_restarted`.

## SQLite Contract

The store uses WAL mode, foreign keys, and `busy_timeout`. `jobs` stores request JSON, normalized target, state, attempt counters, timestamps, PID, result paths, exit code, error code/message, cancellation flag, and idempotency key. `events` stores timestamped state and audit events. `artifacts` stores relative path, kind, byte size, SHA-256, and creation time.

All store methods are thread-safe through one lock and short transactions. Required methods include `create_job`, `get_job`, `list_jobs`, `claim_next_job`, `request_cancel`, `is_cancel_requested`, `complete_job`, `fail_or_retry_job`, `recover_running_jobs`, `append_event`, `replace_artifacts`, and `queue_depth`.

## Device Discovery Contract

`DeviceDiscovery` receives an injectable command runner.

For physical devices it first runs `xcrun devicectl list devices --json-output <tempfile>` and consumes only the JSON file. It accepts the known `result.devices`, `devices`, or nested list variants. It normalizes UDID, CoreDevice identifier, name, OS version, device type, transport, pairing state, developer mode, and readiness. If `devicectl` is unavailable, it falls back to parsing `xcrun xctrace list devices`.

For simulators it runs `xcrun simctl list devices available --json`, normalizes runtime/name/UDID/state, selects a requested UDID or deterministic name/OS match, boots a shutdown simulator, and waits with `xcrun simctl bootstatus <udid> -b`.

## Runner Contract

`XcodeRunner` receives `AgentConfig`, `JobStore`, and `DeviceDiscovery`. It creates `artifacts/<job-id>/`, writes `request.json`, `resolved.json`, and `command.json`, and streams merged stdout/stderr to `xcodebuild.log`.

It invokes:

```text
xcodebuild test
-project <fixed project path>
-scheme FaceSwapLiveAppV17-QA
-testPlan FaceSwapLiveAppV17-QA
-only-test-configuration <Simulator|Cable Device>
-destination <normalized destination>
-parallel-testing-enabled NO
-test-timeouts-enabled YES
-default-test-execution-time-allowance <bounded>
-maximum-test-execution-time-allowance <bounded>
-collect-test-diagnostics on-failure
-resultBundlePath <job dir>/result.xcresult
```

Cable runs additionally use `-allowProvisioningUpdates`. `only_testing` and `skip_testing` become repeated `-only-testing:` and `-skip-testing:` arguments. A new process session enables process-group cancellation. The runner polls for timeout and cancellation, sends `SIGTERM`, waits the configured grace period, then sends `SIGKILL`.

## Service Contract

`AgentService` owns the store, discovery, runner, worker thread, and HTTP server. `start()` initializes directories, recovers stale jobs, starts the worker, and starts the server. `stop()` cancels the active process, shuts down HTTP, and joins threads. SIGTERM and SIGINT call `stop()`.

The worker claims one job at a time, executes it, records artifacts, applies bounded retries to transient failure codes (`device_unavailable`, `simulator_unavailable`, `timeout`, `xcodebuild_interrupted`), and respects cancellation.

## CLI and launchd Contract

`python3 -m faceswap_qa_agent serve --config <path>` runs the service. Client commands are `health`, `devices`, `submit`, `jobs`, `status`, `cancel`, and `tail`.

The installer copies/renders a per-user plist at `~/Library/LaunchAgents/com.faceswap.qa-agent.plist`, creates state/log/artifact directories, validates configuration, generates the token, runs `launchctl bootout gui/$(id -u) ...` when replacing an installation, then `launchctl bootstrap gui/$(id -u) ...` and `launchctl kickstart -k gui/$(id -u)/com.faceswap.qa-agent`. The uninstaller performs `bootout` and removes only the plist unless `--purge` is explicitly supplied.

## Test Contract

Linux tests use `unittest`, temporary directories, fake `xcrun` and `xcodebuild` executables, and no network beyond loopback. They cover configuration, validation, idempotency, transitions, restart recovery, device JSON normalization, simulator selection, exact xcodebuild arguments, success/failure/timeout/cancellation, HTTP authentication and body limits, API lifecycle, serialization, artifact checksums, and retention. macOS qualification later covers real launchd, Simulator, and cable iPhone execution.
