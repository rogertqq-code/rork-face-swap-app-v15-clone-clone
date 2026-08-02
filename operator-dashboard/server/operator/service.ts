import { TRPCError } from "@trpc/server";
import type {
  AgentHealth,
  CableDevice,
  JobLogEntry,
  JobRecord,
  LiveActionKind,
  LiveObservationKind,
  LiveSession,
  OperatorOverview,
  OperatorScenario,
  QuarantineState,
  TraceRecord,
} from "../../shared/operator";
import {
  QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
  type QuarantineMode,
} from "../../shared/operator";
import {
  AgentGateway,
  AgentGatewayError,
  agentGateway,
  asOptionalString,
  asRecord,
} from "./agentGateway";
import {
  findJobByIdempotencyKey,
  getOwnedLiveSession,
  getOperatorJob,
  insertOperatorJob,
  listOperatorJobs,
  recordAudit,
  recordPolicySnapshot,
  recordQuarantine,
  storeLiveSessionLease,
  updateOperatorJob,
  upsertLiveSession,
} from "./persistence";
import { evaluateActivationGate } from "./policy";
import {
  persistedEvidenceInventory,
  persistedEvidenceSummary,
  prepareVerifiedEvidence,
} from "./evidence";
import { sealLiveLease } from "./leaseVault";
import {
  captureGuardedLiveObservation,
  executeGuardedLiveAction,
  latestVerifiedScreenshot,
} from "./liveOperations";

const SCENARIO_TESTS: Record<OperatorScenario, string[]> = {
  canary: ["FaceSwapLiveAppV17UITests/testManifestActivationAndRootIdentity"],
  launch: ["FaceSwapLiveAppV17UITestsLaunchTests/testLaunch"],
  tabs: ["FaceSwapLiveAppV17UITests/testRootTabsAndScreens"],
  browser: [
    "FaceSwapLiveAppV17UITests/testBrowserNavigationAndFeatureOverrides",
  ],
  media: ["FaceSwapLiveAppV17UITests/testMediaSequenceAndCaptureState"],
  diagnostics: ["FaceSwapLiveAppV17UITests/testDiagnosticsStructuredResult"],
  recovery: [
    "FaceSwapLiveAppV17UITests/testRecoveryEvidenceAndNegativeCommand",
  ],
  hardware: [
    "FaceSwapLiveAppV17UITests/testCableDeviceHardwareAndNativeWebRTC",
  ],
  all: [],
};

export class OperatorService {
  constructor(private readonly gateway: AgentGateway = agentGateway) {}

  async overview(ownerUserId: number): Promise<OperatorOverview> {
    const activation = await evaluateActivationGate(this.gateway);
    await recordPolicySnapshot(ownerUserId, activation).catch(() => undefined);
    if (!this.gateway.getConfiguration().valid) {
      return {
        activation,
        agent: unconfiguredHealth(this.gateway),
        quarantine: unavailableQuarantine(),
        activeJob: null,
        activeLiveSession: null,
        refreshedAt: Date.now(),
      };
    }

    try {
      const [healthRaw, devicesRaw, quarantineRaw] = await Promise.all([
        this.gateway.request<unknown>("GET", "/api/v1/health"),
        this.gateway.request<unknown>("GET", "/api/v1/devices"),
        this.gateway.request<unknown>("GET", "/api/v1/github/quarantine"),
      ]);
      const agent = mapHealth(healthRaw, devicesRaw);
      const quarantine = mapQuarantine(quarantineRaw);
      const activeJob = agent.activeJobId
        ? await this.fetchAgentJob(agent.activeJobId, null)
        : null;
      const activeLiveSession = agent.activeLiveSessionId
        ? await this.fetchLiveSession(agent.activeLiveSessionId)
        : null;
      return {
        activation,
        agent,
        quarantine,
        activeJob,
        activeLiveSession,
        refreshedAt: Date.now(),
      };
    } catch (error) {
      return {
        activation: {
          ...activation,
          open: false,
          state: "unavailable",
          summary:
            "Agent telemetry is unavailable; protected controls are blocked.",
          failedChecks: Array.from(
            new Set([...activation.failedChecks, "agent_telemetry"])
          ),
        },
        agent: failedHealth(this.gateway, error),
        quarantine: unavailableQuarantine(),
        activeJob: null,
        activeLiveSession: null,
        refreshedAt: Date.now(),
      };
    }
  }

