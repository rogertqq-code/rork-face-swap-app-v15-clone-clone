import { z } from "zod";

export const OPERATOR_SCENARIOS = [
  "canary",
  "launch",
  "tabs",
  "browser",
  "media",
  "diagnostics",
  "recovery",
  "hardware",
  "all",
] as const;

export const JOB_STATUSES = [
  "queued",
  "preparing",
  "running",
  "cancelling",
  "succeeded",
  "failed",
  "cancelled",
  "timed_out",
] as const;

export const LIVE_SESSION_STATES = [
  "idle",
  "starting",
  "active",
  "recovering",
  "closing",
  "closed",
  "failed",
] as const;

export const QUARANTINE_MODES = [
  "manual",
  "runner-maintenance",
  "device-maintenance",
] as const;

export const QUARANTINE_CLEAR_ACKNOWLEDGEMENT =
  "CLEAR QUARANTINE AND REVALIDATE DEVICE";

export const deviceUdidSchema = z
  .string()
  .trim()
  .min(24)
  .max(40)
  .regex(/^[A-Fa-f0-9-]+$/, "Enter a valid cable-device UDID");

export const idempotencyKeySchema = z.string().uuid();

export const jobSubmissionSchema = z.object({
  scenario: z.enum(OPERATOR_SCENARIOS),
  deviceUdid: deviceUdidSchema,
  retryCount: z.number().int().min(0).max(2),
  idempotencyKey: idempotencyKeySchema,
});

export const quarantineSetSchema = z.object({
  mode: z.enum(QUARANTINE_MODES),
  reason: z.string().trim().min(8).max(240),
});

export const quarantineClearSchema = z.object({
  acknowledgement: z.literal(QUARANTINE_CLEAR_ACKNOWLEDGEMENT),
});

export type OperatorScenario = (typeof OPERATOR_SCENARIOS)[number];
export type JobStatus = (typeof JOB_STATUSES)[number];
export type LiveSessionState = (typeof LIVE_SESSION_STATES)[number];
export type QuarantineMode = (typeof QUARANTINE_MODES)[number];

export type PolicyCheck = {
  key: string;
  label: string;
  passed: boolean;
  required: true;
  detail: string;
  checkedAt: number;
};

export type ActivationGate = {
  open: boolean;
  state: "open" | "blocked" | "unavailable";
  summary: string;
  repository: string;
  repositoryPrivate: boolean;
  failedChecks: string[];
  checks: PolicyCheck[];
  checkedAt: number;
};

export type CableDevice = {
  udid: string;
  name: string;
  model: string;
  platformVersion: string;
  transport: "usb" | "network" | "unknown";
  paired: boolean;
  trusted: boolean;
  developerMode: boolean;
  ready: boolean;
  readinessReason: string | null;
};

export type AgentHealth = {
  configured: boolean;
  reachable: boolean;
  state: "healthy" | "degraded" | "offline" | "unconfigured";
  version: string | null;
  queueDepth: number;
  activeJobId: string | null;
  activeLiveSessionId: string | null;
  appiumState: "stopped" | "starting" | "healthy" | "degraded" | "unknown";
  cableDevices: CableDevice[];
  observedAt: number;
  latencyMs: number | null;
  errorCode: string | null;
};

export type JobRecord = {
  id: string;
  scenario: OperatorScenario;
  deviceUdid: string;
  idempotencyKey: string;
  retryCount: number;
  attempt: number;
  status: JobStatus;
  phase: string;
  traceId: string | null;
  createdAt: number;
  startedAt: number | null;
  finishedAt: number | null;
  updatedAt: number;
  errorCode: string | null;
  errorMessage: string | null;
};

export type JobLogEntry = {
  sequence: number;
  timestamp: number;
  level: "debug" | "info" | "warning" | "error";
  phase: string;
  message: string;
  fields: Record<string, string | number | boolean | null>;
};

