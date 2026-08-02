import type { ActivationGate, PolicyCheck } from "../../shared/operator";
import {
  AgentGateway,
  AgentGatewayError,
  asOptionalString,
  asRecord,
} from "./agentGateway";

const REQUIRED_CHECKS = [
  ["repository_private", "Repository is private"],
  ["default_branch_main", "Default branch is main"],
  ["protected_environment", "Protected physical-device environment"],
  ["environment_reviewers", "Required environment reviewers"],
  ["workflow_permissions_restricted", "Restricted workflow permissions"],
  ["activation_variable", "Physical-device activation variable"],
  ["dedicated_runner", "Eligible dedicated Mac runner"],
] as const;

export async function evaluateActivationGate(
  gateway: AgentGateway
): Promise<ActivationGate> {
  const now = Date.now();
  const configuration = gateway.getConfiguration();
  if (!configuration.valid) {
    return unavailableGate(configuration.detail, now, configuration.configured);
  }

  try {
    const raw = await gateway.request<unknown>("GET", "/api/v1/github/policy");
    const report = asRecord(raw);
    const rawChecks = Array.isArray(report.checks) ? report.checks : [];
    const indexed = new Map<string, Record<string, unknown>>();
    for (const item of rawChecks) {
      const record = asRecord(item);
      const key = asOptionalString(record.name) ?? asOptionalString(record.key);
      if (key) indexed.set(key, record);
    }
    const checks: PolicyCheck[] = [
      {
        key: "gateway_reachable",
        label: "Mac-agent gateway reachable",
        passed: true,
        required: true,
        detail: "Authenticated policy response received from the Mac agent.",
        checkedAt: now,
      },
      ...REQUIRED_CHECKS.map(([key, label]) => {
        const item = indexed.get(key);
        return {
          key,
          label,
          passed: item?.passed === true,
          required: true as const,
          detail:
            asOptionalString(item?.detail) ??
            `Required policy check '${key}' was not reported.`,
          checkedAt: now,
        };
      }),
    ];
    const failedChecks = checks
      .filter(item => !item.passed)
      .map(item => item.key);
    const repository =
      asOptionalString(report.repository) ?? "repository unavailable";
    const repositoryPrivate =
      indexed.get("repository_private")?.passed === true;
    const reportPassed = report.status === "pass" || report.passed === true;
    const open = reportPassed && failedChecks.length === 0;
    return {
      open,
      state: open ? "open" : "blocked",
      summary: open
        ? "Every required repository, environment, and runner control passed."
        : "One or more required GitHub activation controls failed or were not reported.",
      repository,
      repositoryPrivate,
      failedChecks,
      checks,
      checkedAt: now,
    };
  } catch (error) {
    const detail =
      error instanceof AgentGatewayError
        ? `${error.code}: ${error.message}`
        : "Policy verifier request failed.";
    return unavailableGate(detail, now, true);
  }
}

function unavailableGate(
  detail: string,
  checkedAt: number,
  configured: boolean
): ActivationGate {
  const checks: PolicyCheck[] = [
    {
      key: "gateway_configured",
      label: "Mac-agent gateway configured",
      passed: configured,
      required: true,
      detail,
      checkedAt,
    },
    {
      key: "gateway_reachable",
      label: "Mac-agent gateway reachable",
      passed: false,
      required: true,
      detail: "No authenticated policy response is available.",
      checkedAt,
    },
    ...REQUIRED_CHECKS.map(([key, label]) => ({
      key,
      label,
      passed: false,
      required: true as const,
      detail: "Unavailable checks fail closed.",
      checkedAt,
    })),
  ];
  return {
    open: false,
    state: "unavailable",
    summary:
      "Activation policy is unavailable; all protected controls are blocked.",
    repository: "repository unavailable",
    repositoryPrivate: false,
    failedChecks: checks.filter(item => !item.passed).map(item => item.key),
    checks,
    checkedAt,
  };
}