  async listJobs(ownerUserId: number) {
    return listOperatorJobs(ownerUserId);
  }

  async jobDetail(ownerUserId: number, localJobId: string) {
    const local = await getOperatorJob(ownerUserId, localJobId);
    if (!local)
      throw new TRPCError({ code: "NOT_FOUND", message: "Job not found." });
    return local;
  }

  async submitJob(
    ownerUserId: number,
    input: {
      scenario: OperatorScenario;
      deviceUdid: string;
      retryCount: number;
      idempotencyKey: string;
    }
  ) {
    const existing = await findJobByIdempotencyKey(input.idempotencyKey);
    const duplicate = duplicateJobResult(existing);
    if (duplicate) return duplicate;
    await this.requireOperational(ownerUserId, input.deviceUdid, "job.submit");
    const now = Date.now();
    const local: JobRecord = {
      id: crypto.randomUUID(),
      scenario: input.scenario,
      deviceUdid: input.deviceUdid,
      idempotencyKey: input.idempotencyKey,
      retryCount: input.retryCount,
      attempt: 0,
      status: "preparing",
      phase: "Submitting to Mac agent",
      traceId: crypto.randomUUID(),
      createdAt: now,
      startedAt: null,
      finishedAt: null,
      updatedAt: now,
      errorCode: null,
      errorMessage: null,
    };
    await insertOperatorJob(local, ownerUserId);
    try {
      const payload = {
        target: { kind: "cable", udid: input.deviceUdid },
        run_id: local.id,
        session_trace_id: local.traceId,
        only_testing: SCENARIO_TESTS[input.scenario],
        skip_testing: [],
        max_retries: input.retryCount,
      };
      const response = await this.gateway.request<unknown>(
        "POST",
        "/api/v1/jobs",
        {
          body: payload,
          idempotencyKey: input.idempotencyKey,
          timeoutMs: 30_000,
        }
      );
      const record = asRecord(response);
      const agentRecord = asRecord(record.job);
      const mapped = mapAgentJob(agentRecord, local);
      const agentJobId = asOptionalString(agentRecord.id) ?? undefined;
      await updateOperatorJob(local.id, mapped, agentJobId);
      await recordAudit({
        ownerUserId,
        action: "job.submit",
        resourceType: "job",
        resourceId: local.id,
        outcome: "success",
        traceId: mapped.traceId,
        detail: { scenario: input.scenario, duplicate: false },
      });
      return { job: mapped, duplicate: false };
    } catch (error) {
      const failed: JobRecord = {
        ...local,
        status: "failed",
        phase: "Submission failed",
        finishedAt: Date.now(),
        updatedAt: Date.now(),
        errorCode:
          error instanceof AgentGatewayError ? error.code : "submission_failed",
        errorMessage:
          error instanceof Error ? error.message : "Submission failed.",
      };
      await updateOperatorJob(local.id, failed);
      await recordAudit({
        ownerUserId,
        action: "job.submit",
        resourceType: "job",
        resourceId: local.id,
        outcome: "failure",
        traceId: failed.traceId,
        detail: { errorCode: failed.errorCode },
      });
      throw mapGatewayError(error);
    }
  }

  async cancelJob(ownerUserId: number, localJobId: string) {
    await this.requireOperational(ownerUserId, null, "job.cancel");
    const local = await getOperatorJob(ownerUserId, localJobId);
    if (!local)
      throw new TRPCError({ code: "NOT_FOUND", message: "Job not found." });
    const jobs = await this.gateway.request<unknown>(
      "GET",
      "/api/v1/jobs?limit=100"
    );
    const candidates = Array.isArray(asRecord(jobs).jobs)
      ? (asRecord(jobs).jobs as unknown[])
      : [];
    const matching = candidates.map(asRecord).find(item => {
      const request = asRecord(item.request);
      return asOptionalString(request.run_id) === local.id;
    });
    const agentId = asOptionalString(matching?.id);
    if (!agentId)
      throw new TRPCError({
        code: "NOT_FOUND",
        message: "Agent job not found.",
      });
    await this.gateway.request(
      "POST",
      `/api/v1/jobs/${encodeURIComponent(agentId)}/cancel`
    );
    const next = {
      ...local,
      status: "cancelling" as const,
      phase: "Cancellation requested",
      updatedAt: Date.now(),
    };
    await updateOperatorJob(local.id, next, agentId);
    await recordAudit({
      ownerUserId,
      action: "job.cancel",
      resourceType: "job",
      resourceId: local.id,
      outcome: "success",
      traceId: local.traceId,
    });
    return next;
  }

