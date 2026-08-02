# FaceSwap QA Operator Dashboard Architecture

## Purpose and Trust Boundary

The dashboard is an authenticated control plane for the existing FaceSwap QA Mac agent. The browser never receives the Mac-agent bearer token, GitHub administrator credentials, evidence signing material, or raw configuration. Every operator read and mutation is routed through an owner-only server procedure, which validates the Manus OAuth identity, activation policy, operation input, and current quarantine state before accessing the agent gateway.

> **Fail-closed invariant:** an unknown, stale, unreachable, incomplete, or failing activation check is a failure. Device, job, live-session, evidence, and quarantine mutations remain blocked until every required policy check passes.

| Boundary         | Responsibility                                                                                                       | Forbidden behavior                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Browser          | Render typed state, poll owner-only queries, submit closed mutations, display verified evidence links                | Agent credentials, direct Mac-agent calls, client-trusted policy decisions, unverified artifact links |
| Dashboard server | OAuth/owner enforcement, fail-closed policy evaluation, bounded agent calls, SHA-256 verification, audit persistence | Trusting browser role claims, forwarding arbitrary URLs or commands, surfacing unverifiable bytes     |
| Database         | Durable operator audit trail, normalized snapshots, submission metadata, evidence verification state                 | File bytes, bearer tokens, raw secrets, mutable authorization decisions                               |
| Object storage   | Verified evidence bytes and screenshot observations                                                                  | Unverified or hash-mismatched content                                                                 |
| Mac agent        | Device discovery, exclusive ownership, Xcode/Appium/WDA execution, trace/evidence generation, quarantine             | Public unauthenticated access, arbitrary shell execution, bypassing activation policy                 |

## Connectivity Modes

The server gateway supports a single typed interface with three runtime modes. `direct` calls a configured private HTTPS Mac-agent endpoint using a server-only bearer token. `relay` reads commands and snapshots exchanged by an outbound Mac bridge through the dashboard control plane. `unconfigured` returns a truthful unavailable snapshot and blocks every mutation. No mode silently falls back to fabricated device state.

The initial managed deployment uses request-scoped polling. Device overview, active job, and live-session queries refresh every two to five seconds while visible; traces and policy refresh less frequently. Durable state resides in the database, so the dashboard remains compatible with stateless autoscaling. An always-on reserved process is not required for the initial polling model.

## Authorization Model

Manus OAuth remains the only login mechanism. The server uses an owner-only procedure that requires both `role === "admin"` and `openId === OWNER_OPEN_ID`. The application exposes no role-management or promotion procedure. Non-owner authenticated users receive a forbidden response and an inert access-denied screen.

| Operation class               | Required conditions                                                                                         |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Read dashboard telemetry      | Authenticated owner; gateway calls are bounded and server-side                                              |
| Submit or cancel job          | Owner; activation open; not quarantined; exact ready device; valid scenario/UDID/retries/idempotency key    |
| Start or control live session | Owner; activation open; not quarantined; exclusive device ownership; allowlisted action schema              |
| Browse or download evidence   | Owner; activation open; artifact inventory present; server-computed SHA-256 matches expected digest         |
| Set quarantine                | Owner; activation open; allowlisted mode; bounded reason                                                    |
| Clear quarantine              | Owner; activation open; exact acknowledgement; agent idle; queue empty; no live session; exact device ready |

## Persistence Model

The database records operator audit events, dashboard job submissions, live-session metadata, policy snapshots, quarantine history, and evidence verification metadata. Business timestamps are stored as UTC milliseconds. Binary evidence is stored in object storage only after server-side hash verification; the database stores the key, size, media type, expected digest, computed digest, and verification timestamp.

## Real-Time Model

The UI uses bounded live polling rather than static snapshots. Overview state refreshes every three seconds, job detail and log tail every two seconds while nonterminal, live sessions and BiDi streams every two seconds while active, and policy/traces every fifteen seconds. Polling pauses when a panel is hidden or the browser tab is backgrounded and resumes with an immediate refresh. All responses carry `observedAt` or `updatedAt` timestamps so the UI can identify stale data.

## Evidence Verification

Every artifact is downloaded by the dashboard server with a byte ceiling and timeout, hashed with SHA-256 over the exact received bytes, and rejected on any size or digest mismatch. Only verified bytes are uploaded to object storage and only verified records receive download URLs. A sanitized evidence summary and inventory are rendered separately from binary downloads.

## Visual System

The design uses a near-black indigo surface, cyan primary telemetry, violet secondary accents, amber warnings, and red fail-closed states. Status is conveyed through text and icons as well as color. Headings use a geometric sans face; telemetry, identifiers, traces, UDIDs, hashes, logs, and timestamps use a monospace face. Soft inner glows and scan-line texture establish the cyberpunk operator character without reducing readability.

| Token           | Intent                                                       |
| --------------- | ------------------------------------------------------------ |
| `--background`  | Deep blue-black command surface                              |
| `--card`        | Slightly raised indigo panel with cyan edge illumination     |
| `--primary`     | Electric cyan operator action and healthy state              |
| `--accent`      | Ultraviolet secondary selection and trace context            |
| `--warning`     | Amber degraded, pending, or external-gate state              |
| `--destructive` | Red policy failure, quarantine, cancellation, or agent fault |

Animations are limited to opacity and transform, remain under 300 milliseconds, and respect reduced-motion preferences. Live pulses are supplemental; all state changes remain visible as labels and timestamps.

## Code-Verifiable Acceptance Contract

The implementation is complete only when the TODO history shows every requirement as complete; database migrations are applied; every operator procedure is owner-gated; blocked policy prevents every protected mutation; job and session panels poll live state; idempotency is always visible; quarantine clear requires the exact shared string; evidence links exist only for server-verified SHA-256 matches; TypeScript, Vitest, production build, browser console, network, desktop/mobile screenshots, keyboard focus, and contrast checks pass; and a single final checkpoint is created.
