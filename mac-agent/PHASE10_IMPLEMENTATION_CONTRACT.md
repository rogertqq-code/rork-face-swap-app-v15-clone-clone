# Phase 10 Implementation Contract

## Goal and compatibility boundary

Phase 10 extends the existing Phase 8–9 system without creating another queue, device owner, Appium server, evidence root, or remote command surface. `AgentService`, `JobStore`, `LiveStore`, `LiveControlManager`, the managed Appium/WDA runtime, and the QA-only iOS router remain the owners of their current lifecycles.

The implementation adds a globally correlated session trace, deterministic evidence bundles, machine-readable analytics, typed recovery episodes, bounded trace/evidence API and CLI surfaces, and a QA-only iOS trace bridge. Existing job and live endpoints remain backward compatible: callers may omit new trace fields, in which case the agent generates them.

## Identity model

| Identity | Format | Authority | Purpose |
|---|---|---|---|
| `run_id` | canonical UUID | existing job/session manifest | Operator-visible logical run identity retained for compatibility. |
| `session_trace_id` | canonical UUID | Mac agent | Root correlation identity for one queued job or live session. |
| `operation_trace_id` | canonical UUID | caller or Mac agent | Existing action/observation trace identity; defaults to a new UUID and is linked to the session trace. |
| `span_id` | 16 lowercase hexadecimal characters | Mac agent/plugin/iOS bridge | One operation or lifecycle span. |
| `traceparent` | W3C version `00`, 32-hex root trace, 16-hex span, sampled flag `01` | derived | Cross-process propagation through API, Appium capability, plugin, BiDi, QA command, and logs. |
| `bundle_id` | canonical UUID | evidence builder | One immutable exported evidence package. |
| `recovery_id` | canonical UUID | recovery recorder | One failure detection and recovery episode. |

A UUID is converted to the 32-hex W3C trace field by removing hyphens. The agent rejects all-zero trace or span fields, malformed `traceparent`, mismatched explicit session trace IDs, and attempts to change a session trace after creation. Incoming `traceparent` is optional. When present, its root trace becomes `session_trace_id`; otherwise an explicit `trace_id` or generated UUID is used. Every response returns the normalized root trace.

Actions and observations keep their existing `trace_id` fields for compatibility; these are `operation_trace_id` values. Stored events and evidence metadata contain both `session_trace_id` and `operation_trace_id`. SSE keeps `trace_id` as the operation field and adds `session_trace_id` and `span_id`.

## Persistence and schema versions

`JobStore` migrates from schema 1 to schema 2, and `LiveStore` migrates from live schema 1 to 2. Migration is transactional, idempotent, and preserves existing rows.

### Queued jobs

`jobs` gains `session_trace_id TEXT NOT NULL`; legacy rows derive it from the serialized `run_id`. `events` gains nullable `session_trace_id`, `operation_trace_id`, and `span_id`. `artifacts` gains nullable `session_trace_id`, `operation_trace_id`, `content_type`, and `provenance`.

### Live sessions

`live_sessions` gains `session_trace_id TEXT NOT NULL` and recovery bookkeeping fields that do not duplicate managed process ownership. `live_events` gains `session_trace_id TEXT NOT NULL`, keeps current `trace_id` as `operation_trace_id`, and gains nullable `span_id`. `live_artifacts` gains root/operation trace, content type, provenance, and redaction state. A new `recovery_episodes` table stores typed detection, attempt, outcome, evidence, and bounded diagnostic details.

Existing monotonic SQLite event IDs remain the SSE replay authority. Wall-clock timestamps remain UTC epoch values for cross-system timelines; a per-process monotonic offset and sequence are recorded where deterministic ordering is needed. Monotonic values are never compared across process restarts.

## Appium, WDA, BiDi, MJPEG, and iOS propagation

Every Appium session receives:

- `appium:faceswapTraceId`: session root UUID;
- `appium:faceswapTraceparent`: normalized W3C traceparent;
- existing `faceswap:liveControl=true` and exact QA bundle gate.

The local plugin requires those values for agent-owned live sessions, emits them in custom HTTP and BiDi results, and includes `session_trace_id`, `trace_id`, `span_id`, and `traceparent` in every custom event. The plugin does not attempt to modify WDA itself or add arbitrary mobile commands.

BiDi event persistence validates the session root. A missing operation ID is generated; a mismatched session root produces a typed correlation warning event and never rewrites the session root. MJPEG frames are associated in local metadata only; JPEG bytes are not mutated. Frame metadata contains sequence, capture time, dimensions, SHA-256, session root, and current operation when available.

The iOS QA command envelope is version 2 and adds optional `traceID`, `rootTraceID`, `spanID`, and `traceparent`. The decoder remains backward compatible with version 1. Results echo normalized trace fields. All additions remain inside `#if QA_AUTOMATION`; Release sources and build settings remain free of QA symbols.

The QA runtime publishes current root/operation trace probes. The router records one trace-aware lifecycle event per command. Evidence export writes a QA evidence manifest with command result, telemetry export, diagnostics report, and connection log paths. Production telemetry structures are not globally changed; QA-only export wrappers add correlation metadata so Release behavior and ABI remain unchanged.

## Unified evidence model

`evidence.py` owns evidence metadata and deterministic export. Each manifest uses `schema_version: 1` and contains:

- bundle identity and owner (`job` or `live_session`);
- run, session, root trace, creation, closure, status, target, and version information;
- sorted trace timeline entries and recovery episodes;
- sorted artifact records with confined relative path, kind, content type, byte size, SHA-256, timestamps, provenance, redaction state, root/operation trace, and optional span;
- aggregate analytics and invariant results;
- explicit `complete`, `partial`, or `corrupt` evidence status plus reasons.