  async jobLog(
    ownerUserId: number,
    localJobId: string
  ): Promise<JobLogEntry[]> {
    const local = await getOperatorJob(ownerUserId, localJobId);
    if (!local)
      throw new TRPCError({ code: "NOT_FOUND", message: "Job not found." });
    if (!this.gateway.getConfiguration().valid) return [];
    const jobs = await this.gateway.request<unknown>(
      "GET",
      "/api/v1/jobs?limit=100"
    );
    const candidates = Array.isArray(asRecord(jobs).jobs)
      ? (asRecord(jobs).jobs as unknown[])
      : [];
    const matching = candidates
      .map(asRecord)
      .find(
        item => asOptionalString(asRecord(item.request).run_id) === local.id
      );
    const agentId = asOptionalString(matching?.id);
    if (!agentId) return [];
    const raw = await this.gateway.request<unknown>(
      "GET",
      `/api/v1/jobs/${encodeURIComponent(agentId)}/log?offset=0&limit=65536`
    );
    const log = asRecord(asRecord(raw).log);
    const text = asOptionalString(log.data) ?? "";
    return text
      .split("\n")
      .filter(Boolean)
      .slice(-200)
      .map((message, index) => ({
        sequence: index + 1,
        timestamp: local.updatedAt,
        level: /error|fail/i.test(message)
          ? "error"
          : /warn/i.test(message)
            ? "warning"
            : "info",
        phase: local.phase,
        message: message.slice(0, 2000),
        fields: {},
      }));
  }

  async listTraces(): Promise<TraceRecord[]> {
    if (!this.gateway.getConfiguration().valid) return [];
    const raw = await this.gateway.request<unknown>(
      "GET",
      "/api/v1/traces?limit=50"
    );
    const records = Array.isArray(asRecord(raw).traces)
      ? (asRecord(raw).traces as unknown[])
      : [];
    return records.map(item => mapTrace(asRecord(item)));
  }

  async traceDetail(traceId: string): Promise<TraceRecord> {
    const [documentRaw, eventsRaw, analyticsRaw, recoveriesRaw] =
      await Promise.all([
        this.gateway.request<unknown>(
          "GET",
          `/api/v1/traces/${encodeURIComponent(traceId)}`
        ),
        this.gateway.request<unknown>(
          "GET",
          `/api/v1/traces/${encodeURIComponent(traceId)}/events?after=0&limit=1000`
        ),
        this.gateway.request<unknown>(
          "GET",
          `/api/v1/traces/${encodeURIComponent(traceId)}/analytics`
        ),
        this.gateway.request<unknown>(
          "GET",
          `/api/v1/traces/${encodeURIComponent(traceId)}/recoveries`
        ),
      ]);
    return mapTraceDetail(
      traceId,
      documentRaw,
      eventsRaw,
      analyticsRaw,
      recoveriesRaw
    );
  }

  async evidenceInventory(ownerUserId: number, traceId: string) {
    await this.requireActivation(ownerUserId, "evidence.inventory");
    return persistedEvidenceInventory(ownerUserId, traceId);
  }

  async evidenceSummary(ownerUserId: number, traceId: string) {
    await this.requireActivation(ownerUserId, "evidence.summary");
    return persistedEvidenceSummary(ownerUserId, traceId);
  }

  async prepareEvidence(ownerUserId: number, traceId: string) {
    await this.requireActivation(ownerUserId, "evidence.prepare");
    const result = await prepareVerifiedEvidence({
      gateway: this.gateway,
      ownerUserId,
      traceId,
    });
    await recordAudit({
      ownerUserId,
      action: "evidence.prepare",
      resourceType: "trace",
      resourceId: traceId,
      outcome: result.counts.rejected === 0 ? "success" : "failure",
      traceId,
      detail: { counts: result.counts },
    });
    return result;
  }

