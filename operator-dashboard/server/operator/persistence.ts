import { and, desc, eq } from "drizzle-orm";
import {
  operatorAuditEvents,
  operatorEvidenceArtifacts,
  operatorEvidenceBundles,
  operatorJobs,
  operatorLiveSessions,
  operatorPolicySnapshots,
  operatorQuarantineEvents,
  type InsertOperatorEvidenceArtifact,
  type InsertOperatorEvidenceBundle,
  type InsertOperatorJob,
  type InsertOperatorLiveSession,
} from "../../drizzle/schema";
import type {
  ActivationGate,
  EvidenceArtifact,
  JobRecord,
  LiveSession,
  QuarantineMode,
} from "../../shared/operator";
import { getDb } from "../db";

export class OperatorPersistenceError extends Error {}

async function database() {
  const db = await getDb();
  if (!db)
    throw new OperatorPersistenceError("Operator database is unavailable.");
  return db;
}

export async function findJobByIdempotencyKey(key: string) {
  const db = await database();
  const [job] = await db
    .select()
    .from(operatorJobs)
    .where(eq(operatorJobs.idempotencyKey, key))
    .limit(1);
  return job ? mapPersistedJob(job) : null;
}

export async function insertOperatorJob(job: JobRecord, ownerUserId: number) {
  const db = await database();
  const values: InsertOperatorJob = {
    id: job.id,
    ownerUserId,
    agentJobId: null,
    scenario: job.scenario,
    deviceUdid: job.deviceUdid,
    idempotencyKey: job.idempotencyKey,
    retryCount: job.retryCount,
    attempt: job.attempt,
    status: job.status,
    phase: job.phase,
    traceId: job.traceId,
    errorCode: job.errorCode,
    errorMessage: job.errorMessage,
    createdAtMs: job.createdAt,
    startedAtMs: job.startedAt,
    finishedAtMs: job.finishedAt,
    updatedAtMs: job.updatedAt,
  };
  await db.insert(operatorJobs).values(values);
}

export async function updateOperatorJob(
  localId: string,
  job: JobRecord,
  agentJobId?: string
) {
  const db = await database();
  await db
    .update(operatorJobs)
    .set({
      agentJobId,
      attempt: job.attempt,
      status: job.status,
      phase: job.phase,
      traceId: job.traceId,
      errorCode: job.errorCode,
      errorMessage: job.errorMessage,
      startedAtMs: job.startedAt,
      finishedAtMs: job.finishedAt,
      updatedAtMs: job.updatedAt,
    })
    .where(eq(operatorJobs.id, localId));
}

export async function listOperatorJobs(ownerUserId: number, limit = 30) {
  const db = await database();
  const rows = await db
    .select()
    .from(operatorJobs)
    .where(eq(operatorJobs.ownerUserId, ownerUserId))
    .orderBy(desc(operatorJobs.updatedAtMs))
    .limit(Math.min(100, Math.max(1, limit)));
  return rows.map(mapPersistedJob);
}

export async function getOperatorJob(ownerUserId: number, id: string) {
  const db = await database();
  const [row] = await db
    .select()
    .from(operatorJobs)
    .where(
      and(eq(operatorJobs.ownerUserId, ownerUserId), eq(operatorJobs.id, id))
    )
    .limit(1);
  return row ? mapPersistedJob(row) : null;
}

export async function upsertLiveSession(
  session: LiveSession,
  ownerUserId: number
) {
  const db = await database();
  const values: InsertOperatorLiveSession = {
    id: session.id,
    ownerUserId,
    deviceUdid: session.deviceUdid,
    state: session.state,
    bidiConnected: session.bidiConnected,
    appiumSessionId: session.appiumSessionId,
    sessionTraceId: session.sessionTraceId,
    traceparent: session.traceparent,
    startedAtMs: session.startedAt,
    expiresAtMs: session.expiresAt,
    lastHeartbeatAtMs: session.lastHeartbeatAt,
    closedAtMs: ["closed", "failed"].includes(session.state)
      ? Date.now()
      : null,
    updatedAtMs: Date.now(),
  };
  await db
    .insert(operatorLiveSessions)
    .values(values)
    .onDuplicateKeyUpdate({
      set: {
        state: values.state,
        bidiConnected: values.bidiConnected,
        appiumSessionId: values.appiumSessionId,
        expiresAtMs: values.expiresAtMs,
        lastHeartbeatAtMs: values.lastHeartbeatAtMs,
        closedAtMs: values.closedAtMs,
        updatedAtMs: values.updatedAtMs,
      },
    });
}

