import {
  bigint,
  boolean,
  index,
  int,
  mysqlEnum,
  mysqlTable,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/mysql-core";

/**
 * Core user table backing auth flow.
 * Extend this file with additional tables as your product grows.
 * Columns use camelCase to match both database fields and generated types.
 */
export const users = mysqlTable("users", {
  /**
   * Surrogate primary key. Auto-incremented numeric value managed by the database.
   * Use this for relations between tables.
   */
  id: int("id").autoincrement().primaryKey(),
  /** Manus OAuth identifier (openId) returned from the OAuth callback. Unique per user. */
  openId: varchar("openId", { length: 64 }).notNull().unique(),
  name: text("name"),
  email: varchar("email", { length: 320 }),
  loginMethod: varchar("loginMethod", { length: 64 }),
  role: mysqlEnum("role", ["user", "admin"]).default("user").notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
  lastSignedIn: timestamp("lastSignedIn").defaultNow().notNull(),
});

export type User = typeof users.$inferSelect;
export type InsertUser = typeof users.$inferInsert;

export const operatorJobs = mysqlTable(
  "operatorJobs",
  {
    id: varchar("id", { length: 36 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    agentJobId: varchar("agentJobId", { length: 64 }),
    scenario: mysqlEnum("scenario", [
      "canary",
      "launch",
      "tabs",
      "browser",
      "media",
      "diagnostics",
      "recovery",
      "hardware",
      "all",
    ]).notNull(),
    deviceUdid: varchar("deviceUdid", { length: 40 }).notNull(),
    idempotencyKey: varchar("idempotencyKey", { length: 64 }).notNull(),
    retryCount: int("retryCount").notNull(),
    attempt: int("attempt").default(0).notNull(),
    status: mysqlEnum("status", [
      "queued",
      "preparing",
      "running",
      "cancelling",
      "succeeded",
      "failed",
      "cancelled",
      "timed_out",
    ]).notNull(),
    phase: varchar("phase", { length: 96 }).notNull(),
    traceId: varchar("traceId", { length: 36 }),
    errorCode: varchar("errorCode", { length: 96 }),
    errorMessage: text("errorMessage"),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
    startedAtMs: bigint("startedAtMs", { mode: "number" }),
    finishedAtMs: bigint("finishedAtMs", { mode: "number" }),
    updatedAtMs: bigint("updatedAtMs", { mode: "number" }).notNull(),
  },
  table => [
    uniqueIndex("operatorJobs_idempotency_idx").on(table.idempotencyKey),
    index("operatorJobs_owner_updated_idx").on(
      table.ownerUserId,
      table.updatedAtMs
    ),
    index("operatorJobs_status_updated_idx").on(
      table.status,
      table.updatedAtMs
    ),
    index("operatorJobs_trace_idx").on(table.traceId),
  ]
);

export const operatorLiveSessions = mysqlTable(
  "operatorLiveSessions",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    deviceUdid: varchar("deviceUdid", { length: 40 }).notNull(),
    state: mysqlEnum("state", [
      "idle",
      "starting",
      "active",
      "recovering",
      "closing",
      "closed",
      "failed",
    ]).notNull(),
    bidiConnected: boolean("bidiConnected").default(false).notNull(),
    appiumSessionId: varchar("appiumSessionId", { length: 128 }),
    sessionTraceId: varchar("sessionTraceId", { length: 36 }).notNull(),
    traceparent: varchar("traceparent", { length: 55 }).notNull(),
    leaseCiphertext: text("leaseCiphertext"),
    startedAtMs: bigint("startedAtMs", { mode: "number" }).notNull(),
    expiresAtMs: bigint("expiresAtMs", { mode: "number" }).notNull(),
    lastHeartbeatAtMs: bigint("lastHeartbeatAtMs", {
      mode: "number",
    }).notNull(),
    closedAtMs: bigint("closedAtMs", { mode: "number" }),
    updatedAtMs: bigint("updatedAtMs", { mode: "number" }).notNull(),
  },
  table => [
    index("operatorLiveSessions_owner_updated_idx").on(
      table.ownerUserId,
      table.updatedAtMs
    ),
    index("operatorLiveSessions_state_updated_idx").on(
      table.state,
      table.updatedAtMs
    ),
    index("operatorLiveSessions_trace_idx").on(table.sessionTraceId),
  ]
);

export const operatorPolicySnapshots = mysqlTable(
  "operatorPolicySnapshots",
  {
    id: varchar("id", { length: 36 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    gateState: mysqlEnum("gateState", [
      "open",
      "blocked",
      "unavailable",
    ]).notNull(),
    repository: varchar("repository", { length: 200 }).notNull(),
    repositoryPrivate: boolean("repositoryPrivate").notNull(),
    summary: text("summary").notNull(),
    failedChecksJson: text("failedChecksJson").notNull(),
    checksJson: text("checksJson").notNull(),
    checkedAtMs: bigint("checkedAtMs", { mode: "number" }).notNull(),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
  },
  table => [index("operatorPolicySnapshots_checked_idx").on(table.checkedAtMs)]
);

export const operatorEvidenceArtifacts = mysqlTable(
  "operatorEvidenceArtifacts",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    traceId: varchar("traceId", { length: 36 }).notNull(),
    name: varchar("name", { length: 240 }).notNull(),
    kind: varchar("kind", { length: 80 }).notNull(),
    sizeBytes: bigint("sizeBytes", { mode: "number" }).notNull(),
    sha256: varchar("sha256", { length: 64 }).notNull(),
    computedSha256: varchar("computedSha256", { length: 64 }),
    mediaType: varchar("mediaType", { length: 128 }).notNull(),
    storageKey: varchar("storageKey", { length: 512 }),
    verified: boolean("verified").default(false).notNull(),
    verificationError: text("verificationError"),
    sanitized: boolean("sanitized").default(false).notNull(),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
    verifiedAtMs: bigint("verifiedAtMs", { mode: "number" }),
  },
  table => [
    index("operatorEvidenceArtifacts_trace_created_idx").on(
      table.traceId,
      table.createdAtMs
    ),
    index("operatorEvidenceArtifacts_verified_idx").on(
      table.verified,
      table.createdAtMs
    ),
  ]
);

export const operatorEvidenceBundles = mysqlTable(
  "operatorEvidenceBundles",
  {
    traceId: varchar("traceId", { length: 36 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    status: varchar("status", { length: 32 }).notNull(),
    reasonsJson: text("reasonsJson").notNull(),
    archiveSizeBytes: bigint("archiveSizeBytes", { mode: "number" }).notNull(),
    archiveSha256: varchar("archiveSha256", { length: 64 }).notNull(),
    manifestSha256: varchar("manifestSha256", { length: 64 }).notNull(),
    totalCount: int("totalCount").notNull(),
    verifiedCount: int("verifiedCount").notNull(),
    rejectedCount: int("rejectedCount").notNull(),
    sanitizedCount: int("sanitizedCount").notNull(),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
    verifiedAtMs: bigint("verifiedAtMs", { mode: "number" }).notNull(),
  },
  table => [
    index("operatorEvidenceBundles_owner_verified_idx").on(
      table.ownerUserId,
      table.verifiedAtMs
    ),
  ]
);

export const operatorQuarantineEvents = mysqlTable(
  "operatorQuarantineEvents",
  {
    id: varchar("id", { length: 36 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    action: mysqlEnum("action", ["set", "clear"]).notNull(),
    mode: mysqlEnum("mode", [
      "manual",
      "runner-maintenance",
      "device-maintenance",
    ]),
    reason: text("reason"),
    deviceUdid: varchar("deviceUdid", { length: 40 }),
    acknowledgementMatched: boolean("acknowledgementMatched")
      .default(false)
      .notNull(),
    agentConfirmed: boolean("agentConfirmed").default(false).notNull(),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
  },
  table => [index("operatorQuarantineEvents_created_idx").on(table.createdAtMs)]
);

export const operatorAuditEvents = mysqlTable(
  "operatorAuditEvents",
  {
    id: varchar("id", { length: 36 }).primaryKey(),
    ownerUserId: int("ownerUserId").notNull(),
    action: varchar("action", { length: 96 }).notNull(),
    resourceType: varchar("resourceType", { length: 64 }).notNull(),
    resourceId: varchar("resourceId", { length: 128 }),
    outcome: mysqlEnum("outcome", ["success", "blocked", "failure"]).notNull(),
    traceId: varchar("traceId", { length: 36 }),
    detailJson: text("detailJson").notNull(),
    createdAtMs: bigint("createdAtMs", { mode: "number" }).notNull(),
  },
  table => [
    index("operatorAuditEvents_created_idx").on(table.createdAtMs),
    index("operatorAuditEvents_resource_idx").on(
      table.resourceType,
      table.resourceId
    ),
    index("operatorAuditEvents_trace_idx").on(table.traceId),
  ]
);

export type OperatorJob = typeof operatorJobs.$inferSelect;
export type InsertOperatorJob = typeof operatorJobs.$inferInsert;
export type OperatorLiveSession = typeof operatorLiveSessions.$inferSelect;
export type InsertOperatorLiveSession =
  typeof operatorLiveSessions.$inferInsert;
export type OperatorPolicySnapshot =
  typeof operatorPolicySnapshots.$inferSelect;
export type OperatorEvidenceArtifact =
  typeof operatorEvidenceArtifacts.$inferSelect;
export type InsertOperatorEvidenceArtifact =
  typeof operatorEvidenceArtifacts.$inferInsert;
export type OperatorEvidenceBundle =
  typeof operatorEvidenceBundles.$inferSelect;
export type InsertOperatorEvidenceBundle =
  typeof operatorEvidenceBundles.$inferInsert;
export type OperatorQuarantineEvent =
  typeof operatorQuarantineEvents.$inferSelect;
export type OperatorAuditEvent = typeof operatorAuditEvents.$inferSelect;