export type LiveStreamEvent = {
  sequence: number;
  timestamp: number;
  kind: "action" | "observation" | "bidi" | "recovery" | "system";
  operationTraceId: string | null;
  summary: string;
  outcome: "pending" | "success" | "failure" | "info";
};

export type LiveSession = {
  id: string;
  deviceUdid: string;
  state: LiveSessionState;
  bidiConnected: boolean;
  appiumSessionId: string | null;
  wdaState: "unknown" | "healthy" | "degraded" | "offline";
  sessionTraceId: string;
  traceparent: string;
  startedAt: number;
  expiresAt: number;
  lastHeartbeatAt: number;
  lastScreenshotArtifactId: string | null;
  stream: LiveStreamEvent[];
};

export const OPERATOR_POLL_INTERVALS_MS = {
  overview: 3_000,
  active: 2_000,
  index: 15_000,
  screenshot: 5_000,
} as const;

export const LIVE_ACTION_KINDS = [
  "qa_command",
  "activate_app",
  "terminate_app",
  "query_app_state",
  "start_network_monitor",
  "stop_network_monitor",
] as const;

export type LiveActionKind = (typeof LIVE_ACTION_KINDS)[number];

export const LIVE_OBSERVATION_KINDS = [
  "screenshot",
  "combined",
  "source_json",
  "contexts",
  "orientation",
  "window_rect",
  "device_info",
  "battery_info",
] as const;

export type LiveObservationKind = (typeof LIVE_OBSERVATION_KINDS)[number];

export type LiveOperationReceipt = {
  kind: LiveActionKind | LiveObservationKind;
  operationTraceId: string;
  success: boolean;
  elapsedMs: number | null;
  errorCode: string | null;
  errorMessage: string | null;
};

export type VerifiedScreenshot = {
  artifactId: string;
  traceId: string;
  sha256: string;
  sizeBytes: number;
  mediaType: string;
  capturedAt: number;
  verified: true;
  downloadUrl: string;
};

export type TimelineEvent = {
  sequence: number;
  timestamp: number;
  source: "dashboard" | "agent" | "xcode" | "appium" | "wda" | "bidi" | "ios";
  eventType: string;
  operationTraceId: string | null;
  spanId: string | null;
  outcome: string;
  summary: string;
};

export type RecoveryEpisode = {
  id: string;
  cause: string;
  outcome: string;
  startedAt: number;
  finishedAt: number | null;
  evidenceArtifactIds: string[];
  summary: string;
};

export type AnalyticsInvariant = {
  key: string;
  label: string;
  passed: boolean;
  actual: string;
  expected: string;
};

export type TraceRecord = {
  traceId: string;
  traceparent: string;
  ownerType: "job" | "live_session";
  ownerId: string;
  status: string;
  startedAt: number;
  finishedAt: number | null;
  timeline: TimelineEvent[];
  recoveries: RecoveryEpisode[];
  invariants: AnalyticsInvariant[];
};

export type EvidenceArtifact = {
  id: string;
  traceId: string;
  name: string;
  kind: string;
  sizeBytes: number;
  sha256: string;
  mediaType: string;
  verified: boolean;
  verificationError: string | null;
  sanitized: boolean;
  createdAt: number;
  downloadUrl: string | null;
};

export type EvidenceSummary = {
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
  allVerified: boolean;
  allSanitized: boolean;
  verifiedAt: number;
};

export type QuarantineState = {
  active: boolean;
  mode: QuarantineMode | null;
  reason: string | null;
  setAt: number | null;
  setBy: string | null;
  deviceUdid: string | null;
  clearAcknowledgement: typeof QUARANTINE_CLEAR_ACKNOWLEDGEMENT;
};

export type OperatorOverview = {
  activation: ActivationGate;
  agent: AgentHealth;
  quarantine: QuarantineState;
  activeJob: JobRecord | null;
  activeLiveSession: LiveSession | null;
  refreshedAt: number;
};
