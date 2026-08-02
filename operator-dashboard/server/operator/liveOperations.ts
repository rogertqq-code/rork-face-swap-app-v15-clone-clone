import { createHash } from "node:crypto";
import type {
  EvidenceArtifact,
  LiveActionKind,
  LiveObservationKind,
  LiveOperationReceipt,
  VerifiedScreenshot,
} from "../../shared/operator";
import { storagePut } from "../storage";
import { AgentGateway, asOptionalString, asRecord } from "./agentGateway";
import { persistedEvidenceInventory } from "./evidence";
import { openLiveLease, sealLiveLease } from "./leaseVault";
import {
  getOwnedLiveSession,
  storeLiveSessionLease,
  upsertEvidenceArtifact,
} from "./persistence";

const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const MAX_SCREENSHOT_BYTES = 24 * 1024 * 1024;

export class LiveOperationError extends Error {
  constructor(
    public readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "LiveOperationError";
  }
}

export async function bindLiveLease(
  ownerUserId: number,
  sessionId: string,
  leaseToken: string
) {
  await storeLiveSessionLease(
    ownerUserId,
    sessionId,
    sealLiveLease(sessionId, leaseToken)
  );
}

export async function executeGuardedLiveAction(input: {
  gateway: AgentGateway;
  ownerUserId: number;
  sessionId: string;
  kind: LiveActionKind;
  command?: Record<string, unknown>;
}): Promise<LiveOperationReceipt> {
  const { leaseToken } = await liveCredential(
    input.ownerUserId,
    input.sessionId
  );
  const parameters =
    input.kind === "qa_command" ? { command: input.command ?? {} } : {};
  const raw = await input.gateway.request<unknown>(
    "POST",
    `/api/v1/live/sessions/${encodeURIComponent(input.sessionId)}/actions`,
    {
      leaseToken,
      timeoutMs: 120_000,
      body: {
        kind: input.kind,
        parameters,
        trace_id: crypto.randomUUID(),
      },
    }
  );
  return receipt(input.kind, asRecord(asRecord(raw).result));
}

export async function captureGuardedLiveObservation(input: {
  gateway: AgentGateway;
  ownerUserId: number;
  sessionId: string;
  kind: LiveObservationKind;
}): Promise<{
  receipt: LiveOperationReceipt;
  screenshot: VerifiedScreenshot | null;
}> {
  const { leaseToken, session } = await liveCredential(
    input.ownerUserId,
    input.sessionId
  );
  const raw = await input.gateway.request<unknown>(
    "POST",
    `/api/v1/live/sessions/${encodeURIComponent(input.sessionId)}/observations`,
    {
      leaseToken,
      timeoutMs: 120_000,
      maximumBytes: MAX_SCREENSHOT_BYTES + 2 * 1024 * 1024,
      body: {
        kind: input.kind,
        persist: true,
        trace_id: crypto.randomUUID(),
      },
    }
  );
  const document = asRecord(asRecord(raw).observation);
  const operationReceipt = receipt(input.kind, document);
  const screenshot =
    input.kind === "screenshot"
      ? await verifyAndStoreScreenshot({
          ownerUserId: input.ownerUserId,
          sessionTraceId: session.sessionTraceId,
          document,
        })
      : null;
  return { receipt: operationReceipt, screenshot };
}

export async function latestVerifiedScreenshot(
  ownerUserId: number,
  sessionId: string
) {
  const session = await getOwnedLiveSession(ownerUserId, sessionId);
  if (!session)
    throw new LiveOperationError(
      "session_not_found",
      "Live session not found."
    );
  const inventory = await persistedEvidenceInventory(
    ownerUserId,
    session.sessionTraceId
  );
  const artifact = selectLatestVerifiedScreenshot(inventory);
  if (!artifact?.downloadUrl) return null;
  return {
    artifactId: artifact.id,
    traceId: artifact.traceId,
    sha256: artifact.sha256,
    sizeBytes: artifact.sizeBytes,
    mediaType: artifact.mediaType,
    capturedAt: artifact.createdAt,
    verified: true as const,
    downloadUrl: artifact.downloadUrl,
  };
}

export function selectLatestVerifiedScreenshot(inventory: EvidenceArtifact[]) {
  return (
    inventory
      .filter(
        item =>
          item.kind === "live-screenshot" &&
          item.verified &&
          Boolean(item.downloadUrl) &&
          item.mediaType.startsWith("image/")
      )
      .sort(
        (left, right) =>
          right.createdAt - left.createdAt || right.id.localeCompare(left.id)
      )[0] ?? null
  );
}