export async function storeLiveSessionLease(
  ownerUserId: number,
  sessionId: string,
  leaseCiphertext: string
) {
  const db = await database();
  await db
    .update(operatorLiveSessions)
    .set({ leaseCiphertext, updatedAtMs: Date.now() })
    .where(
      and(
        eq(operatorLiveSessions.ownerUserId, ownerUserId),
        eq(operatorLiveSessions.id, sessionId)
      )
    );
}

export async function getOwnedLiveSession(
  ownerUserId: number,
  sessionId: string
) {
  const db = await database();
  const [row] = await db
    .select()
    .from(operatorLiveSessions)
    .where(
      and(
        eq(operatorLiveSessions.ownerUserId, ownerUserId),
        eq(operatorLiveSessions.id, sessionId)
      )
    )
    .limit(1);
  return row ?? null;
}

export async function recordPolicySnapshot(
  ownerUserId: number,
  gate: ActivationGate
) {
  const db = await database();
  await db.insert(operatorPolicySnapshots).values({
    id: crypto.randomUUID(),
    ownerUserId,
    gateState: gate.state,
    repository: gate.repository,
    repositoryPrivate: gate.repositoryPrivate,
    summary: gate.summary,
    failedChecksJson: JSON.stringify(gate.failedChecks),
    checksJson: JSON.stringify(gate.checks),
    checkedAtMs: gate.checkedAt,
    createdAtMs: Date.now(),
  });
}

export async function recordAudit(input: {
  ownerUserId: number;
  action: string;
  resourceType: string;
  resourceId?: string | null;
  outcome: "success" | "blocked" | "failure";
  traceId?: string | null;
  detail?: Record<string, unknown>;
}) {
  const db = await database();
  await db.insert(operatorAuditEvents).values({
    id: crypto.randomUUID(),
    ownerUserId: input.ownerUserId,
    action: input.action,
    resourceType: input.resourceType,
    resourceId: input.resourceId ?? null,
    outcome: input.outcome,
    traceId: input.traceId ?? null,
    detailJson: JSON.stringify(input.detail ?? {}),
    createdAtMs: Date.now(),
  });
}

export async function recordQuarantine(input: {
  ownerUserId: number;
  action: "set" | "clear";
  mode?: QuarantineMode | null;
  reason?: string | null;
  deviceUdid?: string | null;
  acknowledgementMatched: boolean;
  agentConfirmed: boolean;
}) {
  const db = await database();
  await db.insert(operatorQuarantineEvents).values({
    id: crypto.randomUUID(),
    ownerUserId: input.ownerUserId,
    action: input.action,
    mode: input.mode ?? null,
    reason: input.reason ?? null,
    deviceUdid: input.deviceUdid ?? null,
    acknowledgementMatched: input.acknowledgementMatched,
    agentConfirmed: input.agentConfirmed,
    createdAtMs: Date.now(),
  });
}

export async function upsertEvidenceArtifact(
  artifact: EvidenceArtifact,
  ownerUserId: number,
  storageKey: string | null,
  computedSha256: string | null
) {
  const db = await database();
  const values: InsertOperatorEvidenceArtifact = {
    id: artifact.id,
    ownerUserId,
    traceId: artifact.traceId,
    name: artifact.name,
    kind: artifact.kind,
    sizeBytes: artifact.sizeBytes,
    sha256: artifact.sha256,
    computedSha256,
    mediaType: artifact.mediaType,
    storageKey,
    verified: artifact.verified,
    verificationError: artifact.verificationError,
    sanitized: artifact.sanitized,
    createdAtMs: artifact.createdAt,
    verifiedAtMs: artifact.verified ? Date.now() : null,
  };
  await db
    .insert(operatorEvidenceArtifacts)
    .values(values)
    .onDuplicateKeyUpdate({
      set: {
        sizeBytes: values.sizeBytes,
        sha256: values.sha256,
        computedSha256: values.computedSha256,
        mediaType: values.mediaType,
        storageKey: values.storageKey,
        verified: values.verified,
        verificationError: values.verificationError,
        sanitized: values.sanitized,
        verifiedAtMs: values.verifiedAtMs,
      },
    });
}