  async liveSession(ownerUserId: number, id: string) {
    const owned = await getOwnedLiveSession(ownerUserId, id);
    if (!owned) {
      throw new TRPCError({
        code: "NOT_FOUND",
        message: "Live session not found.",
      });
    }
    const session = await this.fetchLiveSession(id);
    await upsertLiveSession(session, ownerUserId);
    return session;
  }

  async openLiveSession(
    ownerUserId: number,
    deviceUdid: string,
    idempotencyKey: string
  ) {
    await this.requireOperational(ownerUserId, deviceUdid, "live.open");
    const traceId = crypto.randomUUID();
    const raw = await this.gateway.request<unknown>(
      "POST",
      "/api/v1/live/sessions",
      {
        idempotencyKey,
        timeoutMs: 60_000,
        body: {
          target: { kind: "cable", udid: deviceUdid },
          run_id: crypto.randomUUID(),
          session_trace_id: traceId,
          lease_seconds: 300,
          no_reset: true,
          auto_launch: true,
          language: "en",
          locale: "en_US",
        },
      }
    );
    const record = asRecord(raw);
    const session = mapLiveSession(asRecord(record.session), []);
    await upsertLiveSession(session, ownerUserId);
    const leaseToken = asOptionalString(record.lease_token);
    if (!leaseToken) {
      throw new TRPCError({
        code: "SERVICE_UNAVAILABLE",
        message:
          "Mac agent did not provide a recoverable live-session credential.",
      });
    }
    await storeLiveSessionLease(
      ownerUserId,
      session.id,
      sealLiveLease(session.id, leaseToken)
    );
    await recordAudit({
      ownerUserId,
      action: "live.open",
      resourceType: "live_session",
      resourceId: session.id,
      outcome: "success",
      traceId: session.sessionTraceId,
    });
    return { session };
  }

  async executeLiveAction(
    ownerUserId: number,
    input: {
      sessionId: string;
      kind: LiveActionKind;
      command?: Record<string, unknown>;
    }
  ) {
    const owned = await getOwnedLiveSession(ownerUserId, input.sessionId);
    if (!owned) {
      throw new TRPCError({
        code: "NOT_FOUND",
        message: "Live session not found.",
      });
    }
    await this.requireOperational(ownerUserId, owned.deviceUdid, "live.action");
    try {
      const result = await executeGuardedLiveAction({
        gateway: this.gateway,
        ownerUserId,
        ...input,
      });
      await recordAudit({
        ownerUserId,
        action: `live.action.${input.kind}`,
        resourceType: "live_session",
        resourceId: input.sessionId,
        outcome: result.success ? "success" : "failure",
        traceId: owned.sessionTraceId,
        detail: { operationTraceId: result.operationTraceId },
      });
      return result;
    } catch (error) {
      throw mapGatewayError(error);
    }
  }

  async captureLiveObservation(
    ownerUserId: number,
    sessionId: string,
    kind: LiveObservationKind
  ) {
    const owned = await getOwnedLiveSession(ownerUserId, sessionId);
    if (!owned) {
      throw new TRPCError({
        code: "NOT_FOUND",
        message: "Live session not found.",
      });
    }
    await this.requireOperational(
      ownerUserId,
      owned.deviceUdid,
      "live.observe"
    );
    try {
      const result = await captureGuardedLiveObservation({
        gateway: this.gateway,
        ownerUserId,
        sessionId,
        kind,
      });
      await recordAudit({
        ownerUserId,
        action: `live.observe.${kind}`,
        resourceType: "live_session",
        resourceId: sessionId,
        outcome: result.receipt.success ? "success" : "failure",
        traceId: owned.sessionTraceId,
        detail: { operationTraceId: result.receipt.operationTraceId },
      });
      return result;
    } catch (error) {
      throw mapGatewayError(error);
    }
  }

  async latestLiveScreenshot(ownerUserId: number, sessionId: string) {
    return latestVerifiedScreenshot(ownerUserId, sessionId);
  }

  async setQuarantine(
    ownerUserId: number,
    mode: QuarantineMode,
    reason: string
  ) {
    await this.requireActivation(ownerUserId, "quarantine.set");
    const raw = await this.gateway.request<unknown>(
      "POST",
      "/api/v1/github/quarantine",
      { body: { mode, reason } }
    );
    const state = mapQuarantine(raw);
    await recordQuarantine({
      ownerUserId,
      action: "set",
      mode,
      reason,
      deviceUdid: state.deviceUdid,
      acknowledgementMatched: false,
      agentConfirmed: state.active,
    });
    await recordAudit({
      ownerUserId,
      action: "quarantine.set",
      resourceType: "quarantine",
      outcome: "success",
      detail: { mode },
    });
    return state;
  }

