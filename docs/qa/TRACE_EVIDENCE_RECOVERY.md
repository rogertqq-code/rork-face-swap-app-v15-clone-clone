# Phase 10: Unified Trace Propagation, Deterministic Evidence, and Recovery Diagnostics

## Status

**Linux-verifiable implementation: PASS.**

**Independent code-level closure: PASS.**

**macOS/physical-iPhone qualification: OPEN ENVIRONMENTAL GATE.**

Phase 10 unifies queued Xcode jobs and live Appium/WebDriverAgent sessions under one immutable trace root, generates deterministic evidence at terminal boundaries, records typed recovery episodes, exposes authenticated trace/recovery/evidence APIs and CLI commands, and propagates trace identity through XCUITest, the iOS QA router, Appium capabilities, WebDriver commands, plugin HTTP/BiDi methods, streamed events, artifacts, and accessibility probes.

## Architecture

| Layer                     | Phase 10 responsibility                                                                                                                                                             |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Queued Xcode runner       | Creates one session root per job, derives child operation/span context, injects trace environment into `xcodebuild`, and retains a trace-context artifact.                          |
| XCUITest harness          | Reads the queued trace environment, forwards it into app launch, emits version-2 QA command envelopes, asserts returned trace continuity, and attaches trace probes on failure.     |
| iOS QA command router     | Validates UUIDs, spans, and W3C `traceparent`; preserves version-1 compatibility; returns root/operation/span fields on success and failure.                                        |
| Live Appium control       | Creates one root per live session, passes it as strict Appium capabilities, derives child spans for every action/observation, and correlates screenshots, source trees, and events. |
| Appium plugin and BiDi    | Rejects root mismatch, emits trace-rich custom HTTP/BiDi results, and broadcasts correlated custom events.                                                                          |
| Persistence               | Stores trace roots and operation/span metadata in schema-v2 job and live tables, enriches events/artifacts, and retains typed recovery episodes.                                    |
| Trace coordinator         | Resolves job or live ownership, merges events, calculates analytics, exposes recovery history, and exports deterministic evidence.                                                  |
| Evidence builder          | Confines paths, rejects symlinks, rehashes artifacts, validates exact temporary descriptors, emits canonical manifests, and creates byte-reproducible gzip/tar archives.            |
| Authenticated API and CLI | Exposes bounded trace/recovery indexes, detail/timeline/analytics, export and verified download, and mirrors them in operator commands.                                             |

## Canonical Trace Contract

Each owner has an immutable `session_trace_id` UUID. Each operation has an independent `operation_trace_id` UUID, a 16-hex span ID, and a normalized W3C version-00 `traceparent`. All-zero values, invalid lengths, invalid flags, mismatched explicit roots, mismatched spans, and cross-session reuse fail closed.

The canonical context crosses these boundaries:

1. API request or generated owner identity.
2. SQLite owner record and events.
3. `xcodebuild` environment or Appium capabilities.
4. XCUITest launch and QA manifest labels.
5. iOS QA command envelope and result.
6. WebDriver action/observation or Appium plugin request.
7. BiDi/SSE event stream.
8. Screenshot, source, log, telemetry, and xcresult artifact metadata.
9. Recovery episode.
10. Analytics and final evidence manifest.

The iOS app publishes persistent machine-readable probes for the active root, last operation UUID, span, and traceparent, in addition to the existing feature, media, WebRTC, synchronization, command, and error probes.

## Deterministic Evidence

Terminal queued jobs and live sessions automatically trigger evidence export. Evidence export remains non-authoritative over terminal state: export failure records a bounded durable diagnostic and never rewrites the underlying job/session outcome.

The builder:

- confines all source paths beneath the configured artifact root;
- rejects absolute paths, traversal, and source or output symlinks;
- validates artifact root trace, size, SHA-256, provenance, content type, and redaction state;
- excludes corrupt bytes and marks the manifest accordingly;
- canonicalizes JSON ordering;
- fixes gzip and tar metadata for byte-for-byte reproducibility;
- creates the output through a private same-directory temporary descriptor;
- forces mode `0600`, verifies the exact descriptor with `fstat`, requires a regular file owned by the effective user with no group/other bits, fsyncs, and atomically replaces;
- validates artifacts again during export so post-manifest mutation fails without replacing a prior valid bundle.

The authenticated evidence download path performs an additional persisted-path, symlink, size, and hash validation. It opens the file, rehashes the exact open descriptor before writing response headers, then streams the same descriptor with `Content-Length`, `X-Content-SHA256`, and `Cache-Control: no-store`.

