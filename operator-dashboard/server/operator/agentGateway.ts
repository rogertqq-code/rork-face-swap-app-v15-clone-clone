import { randomUUID } from "node:crypto";

const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_JSON_BYTES = 2 * 1024 * 1024;
const MAX_REQUEST_BYTES = 256 * 1024;
const MAX_JSON_DEPTH = 32;
const MAX_JSON_NODES = 20_000;

type HttpMethod = "GET" | "POST" | "DELETE";
type FetchLike = typeof fetch;

export type GatewayConfiguration = {
  mode: "direct" | "unconfigured";
  configured: boolean;
  valid: boolean;
  baseUrl: string | null;
  errorCode: string | null;
  detail: string;
};

export class AgentGatewayError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly status: number
  ) {
    super(message);
    this.name = "AgentGatewayError";
  }
}

export class AgentGateway {
  private readonly fetchImpl: FetchLike;
  private readonly timeoutMs: number;
  private readonly token: string | null;
  private readonly baseUrl: URL | null;
  private readonly configuration: GatewayConfiguration;

  constructor(options?: {
    baseUrl?: string;
    token?: string;
    fetchImpl?: FetchLike;
    timeoutMs?: number;
  }) {
    this.fetchImpl = options?.fetchImpl ?? fetch;
    this.timeoutMs = Math.min(
      60_000,
      Math.max(1_000, options?.timeoutMs ?? DEFAULT_TIMEOUT_MS)
    );
    const rawBaseUrl = options?.baseUrl ?? process.env.MAC_AGENT_BASE_URL ?? "";
    const rawToken = options?.token ?? process.env.MAC_AGENT_API_TOKEN ?? "";
    this.token = rawToken || null;

    if (!rawBaseUrl || !rawToken) {
      this.baseUrl = null;
      this.configuration = {
        mode: "unconfigured",
        configured: false,
        valid: false,
        baseUrl: null,
        errorCode: "gateway_unconfigured",
        detail: "Mac-agent URL and bearer token are not configured.",
      };
      return;
    }

    try {
      const parsed = new URL(rawBaseUrl);
      const invalid =
        parsed.protocol !== "https:" ||
        parsed.username.length > 0 ||
        parsed.password.length > 0 ||
        parsed.search.length > 0 ||
        parsed.hash.length > 0 ||
        !["", "/"].includes(parsed.pathname) ||
        rawToken.length < 32 ||
        rawToken.length > 512;
      if (invalid) throw new Error("invalid secure gateway configuration");
      parsed.pathname = "/";
      this.baseUrl = parsed;
      this.configuration = {
        mode: "direct",
        configured: true,
        valid: true,
        baseUrl: parsed.origin,
        errorCode: null,
        detail: "Private HTTPS Mac-agent gateway configured.",
      };
    } catch {
      this.baseUrl = null;
      this.configuration = {
        mode: "unconfigured",
        configured: true,
        valid: false,
        baseUrl: null,
        errorCode: "gateway_configuration_invalid",
        detail:
          "Mac-agent configuration must use a credential-free HTTPS origin and a private token.",
      };
    }
  }

  getConfiguration(): GatewayConfiguration {
    return { ...this.configuration };
  }

  async request<T>(
    method: HttpMethod,
    path: string,
    options?: {
      body?: unknown;
      idempotencyKey?: string;
      leaseToken?: string;
      timeoutMs?: number;
      maximumBytes?: number;
    }
  ): Promise<T> {
    if (!this.baseUrl || !this.token || !this.configuration.valid) {
      throw new AgentGatewayError(
        this.configuration.errorCode ?? "gateway_unconfigured",
        this.configuration.detail,
        503
      );
    }

    const url = this.safeUrl(path);
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      Math.min(120_000, Math.max(1_000, options?.timeoutMs ?? this.timeoutMs))
    );
    let body: string | undefined;
    if (options?.body !== undefined) {
      body = JSON.stringify(options.body);
      if (Buffer.byteLength(body, "utf8") > MAX_REQUEST_BYTES) {
        clearTimeout(timeout);
        throw new AgentGatewayError(
          "gateway_request_too_large",
          "Mac-agent request exceeds the bounded JSON limit.",
          413
        );
      }
    }