  async clearQuarantine(ownerUserId: number, acknowledgement: string) {
    if (acknowledgement !== QUARANTINE_CLEAR_ACKNOWLEDGEMENT) {
      throw new TRPCError({
        code: "BAD_REQUEST",
        message: "Exact quarantine acknowledgement is required.",
      });
    }
    await this.requireActivation(ownerUserId, "quarantine.clear");
    const raw = await this.gateway.request<unknown>(
      "DELETE",
      "/api/v1/github/quarantine",
      { body: { acknowledgement } }
    );
    const state = mapQuarantine(raw);
    await recordQuarantine({
      ownerUserId,
      action: "clear",
      acknowledgementMatched: true,
      agentConfirmed: !state.active,
    });
    await recordAudit({
      ownerUserId,
      action: "quarantine.clear",
      resourceType: "quarantine",
      outcome: "success",
    });
    return state;
  }

  private async requireActivation(ownerUserId: number, action: string) {
    const gate = await evaluateActivationGate(this.gateway);
    await recordPolicySnapshot(ownerUserId, gate).catch(() => undefined);
    if (!gate.open) {
      await recordAudit({
        ownerUserId,
        action,
        resourceType: "activation_gate",
        outcome: "blocked",
        detail: { state: gate.state, failedChecks: gate.failedChecks },
      }).catch(() => undefined);
      throw new TRPCError({
        code: "PRECONDITION_FAILED",
        message: gate.summary,
      });
    }
    return gate;
  }

  private async requireOperational(
    ownerUserId: number,
    deviceUdid: string | null,
    action: string
  ) {
    await this.requireActivation(ownerUserId, action);
    const [devicesRaw, quarantineRaw] = await Promise.all([
      this.gateway.request<unknown>("GET", "/api/v1/devices"),
      this.gateway.request<unknown>("GET", "/api/v1/github/quarantine"),
    ]);
    const quarantine = mapQuarantine(quarantineRaw);
    if (quarantine.active)
      throw new TRPCError({
        code: "PRECONDITION_FAILED",
        message: `Device access is quarantined: ${quarantine.reason ?? "no reason supplied"}`,
      });
    if (deviceUdid) {
      const device = mapDevices(devicesRaw).find(
        item => item.udid === deviceUdid
      );
      if (!device?.ready || device.transport !== "usb") {
        throw new TRPCError({
          code: "PRECONDITION_FAILED",
          message: "The exact USB cable device is not ready.",
        });
      }
    }
  }

  private async fetchAgentJob(agentId: string, fallback: JobRecord | null) {
    const raw = await this.gateway.request<unknown>(
      "GET",
      `/api/v1/jobs/${encodeURIComponent(agentId)}`
    );
    return mapAgentJob(asRecord(asRecord(raw).job), fallback);
  }

  private async fetchLiveSession(id: string) {
    const [raw, eventsRaw] = await Promise.all([
      this.gateway.request<unknown>(
        "GET",
        `/api/v1/live/sessions/${encodeURIComponent(id)}`
      ),
      this.gateway.request<unknown>(
        "GET",
        `/api/v1/live/sessions/${encodeURIComponent(id)}/events?after=0&limit=200`
      ),
    ]);
    const events = Array.isArray(asRecord(eventsRaw).events)
      ? (asRecord(eventsRaw).events as unknown[])
      : [];
    return mapLiveSession(asRecord(asRecord(raw).session), events);
  }
}

function unconfiguredHealth(gateway: AgentGateway): AgentHealth {
  const config = gateway.getConfiguration();
  return {
    configured: config.configured,
    reachable: false,
    state: "unconfigured",
    version: null,
    queueDepth: 0,
    activeJobId: null,
    activeLiveSessionId: null,
    appiumState: "unknown",
    cableDevices: [],
    observedAt: Date.now(),
    latencyMs: null,
    errorCode: config.errorCode,
  };
}