The CLI `trace-download` independently bounds length to two gibibytes, validates the hash header, validates every streamed byte, verifies its exact `mkstemp` descriptor, fsyncs, atomically replaces the operator destination, and leaves mode `0600`.

## Analytics and Qualification

The analytics engine merges events deterministically, calculates nearest-rank latency summaries, classifies errors and recovery outcomes, and evaluates concrete invariants including root continuity, evidence hashes, artifact trace ownership, recovery closure, redaction classification, and exclusive device ownership.

Qualification has three honest states:

| Status       | Meaning                                                                             |
| ------------ | ----------------------------------------------------------------------------------- |
| `pass`       | Every required invariant passed and no environmental gate remains.                  |
| `fail`       | At least one concrete invariant failed.                                             |
| `incomplete` | Evidence or a declared environmental gate prevents a reliable pass/fail conclusion. |

Linux evidence never silently converts a physical Mac/iPhone gate into a pass.

## Typed Recovery

Recovery episodes carry immutable owner and root trace identity, one closed cause, one legal outcome, bounded redacted detail, optional error code, timing, and confined evidence references. Integrated terminal fault paths include:

- agent restart and verified stale-process recovery;
- Appium crash;
- three consecutive WDA health failures;
- BiDi disconnect;
- lease expiry;
- evidence export failure/corruption;
- device or transport loss as classified by the live controller.

Fault-injection tests verify state transition legality, terminal outcomes, queue/device release, root continuity, log evidence, and analytics visibility.

## Schema Migration

Both job and live SQLite stores use transactional schema-v2 migration. Connections set `sqlite3.Row` before migration, so named `PRAGMA table_info` access is valid. Real v1 fixtures verify:

- new trace/evidence/recovery columns and tables;
- deterministic root and operation trace backfill;
- event and artifact enrichment;
- trace indexes;
- schema version update;
- backward-compatible row decoding;
- idempotent reopen.

An independent audit initially alleged tuple row access; the full re-audit confirmed this was a false positive because both connection factories install the row factory before initialization.

## Authenticated API

All routes remain bearer-authenticated and loopback-bound under `/api/v1`.

| Route                                   | Purpose                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------- |
| `GET /traces`                           | Bounded owner/status/time-filtered trace index with pagination.                 |
| `GET /traces/{trace}`                   | Unified owner, events, recoveries, artifacts, analytics, and evidence metadata. |
| `GET /traces/{trace}/events`            | Bounded correlated timeline.                                                    |
| `GET /traces/{trace}/analytics`         | Invariant and qualification document.                                           |
| `GET /traces/{trace}/recoveries`        | Recovery history for one root.                                                  |
| `GET /traces/{trace}/evidence`          | Evidence metadata.                                                              |
| `POST /traces/{trace}/evidence`         | Deterministic export.                                                           |
| `GET /traces/{trace}/evidence/download` | Confined, size/hash-verified binary bundle.                                     |
| `GET /recovery`                         | Bounded root/owner/cause/outcome-filtered recovery index.                       |
| `GET /recovery/{recovery}`              | One typed recovery episode.                                                     |

The existing job, live-session, Appium, AI-tool, observation, action, event, artifact, and SSE routes remain intact.

## Operator CLI

Phase 10 adds or completes:

- `trace-index`
- `trace`
- `trace-events`
- `trace-analytics`
- `trace-recoveries`
- `trace-export`
- `trace-download`
- `recovery-list`
- `recovery-show`

The CLI preserves bearer-token secrecy, lease-token file/environment handling, bounded JSON decoding, resumable SSE, deterministic errors, and no arbitrary command surface.

## Real Appium/BiDi Proof

The exact pinned private runtime was started in the sandbox with the current plugin:

- Node 20.19.5
- Appium 3.6.0
- XCUITest 12.1.4 loaded
- official fake driver 6.2.2 loaded for hardware-independent protocol execution
- `faceswap-live` 1.0.0 active

The real WebDriver BiDi verifier created an authorized session, subscribed to custom events, requested the plugin schema, executed a live action, received the result and custom event, and deleted the session. The saved result proves:

- session root `22222222-2222-4222-8222-222222222222`;
- normalized W3C session parent;
- operation UUID `11111111-1111-4111-8111-111111111111`;
- generated child span;
- operation traceparent with the session root;
- matching custom event correlation.