    try {
      const response = await this.fetchImpl(url, {
        method,
        signal: controller.signal,
        redirect: "error",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
          "X-Request-ID": randomUUID(),
          ...(options?.idempotencyKey
            ? { "Idempotency-Key": options.idempotencyKey }
            : {}),
          ...(options?.leaseToken
            ? { "X-Live-Lease-Token": options.leaseToken }
            : {}),
        },
        body,
      });
      const bytes = await readBounded(
        response,
        options?.maximumBytes ?? MAX_JSON_BYTES
      );
      const document = parseBoundedJson(bytes);
      if (!response.ok) {
        const record = asRecord(document);
        const error = asRecord(record.error);
        const code =
          asOptionalString(error.code) ??
          asOptionalString(record.code) ??
          "gateway_remote_error";
        const message =
          asOptionalString(error.message) ??
          asOptionalString(record.message) ??
          `Mac-agent request failed with HTTP ${response.status}.`;
        throw new AgentGatewayError(code, message, response.status);
      }
      return document as T;
    } catch (error) {
      if (error instanceof AgentGatewayError) throw error;
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new AgentGatewayError(
          "gateway_timeout",
          "Mac-agent request exceeded the configured timeout.",
          504
        );
      }
      throw new AgentGatewayError(
        "gateway_unreachable",
        "Mac-agent gateway is unreachable.",
        503
      );
    } finally {
      clearTimeout(timeout);
    }
  }

  async requestBytes(
    path: string,
    options?: { timeoutMs?: number; maximumBytes?: number }
  ): Promise<{
    bytes: Uint8Array;
    contentType: string;
    expectedSha256: string | null;
  }> {
    if (!this.baseUrl || !this.token || !this.configuration.valid) {
      throw new AgentGatewayError(
        this.configuration.errorCode ?? "gateway_unconfigured",
        this.configuration.detail,
        503
      );
    }
    const url = this.safeUrl(path);
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      Math.min(180_000, Math.max(1_000, options?.timeoutMs ?? 60_000))
    );
    try {
      const response = await this.fetchImpl(url, {
        method: "GET",
        signal: controller.signal,
        redirect: "error",
        headers: {
          Accept: "application/octet-stream,application/gzip",
          Authorization: `Bearer ${this.token}`,
          "X-Request-ID": randomUUID(),
        },
      });
      const bytes = await readBounded(
        response,
        options?.maximumBytes ?? 64 * 1024 * 1024
      );
      if (!response.ok) {
        let message = `Mac-agent evidence request failed with HTTP ${response.status}.`;
        try {
          const record = asRecord(parseBoundedJson(bytes));
          message = asOptionalString(asRecord(record.error).message) ?? message;
        } catch {
          // Preserve the deterministic HTTP error when the body is not JSON.
        }
        throw new AgentGatewayError(
          "gateway_evidence_download_failed",
          message,
          response.status
        );
      }
      return {
        bytes,
        contentType:
          response.headers.get("content-type") ?? "application/octet-stream",
        expectedSha256:
          response.headers.get("x-content-sha256")?.toLowerCase() ?? null,
      };
    } catch (error) {
      if (error instanceof AgentGatewayError) throw error;
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new AgentGatewayError(
          "gateway_timeout",
          "Mac-agent evidence request exceeded the configured timeout.",
          504
        );
      }
      throw new AgentGatewayError(
        "gateway_unreachable",
        "Mac-agent evidence endpoint is unreachable.",
        503
      );
    } finally {
      clearTimeout(timeout);
    }
  }

  private safeUrl(path: string): URL {
    if (
      !path.startsWith("/api/v1/") ||
      path.includes("..") ||
      path.includes("\\") ||
      /[\r\n]/.test(path)
    ) {
      throw new AgentGatewayError(
        "gateway_path_invalid",
        "Mac-agent path is outside the allowlisted API namespace.",
        400
      );
    }
    const url = new URL(path, this.baseUrl!);
    if (url.origin !== this.baseUrl!.origin) {
      throw new AgentGatewayError(
        "gateway_origin_mismatch",
        "Mac-agent request origin mismatch.",
        400
      );
    }
    return url;
  }
}

async function readBounded(response: Response, maximumBytes: number) {
  const contentLength = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maximumBytes) {
    throw new AgentGatewayError(
      "gateway_response_too_large",
      "Mac-agent response exceeds the configured byte limit.",
      502
    );
  }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw new AgentGatewayError(
        "gateway_response_too_large",
        "Mac-agent response exceeds the configured byte limit.",
        502
      );
    }
    chunks.push(value);
  }
  const output = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

function parseBoundedJson(bytes: Uint8Array): unknown {
  if (bytes.byteLength === 0) return {};
  let document: unknown;
  try {
    document = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes)
    );
  } catch {
    throw new AgentGatewayError(
      "gateway_json_invalid",
      "Mac-agent returned invalid JSON.",
      502
    );
  }
  assertJsonComplexity(document);
  return document;
}

function assertJsonComplexity(value: unknown) {
  const stack: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  let nodes = 0;
  while (stack.length) {
    const current = stack.pop()!;
    nodes += 1;
    if (nodes > MAX_JSON_NODES || current.depth > MAX_JSON_DEPTH) {
      throw new AgentGatewayError(
        "gateway_json_complexity_exceeded",
        "Mac-agent JSON exceeds depth or node limits.",
        502
      );
    }
    if (Array.isArray(current.value)) {
      for (const child of current.value) {
        stack.push({ value: child, depth: current.depth + 1 });
      }
    } else if (current.value && typeof current.value === "object") {
      for (const child of Object.values(current.value)) {
        stack.push({ value: child, depth: current.depth + 1 });
      }
    }
  }
}

export function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function asOptionalString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

export const agentGateway = new AgentGateway();