function failedHealth(gateway: AgentGateway, error: unknown): AgentHealth {
  return {
    ...unconfiguredHealth(gateway),
    configured: gateway.getConfiguration().configured,
    state: "offline",
    errorCode:
      error instanceof AgentGatewayError ? error.code : "agent_unavailable",
  };
}

function mapHealth(healthRaw: unknown, devicesRaw: unknown): AgentHealth {
  const health = asRecord(healthRaw);
  const appium = asRecord(health.appium);
  const started = performance.now();
  return {
    configured: true,
    reachable: true,
    state:
      health.status === "ok" && health.worker_alive === true
        ? "healthy"
        : "degraded",
    version: asOptionalString(health.version),
    queueDepth: numberValue(health.queue_depth),
    activeJobId: asOptionalString(health.active_job_id),
    activeLiveSessionId: asOptionalString(health.active_live_session_id),
    appiumState: normalizeAppium(asOptionalString(appium.status)),
    cableDevices: mapDevices(devicesRaw),
    observedAt: Date.now(),
    latencyMs: Math.round(performance.now() - started),
    errorCode: null,
  };
}

function mapDevices(raw: unknown): CableDevice[] {
  const values = Array.isArray(asRecord(raw).devices)
    ? (asRecord(raw).devices as unknown[])
    : [];
  return values.map(item => {
    const record = asRecord(item);
    const reasons = Array.isArray(record.readiness_reasons)
      ? record.readiness_reasons.filter(
          (value): value is string => typeof value === "string"
        )
      : [];
    const kind = asOptionalString(record.kind);
    return {
      udid: asOptionalString(record.udid) ?? "unknown",
      name: asOptionalString(record.name) ?? "Unnamed iPhone",
      model: asOptionalString(record.device_type) ?? "Unknown model",
      platformVersion:
        asOptionalString(record.os_version) ??
        asOptionalString(record.os) ??
        "Unknown",
      transport:
        kind === "physical"
          ? "usb"
          : kind === "simulator"
            ? "network"
            : "unknown",
      paired: !reasons.includes("not_paired"),
      trusted: !reasons.includes("not_trusted"),
      developerMode: !reasons.includes("developer_mode_disabled"),
      ready: record.ready === true && kind === "physical",
      readinessReason: reasons.length ? reasons.join(", ") : null,
    };
  });
}

function unavailableQuarantine(): QuarantineState {
  return {
    active: false,
    mode: null,
    reason: "Quarantine state unavailable",
    setAt: null,
    setBy: null,
    deviceUdid: null,
    clearAcknowledgement: QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
  };
}

function mapQuarantine(raw: unknown): QuarantineState {
  const root = asRecord(raw);
  const document = asRecord(root.document ?? root.quarantine ?? root);
  const reason = asOptionalString(document.reason);
  const mode = ["manual", "runner-maintenance", "device-maintenance"].includes(
    reason ?? ""
  )
    ? (reason as QuarantineMode)
    : (asOptionalString(document.mode) as QuarantineMode | null);
  return {
    active:
      root.quarantined === true ||
      document.status === "quarantined" ||
      root.active === true,
    mode: mode ?? null,
    reason: asOptionalString(document.detail) ?? reason,
    setAt: timestampMs(document.created_at ?? document.set_at),
    setBy: asOptionalString(document.set_by),
    deviceUdid: asOptionalString(document.device_udid),
    clearAcknowledgement: QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
  };
}

function mapAgentJob(
  record: Record<string, unknown>,
  fallback: JobRecord | null
): JobRecord {
  const request = asRecord(record.request);
  const status = normalizeJobStatus(asOptionalString(record.status));
  const now = Date.now();
  return {
    id:
      fallback?.id ??
      asOptionalString(request.run_id) ??
      asOptionalString(record.id) ??
      crypto.randomUUID(),
    scenario: fallback?.scenario ?? "canary",
    deviceUdid:
      fallback?.deviceUdid ??
      asOptionalString(asRecord(request.target).udid) ??
      "unknown",
    idempotencyKey: fallback?.idempotencyKey ?? crypto.randomUUID(),
    retryCount: fallback?.retryCount ?? numberValue(request.max_retries),
    attempt: numberValue(record.attempt),
    status,
    phase: asOptionalString(record.phase) ?? status,
    traceId:
      asOptionalString(record.session_trace_id) ?? fallback?.traceId ?? null,
    createdAt: timestampMs(record.created_at) ?? fallback?.createdAt ?? now,
    startedAt: timestampMs(record.started_at) ?? fallback?.startedAt ?? null,
    finishedAt:
      timestampMs(record.finished_at) ??
      (["succeeded", "failed", "cancelled", "timed_out"].includes(status)
        ? now
        : null),
    updatedAt: timestampMs(record.updated_at) ?? now,
    errorCode: asOptionalString(record.error_code),
    errorMessage: asOptionalString(record.error_message),
  };
}