export async function listEvidenceArtifacts(
  ownerUserId: number,
  traceId: string
) {
  const db = await database();
  return db
    .select()
    .from(operatorEvidenceArtifacts)
    .where(
      and(
        eq(operatorEvidenceArtifacts.ownerUserId, ownerUserId),
        eq(operatorEvidenceArtifacts.traceId, traceId)
      )
    )
    .orderBy(desc(operatorEvidenceArtifacts.createdAtMs));
}

export async function upsertEvidenceSummary(input: {
  ownerUserId: number;
  traceId: string;
  status: string;
  reasons: string[];
  archiveSizeBytes: number;
  archiveSha256: string;
  manifestSha256: string;
  totalCount: number;
  verifiedCount: number;
  rejectedCount: number;
  sanitizedCount: number;
}) {
  const db = await database();
  const now = Date.now();
  const values: InsertOperatorEvidenceBundle = {
    traceId: input.traceId,
    ownerUserId: input.ownerUserId,
    status: input.status.slice(0, 32),
    reasonsJson: JSON.stringify(input.reasons.slice(0, 100)),
    archiveSizeBytes: input.archiveSizeBytes,
    archiveSha256: input.archiveSha256,
    manifestSha256: input.manifestSha256,
    totalCount: input.totalCount,
    verifiedCount: input.verifiedCount,
    rejectedCount: input.rejectedCount,
    sanitizedCount: input.sanitizedCount,
    createdAtMs: now,
    verifiedAtMs: now,
  };
  await db
    .insert(operatorEvidenceBundles)
    .values(values)
    .onDuplicateKeyUpdate({
      set: {
        status: values.status,
        reasonsJson: values.reasonsJson,
        archiveSizeBytes: values.archiveSizeBytes,
        archiveSha256: values.archiveSha256,
        manifestSha256: values.manifestSha256,
        totalCount: values.totalCount,
        verifiedCount: values.verifiedCount,
        rejectedCount: values.rejectedCount,
        sanitizedCount: values.sanitizedCount,
        verifiedAtMs: values.verifiedAtMs,
      },
    });
}

export async function getEvidenceSummary(ownerUserId: number, traceId: string) {
  const db = await database();
  const [row] = await db
    .select()
    .from(operatorEvidenceBundles)
    .where(
      and(
        eq(operatorEvidenceBundles.ownerUserId, ownerUserId),
        eq(operatorEvidenceBundles.traceId, traceId)
      )
    )
    .limit(1);
  if (!row) return null;
  let reasons: string[] = [];
  try {
    const parsed = JSON.parse(row.reasonsJson);
    if (Array.isArray(parsed)) {
      reasons = parsed
        .filter((value): value is string => typeof value === "string")
        .slice(0, 100);
    }
  } catch {
    reasons = ["Stored evidence reasons could not be decoded."];
  }
  return {
    traceId: row.traceId,
    status: row.status,
    reasons,
    archiveSizeBytes: row.archiveSizeBytes,
    archiveSha256: row.archiveSha256,
    manifestSha256: row.manifestSha256,
    totalCount: row.totalCount,
    verifiedCount: row.verifiedCount,
    rejectedCount: row.rejectedCount,
    sanitizedCount: row.sanitizedCount,
    allVerified: row.totalCount > 0 && row.verifiedCount === row.totalCount,
    allSanitized: row.totalCount > 0 && row.sanitizedCount === row.totalCount,
    verifiedAt: row.verifiedAtMs,
  };
}

function mapPersistedJob(row: typeof operatorJobs.$inferSelect): JobRecord {
  return {
    id: row.id,
    scenario: row.scenario,
    deviceUdid: row.deviceUdid,
    idempotencyKey: row.idempotencyKey,
    retryCount: row.retryCount,
    attempt: row.attempt,
    status: row.status,
    phase: row.phase,
    traceId: row.traceId,
    createdAt: row.createdAtMs,
    startedAt: row.startedAtMs,
    finishedAt: row.finishedAtMs,
    updatedAt: row.updatedAtMs,
    errorCode: row.errorCode,
    errorMessage: row.errorMessage,
  };
}