See `phase-10-appium-bidi-trace-smoke.json`.

## Verification Results

| Gate                                    |                               Result |
| --------------------------------------- | -----------------------------------: |
| Python tests                            |                       **138 passed** |
| Appium plugin Node tests                |                        **16 passed** |
| Phase 10 static validator               |                             **PASS** |
| Swift source syntax baseline comparison |                  **146 files, PASS** |
| Interactive SwiftUI files               |                       **23 covered** |
| Accessibility patterns                  |                              **293** |
| Literal identifiers                     |                              **245** |
| Required identifiers                    |                               **59** |
| Persistent probes                       |                               **14** |
| UI scenarios                            | **8 scenario tests + 1 launch test** |
| Run modes                               |                **simulator + cable** |
| Built-in fixtures                       |         **profile + media sequence** |
| Xcode project parser                    |        **PASS; 4 QA configurations** |
| QA test-plan JSON                       |                             **PASS** |
| Shared QA scheme XML                    |                             **PASS** |
| Git diff integrity                      |                             **PASS** |
| Real Appium HTTP/BiDi trace smoke       |                             **PASS** |

The Python suite covers analytics, API, Appium manager, WebDriver, MJPEG, BiDi protocol and concurrency, CLI and installer, discovery, deterministic evidence, subprocess simulator/cable integration, JSON bounds, live control, persistence and exclusivity, recovery, redaction, runner behavior, v1→v2 migration, process recovery, trace context, trace service, and terminal evidence export.

## Independent Audit Closure

Phase 10 used parallel agents for architecture, implementation candidates, and closure audits. The principal closure sequence included:

- 12 independent architecture workstreams;
- 10 independent implementation workstreams integrated centrally;
- 10 broad closure audits;
- 5 full-package focused re-audits;
- 3 descriptor-hardening and holistic final audits.

The broad audit found one real completeness gap—the missing trace/recovery indexes, evidence download route, and matching CLI commands—which was implemented and tested. Two findings were rejected with evidence: the SQLite row-factory allegation and missing iOS files in a deliberately focused audit archive. A focused audit requested explicit `fstat` descriptor checks; these were accepted as defense in depth, implemented, tested, and re-audited.

The final three independent audits returned two `PASS` and one `PASS_WITH_MACOS_GATES`, all with zero code-level blockers and confidence 1.0.

See `phase-10-closure-audit-triage.md` and the preserved raw audit JSON/CSV files.

## Safeguard Change Control

The final mixed-language inventory and scans were analysis-only. No safeguard removal was requested or performed. Retained controls include:

- loopback bearer authentication and private token storage;
- hashed live leases;
- exact QA bundle and live capability gates;
- closed action/observation schemas with no arbitrary shell or mobile command execution;
- immutable root and fail-closed trace mismatch handling;
- bounded JSON, messages, observations, requests, responses, and event history;
- device ownership transactions and process ownership checks;
- cable/iOS-version restrictions for RemoteXPC;
- WDA, Appium, and BiDi health monitoring;
- path confinement, symlink rejection, private temporary descriptors, and atomic output;
- recursive secret redaction and hash-only text/command summaries;
- typed recovery and automatic evidence.

The inventory, generic findings, specialized plugin findings, and summary are preserved in `phase-10-safeguard-*.json`, `phase-10-plugin-safeguard-findings.json`, and `phase-10-safeguard-summary.md`.

## Remaining Environmental Gates

The following require the authorized target Mac and iPhone:

1. LaunchAgent installation, login-session lifecycle, restart, and upgrade rollback.
2. Real Apple signing, Developer Mode, trust, and explicit-UDID readiness.
3. Physical WDA build/launch, reuse, and optional preinstalled identity.
4. Real device MJPEG and screenshot fallback behavior.
5. Physical BiDi context/log events.
6. iOS 18+ RemoteXPC network samples.
7. Cable disconnect/reconnect, trust loss, WDA loss, and Appium process failure on hardware.
8. Real simulator and cable XCUITest execution in Xcode.
9. Physical trace continuity through app result and final artifact manifest.
10. Deterministic repeat export from unchanged physical-run artifacts.

Exact commands and acceptance criteria are in `phase-10-macos-iphone-qualification-runbook.md`.

## Closure

Phase 10 is code-complete and independently closed in the available environment. No reproducible code-level blocker remains. The next implementation phase may proceed while the documented target-Mac/iPhone qualification remains an explicit external gate.