async function liveCredential(ownerUserId: number, sessionId: string) {
  const session = await getOwnedLiveSession(ownerUserId, sessionId);
  if (!session)
    throw new LiveOperationError(
      "session_not_found",
      "Live session not found."
    );
  if (!["starting", "active", "recovering"].includes(session.state)) {
    throw new LiveOperationError(
      "session_not_active",
      "Live session is not available for remote control."
    );
  }
  if (!session.leaseCiphertext) {
    throw new LiveOperationError(
      "session_lease_unavailable",
      "Live session credential is unavailable; open a new guarded session."
    );
  }
  return {
    session,
    leaseToken: openLiveLease(sessionId, session.leaseCiphertext),
  };
}

function receipt(
  kind: LiveActionKind | LiveObservationKind,
  document: Record<string, unknown>
): LiveOperationReceipt {
  return {
    kind,
    operationTraceId:
      asOptionalString(document.operation_trace_id) ??
      asOptionalString(document.trace_id) ??
      crypto.randomUUID(),
    success:
      document.success !== false && !asOptionalString(document.error_code),
    elapsedMs: finiteNumber(document.elapsed_ms),
    errorCode: asOptionalString(document.error_code),
    errorMessage: asOptionalString(document.error_message),
  };
}

async function verifyAndStoreScreenshot(input: {
  ownerUserId: number;
  sessionTraceId: string;
  document: Record<string, unknown>;
}): Promise<VerifiedScreenshot> {
  const value = asRecord(input.document.value);
  const mediaType = asOptionalString(value.content_type);
  const encoded = asOptionalString(value.base64);
  const expectedSha256 = (
    asOptionalString(value.sha256) ??
    asOptionalString(input.document.sha256) ??
    ""
  ).toLowerCase();
  if (
    !encoded ||
    !mediaType ||
    !["image/png", "image/jpeg"].includes(mediaType) ||
    !SHA256_PATTERN.test(expectedSha256)
  ) {
    throw new LiveOperationError(
      "screenshot_document_invalid",
      "Mac agent returned an invalid screenshot observation."
    );
  }
  let bytes: Buffer;
  try {
    bytes = Buffer.from(encoded, "base64");
  } catch {
    throw new LiveOperationError(
      "screenshot_base64_invalid",
      "Screenshot bytes are not valid base64."
    );
  }
  if (!bytes.length || bytes.length > MAX_SCREENSHOT_BYTES) {
    throw new LiveOperationError(
      "screenshot_size_invalid",
      "Screenshot bytes are empty or exceed the dashboard limit."
    );
  }
  const observedSha256 = createHash("sha256").update(bytes).digest("hex");
  if (observedSha256 !== expectedSha256) {
    throw new LiveOperationError(
      "screenshot_hash_mismatch",
      "Screenshot SHA-256 verification failed."
    );
  }
  const operationTraceId =
    asOptionalString(input.document.operation_trace_id) ??
    asOptionalString(input.document.trace_id) ??
    crypto.randomUUID();
  const capturedAt = timestampMs(input.document.captured_at) ?? Date.now();
  const extension = mediaType === "image/jpeg" ? "jpg" : "png";
  const artifactId = crypto.randomUUID();
  const stored = await storagePut(
    `operator-live/${input.sessionTraceId}/${artifactId}.${extension}`,
    bytes,
    mediaType
  );
  await upsertEvidenceArtifact(
    {
      id: artifactId,
      traceId: input.sessionTraceId,
      name: `verified-live-screenshot-${capturedAt}.${extension}`,
      kind: "live-screenshot",
      sizeBytes: bytes.length,
      sha256: observedSha256,
      mediaType,
      verified: true,
      verificationError: null,
      sanitized: false,
      createdAt: capturedAt,
      downloadUrl: stored.url,
    },
    input.ownerUserId,
    stored.key,
    observedSha256
  );
  return {
    artifactId,
    traceId: input.sessionTraceId,
    sha256: observedSha256,
    sizeBytes: bytes.length,
    mediaType,
    capturedAt,
    verified: true,
    downloadUrl: stored.url,
  };
}

function finiteNumber(value: unknown) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function timestampMs(value: unknown) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return null;
  return number < 10_000_000_000
    ? Math.round(number * 1000)
    : Math.round(number);
}