export function duplicateJobResult(existing: JobRecord | null) {
  return existing ? { job: existing, duplicate: true as const } : null;
}

function mapLiveSession(
  record: Record<string, unknown>,
  rawEvents: unknown[]
): LiveSession {
  const request = asRecord(record.request);
  const sessionTraceId =
    asOptionalString(record.session_trace_id) ??
    asOptionalString(request.session_trace_id) ??
    crypto.randomUUID();
  return {
    id: asOptionalString(record.id) ?? "unknown",
    deviceUdid: asOptionalString(asRecord(request.target).udid) ?? "unknown",
    state: normalizeLiveState(asOptionalString(record.status)),
    bidiConnected: asRecord(record.bidi).connected === true,
    appiumSessionId: asOptionalString(record.appium_session_id),
    wdaState:
      asOptionalString(record.wda_state) === "healthy"
        ? "healthy"
        : asOptionalString(record.wda_state) === "offline"
          ? "offline"
          : "unknown",
    sessionTraceId,
    traceparent:
      asOptionalString(record.traceparent) ??
      `00-${sessionTraceId.replaceAll("-", "").padEnd(32, "0").slice(0, 32)}-0000000000000001-01`,
    startedAt:
      timestampMs(record.started_at ?? record.created_at) ?? Date.now(),
    expiresAt: timestampMs(record.lease_expires_at) ?? Date.now(),
    lastHeartbeatAt: timestampMs(record.updated_at) ?? Date.now(),
    lastScreenshotArtifactId: asOptionalString(
      record.last_screenshot_artifact_id
    ),
    stream: rawEvents.map((item, index) => {
      const event = asRecord(item);
      return {
        sequence: numberValue(event.id) || index + 1,
        timestamp: timestampMs(event.timestamp) ?? Date.now(),
        kind: normalizeStreamKind(asOptionalString(event.category)),
        operationTraceId:
          asOptionalString(event.operation_trace_id) ??
          asOptionalString(event.trace_id),
        summary:
          asOptionalString(event.summary) ??
          asOptionalString(event.name) ??
          "Live event",
        outcome:
          event.success === false
            ? "failure"
            : event.success === true
              ? "success"
              : "info",
      };
    }),
  };
}

function mapTrace(record: Record<string, unknown>): TraceRecord {
  const traceId =
    asOptionalString(record.session_trace_id) ??
    asOptionalString(record.trace_id) ??
    "unknown";
  return {
    traceId,
    traceparent:
      asOptionalString(record.traceparent) ??
      `00-${traceId.replaceAll("-", "").padEnd(32, "0").slice(0, 32)}-0000000000000001-01`,
    ownerType: record.owner_type === "live_session" ? "live_session" : "job",
    ownerId: asOptionalString(record.owner_id) ?? "unknown",
    status: asOptionalString(record.status) ?? "unknown",
    startedAt:
      timestampMs(record.started_at ?? record.created_at) ?? Date.now(),
    finishedAt: timestampMs(record.finished_at),
    timeline: [],
    recoveries: [],
    invariants: [],
  };
}

