import { describe, expect, it } from "vitest";
import type { TrpcContext } from "../_core/context";
import { appRouter } from "../routers";
import {
  QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
  jobSubmissionSchema,
  quarantineClearSchema,
} from "../../shared/operator";
import { AgentGateway, AgentGatewayError } from "./agentGateway";
import { evaluateActivationGate } from "./policy";
import { OperatorService } from "./service";

const token = "x".repeat(48);

function jsonResponse(document: unknown, status = 200) {
  return new Response(JSON.stringify(document), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function userContext(user: TrpcContext["user"]): TrpcContext {
  return {
    user,
    req: { protocol: "https", headers: {} } as TrpcContext["req"],
    res: {} as TrpcContext["res"],
  };
}

const baseUser = {
  id: 7,
  openId: "not-the-owner",
  email: "operator@example.test",
  name: "Operator",
  loginMethod: "manus",
  role: "admin" as const,
  createdAt: new Date(),
  updatedAt: new Date(),
  lastSignedIn: new Date(),
};

describe("owner-only authorization", () => {
  it("denies unauthenticated operator procedures", async () => {
    const caller = appRouter.createCaller(userContext(null));
    await expect(caller.operator.overview()).rejects.toMatchObject({
      code: "UNAUTHORIZED",
    });
  });

  it("denies an admin who is not the configured owner", async () => {
    const caller = appRouter.createCaller(userContext(baseUser));
    await expect(caller.operator.overview()).rejects.toMatchObject({
      code: "FORBIDDEN",
    });
  });

  it("denies a non-admin even when the identity shape is valid", async () => {
    const caller = appRouter.createCaller(
      userContext({ ...baseUser, role: "user" })
    );
    await expect(caller.operator.overview()).rejects.toMatchObject({
      code: "FORBIDDEN",
    });
  });
});

describe("closed operator inputs", () => {
  it("accepts the full job contract and preserves the visible idempotency key", () => {
    const idempotencyKey = crypto.randomUUID();
    const result = jobSubmissionSchema.parse({
      scenario: "hardware",
      deviceUdid: "00008110-001234567890001E",
      retryCount: 2,
      idempotencyKey,
    });
    expect(result.idempotencyKey).toBe(idempotencyKey);
  });

  it("rejects unknown scenarios, excessive retries, and malformed UDIDs", () => {
    expect(() =>
      jobSubmissionSchema.parse({
        scenario: "arbitrary-shell",
        deviceUdid: "../../device",
        retryCount: 99,
        idempotencyKey: "not-a-uuid",
      })
    ).toThrow();
  });

  it("requires the exact quarantine acknowledgement", () => {
    expect(
      quarantineClearSchema.parse({
        acknowledgement: QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
      })
    ).toEqual({ acknowledgement: QUARANTINE_CLEAR_ACKNOWLEDGEMENT });
    expect(() =>
      quarantineClearSchema.parse({ acknowledgement: "clear quarantine" })
    ).toThrow();
  });
});

describe("bounded Mac-agent gateway", () => {
  it("is explicitly unconfigured and fail-closed without credentials", async () => {
    const gateway = new AgentGateway({ baseUrl: "", token: "" });
    expect(gateway.getConfiguration()).toMatchObject({
      mode: "unconfigured",
      configured: false,
      valid: false,
      errorCode: "gateway_unconfigured",
    });
    await expect(
      gateway.request("GET", "/api/v1/health")
    ).rejects.toMatchObject({
      code: "gateway_unconfigured",
    });
  });

  it("rejects insecure URLs and embedded credentials", () => {
    expect(
      new AgentGateway({
        baseUrl: "http://mac.example.test",
        token,
      }).getConfiguration()
    ).toMatchObject({
      valid: false,
      errorCode: "gateway_configuration_invalid",
    });
    expect(
      new AgentGateway({
        baseUrl: "https://user:pass@mac.example.test",
        token,
      }).getConfiguration()
    ).toMatchObject({
      valid: false,
      errorCode: "gateway_configuration_invalid",
    });
  });

  it("sends the token server-side and accepts bounded valid JSON", async () => {
    let authorization = "";
    let observedUrl = "";
    const gateway = new AgentGateway({
      baseUrl: "https://mac.example.test",
      token,
      fetchImpl: async (input, init) => {
        observedUrl = String(input);
        authorization = new Headers(init?.headers).get("authorization") ?? "";
        return jsonResponse({ status: "ok" });
      },
    });
    await expect(gateway.request("GET", "/api/v1/health")).resolves.toEqual({
      status: "ok",
    });
    expect(observedUrl).toBe("https://mac.example.test/api/v1/health");
    expect(authorization).toBe(`Bearer ${token}`);
  });

  it("rejects paths outside the allowlisted API namespace", async () => {
    const gateway = new AgentGateway({
      baseUrl: "https://mac.example.test",
      token,
      fetchImpl: async () => jsonResponse({ ok: true }),
    });
    await expect(
      gateway.request("GET", "/admin/secrets")
    ).rejects.toBeInstanceOf(AgentGatewayError);
    await expect(
      gateway.request("GET", "/api/v1/../admin/secrets")
    ).rejects.toMatchObject({ code: "gateway_path_invalid" });
  });

  it("rejects an oversized response before JSON parsing", async () => {
    const gateway = new AgentGateway({
      baseUrl: "https://mac.example.test",
      token,
      fetchImpl: async () =>
        new Response("{}", {
          status: 200,
          headers: { "content-length": String(3 * 1024 * 1024) },
        }),
    });
    await expect(
      gateway.request("GET", "/api/v1/health")
    ).rejects.toMatchObject({
      code: "gateway_response_too_large",
    });
  });
});

describe("fail-closed activation policy", () => {
  it("reports every required check as failed when the gateway is unavailable", async () => {
    const gate = await evaluateActivationGate(
      new AgentGateway({ baseUrl: "", token: "" })
    );
    expect(gate.open).toBe(false);
    expect(gate.state).toBe("unavailable");
    expect(gate.checks.length).toBeGreaterThanOrEqual(9);
    expect(gate.checks.every(item => item.required)).toBe(true);
    expect(gate.failedChecks).toContain("repository_private");
  });

  it("opens only when every named check and the report status pass", async () => {
    const names = [
      "repository_private",
      "default_branch_main",
      "protected_environment",
      "environment_reviewers",
      "workflow_permissions_restricted",
      "activation_variable",
      "dedicated_runner",
    ];
    const gateway = new AgentGateway({
      baseUrl: "https://mac.example.test",
      token,
      fetchImpl: async () =>
        jsonResponse({
          status: "pass",
          repository: "owner/private-repository",
          checks: names.map(name => ({ name, passed: true, detail: "pass" })),
        }),
    });
    const gate = await evaluateActivationGate(gateway);
    expect(gate).toMatchObject({
      open: true,
      state: "open",
      repositoryPrivate: true,
      failedChecks: [],
    });
  });

  it("blocks when one required check is missing even if the report claims pass", async () => {
    const gateway = new AgentGateway({
      baseUrl: "https://mac.example.test",
      token,
      fetchImpl: async () =>
        jsonResponse({
          status: "pass",
          checks: [
            { name: "repository_private", passed: true, detail: "pass" },
          ],
        }),
    });
    const gate = await evaluateActivationGate(gateway);
    expect(gate.open).toBe(false);
    expect(gate.state).toBe("blocked");
    expect(gate.failedChecks).toContain("dedicated_runner");
  });

  it("blocks live, quarantine, and evidence mutations when policy is unavailable", async () => {
    const service = new OperatorService(
      new AgentGateway({ baseUrl: "", token: "" })
    );
    await expect(
      service.openLiveSession(
        1,
        "00008110-001234567890001E",
        crypto.randomUUID()
      )
    ).rejects.toMatchObject({ code: "PRECONDITION_FAILED" });
    await expect(
      service.setQuarantine(1, "manual", "Manual policy test quarantine")
    ).rejects.toMatchObject({ code: "PRECONDITION_FAILED" });
    await expect(
      service.clearQuarantine(1, QUARANTINE_CLEAR_ACKNOWLEDGEMENT)
    ).rejects.toMatchObject({ code: "PRECONDITION_FAILED" });
    await expect(
      service.prepareEvidence(1, "9e92f38a-f08b-4265-aebd-86d434a6850d")
    ).rejects.toMatchObject({ code: "PRECONDITION_FAILED" });
  });
});