Artifact paths must be regular files contained under the configured artifacts root, cannot be symlinks, and are exported with POSIX relative paths. Export uses sorted paths, fixed tar owner/group/mode/mtime values, a gzip header timestamp of zero, and atomic temporary-file rename. Two exports from unchanged inputs must have identical SHA-256 values.

Before export, each artifact is rehashed. A mismatch marks the bundle `corrupt`, records the expected and observed hash without exporting untrusted bytes, and fails the qualification invariant. Startup or teardown failures still produce a partial bundle containing all durable events and available logs.

## Redaction and evidence classes

`redaction.py` centralizes bounded structured and text redaction. Identifiers required for correlation (`run_id`, `session_id`, `job_id`, `session_trace_id`, `trace_id`, `operation_trace_id`, `span_id`, `bundle_id`, `recovery_id`) pass through. Sensitive key names, authorization values, cookies, credentials, passwords, tokens, secrets, API keys, private keys, and configured patterns are replaced with size and SHA-256 metadata.

Raw text is line-bounded and removes bearer tokens, cookie values, common credential assignments, and configured patterns before persistence. Unknown network bodies and headers are metadata-only by default. Screenshots, source trees, syslog, network samples, and raw logs are explicit evidence classes with operator policy; their raw bytes are never embedded in SSE or analytics. SSE carries metadata, summaries, hashes, and relative evidence references only.

## Recovery state machine

`recovery.py` defines typed causes and outcomes. Causes include `agent_restarted`, `appium_crashed`, `wda_unhealthy`, `device_disconnected`, `trust_lost`, `developer_mode_lost`, `bidi_disconnected`, `mjpeg_disconnected`, `lease_expired`, `stale_process`, and `evidence_corrupt`. Outcomes are `observed`, `recovered`, `degraded`, `failed`, or `cancelled`.

The watchdog records a recovery episode before acting. Appium and WDA failures remain terminal for the affected live session after bounded final evidence capture. BiDi and MJPEG each receive a bounded reconnect attempt before degradation; failure of the control channel remains terminal, while MJPEG failure may degrade to regular screenshots. Cable readiness is rechecked through the existing discovery service; trust or Developer Mode loss produces a specific typed cause. Lease expiry remains terminal. Startup recovery marks nonterminal sessions failed while preserving root trace and partial evidence.

No recovery path silently replaces an active lease, changes the session root, adopts an unknown Appium process, starts a second device owner, or continues after artifact confinement/hash failure.

## Analytics and qualification result

`analytics.py` reconstructs a deterministic timeline by `(timestamp, source_priority, sequence, event_id)`. It computes action/observation latency count, minimum, maximum, p50, p90, and p99 using a documented nearest-rank method; errors by component/code; event and artifact counts; recovery cause/outcome counts and recovery latency; evidence completeness; and invariant checks.

Required invariants include root-trace continuity, monotonic per-source sequences, no artifact hash mismatch, no unclosed recovery episode, no plaintext secret marker in summaries, one active device owner, command result correlation, and terminal evidence generation. The machine-readable qualification status is `pass`, `fail`, or `incomplete`. `incomplete` is used for environmental gates or missing physical evidence, never silently converted to pass.

## API, SSE, and CLI

All routes remain under authenticated loopback `/api/v1` and use existing bounded JSON and query parsing.

| Route | Purpose |
|---|---|
| `GET /traces` | Bounded root-trace index with owner, status, time, and pagination filters. |
| `GET /traces/{trace_id}` | Unified trace summary and owner links. |
| `GET /traces/{trace_id}/events` | Bounded merged event timeline. |
| `GET /traces/{trace_id}/analytics` | Deterministic analytics and qualification result. |
| `GET /traces/{trace_id}/evidence` | Evidence manifest metadata and artifacts. |
| `POST /traces/{trace_id}/evidence/export` | Idempotent deterministic bundle export. |
| `GET /traces/{trace_id}/evidence/download` | Confined bundle download with content length and SHA-256. |
| `GET /recovery` | Bounded recovery episode index. |
| `GET /recovery/{recovery_id}` | One typed recovery episode. |
| existing session SSE | Adds root trace, span, recovery, evidence, and qualification events without changing replay IDs. |

CLI commands mirror trace index/show/events/analytics/evidence/export/download and recovery list/show. Lease credentials remain file/environment-only. Bundle download writes atomically, validates advertised length and SHA-256, and refuses symlink destinations.

## Tests and qualification

Linux tests cover schema migration, traceparent parsing, explicit/generated IDs, cross-boundary propagation, plugin events, iOS source contracts, SSE correlation, concurrent operations, deterministic export, path/symlink confinement, artifact corruption, redaction, recovery fault injection, restart continuity, bounded reconnect, analytics percentiles/invariants, API pagination/download, CLI atomic output, retention, and deterministic clocks.

The static validator requires the Phase 10 modules, schema versions, Appium capabilities, plugin fields, QA-only trace fields, API routes, CLI commands, recovery causes, evidence manifest, redaction boundary, analytics invariants, and minimum test breadth. Safeguard inventory is refreshed after implementation; no safeguard removal occurs.

The target Mac/iPhone gate verifies launchd restart, WDA signing/reuse/preinstalled identity, physical Appium, BiDi logs/context, MJPEG frames, RemoteXPC network samples, disconnect/reconnect classification, trust/Developer Mode loss, partial evidence, deterministic export, and trace continuity from API through iOS result and artifact manifest.