function mapTraceDetail(
  traceId: string,
  documentRaw: unknown,
  eventsRaw: unknown,
  analyticsRaw: unknown,
  recoveriesRaw: unknown
): TraceRecord {
  const document = asRecord(asRecord(documentRaw).trace ?? documentRaw);
  const base = mapTrace({ ...document, session_trace_id: traceId });
  const eventValues = Array.isArray(asRecord(eventsRaw).events)
    ? (asRecord(eventsRaw).events as unknown[])
    : [];
  const recoveryValues = Array.isArray(
    asRecord(recoveriesRaw).recovery_episodes
  )
    ? (asRecord(recoveriesRaw).recovery_episodes as unknown[])
    : [];
  const analytics = asRecord(asRecord(analyticsRaw).analytics);
  const invariants = Array.isArray(analytics.invariants)
    ? (analytics.invariants as unknown[])
    : [];
  return {
    ...base,
    timeline: eventValues.map((value, index) => {
      const event = asRecord(value);
      return {
        sequence: numberValue(event.sequence ?? event.id) || index + 1,
        timestamp: timestampMs(event.timestamp) ?? Date.now(),
        source: normalizeSource(asOptionalString(event.source)),
        eventType:
          asOptionalString(event.event_type) ??
          asOptionalString(event.name) ??
          "event",
        operationTraceId: asOptionalString(event.operation_trace_id),
        spanId: asOptionalString(event.span_id),
        outcome: asOptionalString(event.outcome) ?? "info",
        summary: asOptionalString(event.summary) ?? "Correlated trace event",
      };
    }),
    recoveries: recoveryValues.map(value => {
      const item = asRecord(value);
      return {
        id: asOptionalString(item.recovery_id) ?? crypto.randomUUID(),
        cause: asOptionalString(item.cause) ?? "unknown",
        outcome: asOptionalString(item.outcome) ?? "unknown",
        startedAt: timestampMs(item.started_at) ?? Date.now(),
        finishedAt: timestampMs(item.finished_at),
        evidenceArtifactIds: Array.isArray(item.evidence_references)
          ? item.evidence_references.filter(
              (v): v is string => typeof v === "string"
            )
          : [],
        summary: asOptionalString(item.summary) ?? "Recovery episode",
      };
    }),
    invariants: invariants.map(value => {
      const item = asRecord(value);
      return {
        key: asOptionalString(item.key) ?? "invariant",
        label:
          asOptionalString(item.label) ??
          asOptionalString(item.key) ??
          "Invariant",
        passed: item.passed === true,
        actual: String(item.actual ?? "unknown"),
        expected: String(item.expected ?? "unknown"),
      };
    }),
  };
}

function normalizeJobStatus(value: string | null): JobRecord["status"] {
  return [
    "queued",
    "preparing",
    "running",
    "cancelling",
    "succeeded",
    "failed",
    "cancelled",
    "timed_out",
  ].includes(value ?? "")
    ? (value as JobRecord["status"])
    : "queued";
}
function normalizeLiveState(value: string | null): LiveSession["state"] {
  return [
    "idle",
    "starting",
    "active",
    "recovering",
    "closing",
    "closed",
    "failed",
  ].includes(value ?? "")
    ? (value as LiveSession["state"])
    : "idle";
}
function normalizeAppium(value: string | null): AgentHealth["appiumState"] {
  return ["stopped", "starting", "healthy", "degraded"].includes(value ?? "")
    ? (value as AgentHealth["appiumState"])
    : "unknown";
}
function normalizeStreamKind(
  value: string | null
): LiveSession["stream"][number]["kind"] {
  return ["action", "observation", "bidi", "recovery", "system"].includes(
    value ?? ""
  )
    ? (value as LiveSession["stream"][number]["kind"])
    : "system";
}
function normalizeSource(
  value: string | null
): TraceRecord["timeline"][number]["source"] {
  return [
    "dashboard",
    "agent",
    "xcode",
    "appium",
    "wda",
    "bidi",
    "ios",
  ].includes(value ?? "")
    ? (value as TraceRecord["timeline"][number]["source"])
    : "agent";
}
function numberValue(value: unknown) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}
function timestampMs(value: unknown): number | null {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return null;
  return number < 10_000_000_000
    ? Math.round(number * 1000)
    : Math.round(number);
}
function mapGatewayError(error: unknown) {
  return error instanceof AgentGatewayError
    ? new TRPCError({
        code:
          error.status === 404
            ? "NOT_FOUND"
            : error.status === 400
              ? "BAD_REQUEST"
              : error.status === 409
                ? "CONFLICT"
                : error.status === 403
                  ? "FORBIDDEN"
                  : error.status === 504
                    ? "TIMEOUT"
                    : "SERVICE_UNAVAILABLE",
        message: error.message,
      })
    : new TRPCError({
        code: "INTERNAL_SERVER_ERROR",
        message: "Operator action failed.",
      });
}

export const operatorService = new OperatorService();
