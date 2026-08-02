import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AgentGateway } from "./agentGateway";

const { storagePut, upsertEvidenceArtifact, upsertEvidenceSummary } =
  vi.hoisted(() => ({
    storagePut: vi.fn(),
    upsertEvidenceArtifact: vi.fn(),
    upsertEvidenceSummary: vi.fn(),
  }));

vi.mock("../storage", () => ({
  storagePut,
  storageGet: vi.fn(async (key: string) => ({
    key,
    url: `/manus-storage/${key}`,
  })),
}));

vi.mock("./persistence", () => ({
  upsertEvidenceArtifact,
  upsertEvidenceSummary,
  listEvidenceArtifacts: vi.fn(async () => []),
  getEvidenceSummary: vi.fn(async () => null),
}));

import { EvidenceVerificationError, prepareVerifiedEvidence } from "./evidence";

function sha256(bytes: Uint8Array) {
  return createHash("sha256").update(bytes).digest("hex");
}

function octal(value: number, width: number) {
  return value.toString(8).padStart(width - 1, "0") + "\0";
}

function tarEntry(name: string, bytes: Uint8Array) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "utf8");
  header.write(octal(0o600, 8), 100, 8, "ascii");
  header.write(octal(0, 8), 108, 8, "ascii");
  header.write(octal(0, 8), 116, 8, "ascii");
  header.write(octal(bytes.byteLength, 12), 124, 12, "ascii");
  header.write(octal(0, 12), 136, 12, "ascii");
  header.fill(0x20, 148, 156);
  header.write("0", 156, 1, "ascii");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  header.write(checksum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
  const padding = Buffer.alloc((512 - (bytes.byteLength % 512)) % 512);
  return Buffer.concat([header, Buffer.from(bytes), padding]);
}

function archiveFixture(options?: {
  relativePath?: string;
  artifactHash?: string;
  traceId?: string;
}) {
  const traceId = options?.traceId ?? "9e92f38a-f08b-4265-aebd-86d434a6850d";
  const fileBytes = Buffer.from("redacted operator log\n", "utf8");
  const relativePath = options?.relativePath ?? "logs/run.log";
  const expected = options?.artifactHash ?? sha256(fileBytes);
  const manifest = Buffer.from(
    JSON.stringify({
      session_trace_id: traceId,
      status: "complete",
      reasons: [],
      artifacts: [
        {
          relative_path: relativePath,
          kind: "log",
          byte_size: fileBytes.byteLength,
          expected_sha256: expected,
          content_type: "text/plain",
          created_at: 1_700_000_000,
          redaction_state: "redacted",
        },
      ],
    }),
    "utf8"
  );
  const tar = Buffer.concat([
    tarEntry("manifest.json", manifest),
    tarEntry(relativePath, fileBytes),
    Buffer.alloc(1024),
  ]);
  const archive = gzipSync(tar, { mtime: 0 });
  return { traceId, fileBytes, archive };
}

function gatewayFor(archive: Uint8Array, expectedHash = sha256(archive)) {
  return {
    request: vi.fn(async () => ({
      evidence: {
        byte_size: archive.byteLength,
        sha256: expectedHash,
      },
    })),
    requestBytes: vi.fn(async () => ({
      bytes: archive,
      contentType: "application/gzip",
      expectedSha256: expectedHash,
    })),
  } as unknown as AgentGateway;
}

describe("verified evidence preparation", () => {
  beforeEach(() => {
    storagePut.mockReset();
    upsertEvidenceArtifact.mockReset();
    upsertEvidenceSummary.mockReset();
    storagePut.mockResolvedValue({
      key: "operator-evidence/trace/log.txt_abc12345",
      url: "/manus-storage/operator-evidence/trace/log.txt_abc12345",
    });
    upsertEvidenceArtifact.mockResolvedValue(undefined);
    upsertEvidenceSummary.mockResolvedValue(undefined);
  });

  it("surfaces a link only after archive and per-file SHA-256 verification", async () => {
    const fixture = archiveFixture();
    const result = await prepareVerifiedEvidence({
      gateway: gatewayFor(fixture.archive),
      ownerUserId: 1,
      traceId: fixture.traceId,
    });

    expect(result.counts).toEqual({ total: 1, verified: 1, rejected: 0 });
    expect(result.archive.sha256).toBe(sha256(fixture.archive));
    expect(result.artifacts[0]).toMatchObject({
      name: "logs/run.log",
      verified: true,
      sanitized: true,
      downloadUrl: "/manus-storage/operator-evidence/trace/log.txt_abc12345",
    });
    expect(storagePut).toHaveBeenCalledWith(
      expect.stringContaining("operator-evidence/"),
      fixture.fileBytes,
      "text/plain"
    );
    expect(upsertEvidenceArtifact).toHaveBeenCalledWith(
      expect.objectContaining({ verified: true }),
      1,
      "operator-evidence/trace/log.txt_abc12345",
      sha256(fixture.fileBytes)
    );
    expect(upsertEvidenceSummary).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerUserId: 1,
        traceId: fixture.traceId,
        totalCount: 1,
        verifiedCount: 1,
        rejectedCount: 0,
        sanitizedCount: 1,
        archiveSha256: sha256(fixture.archive),
      })
    );
  });

  it("persists a rejected artifact and never uploads mismatched file bytes", async () => {
    const fixture = archiveFixture({ artifactHash: "a".repeat(64) });
    const result = await prepareVerifiedEvidence({
      gateway: gatewayFor(fixture.archive),
      ownerUserId: 1,
      traceId: fixture.traceId,
    });
    expect(result.counts).toEqual({ total: 1, verified: 0, rejected: 1 });
    expect(result.artifacts[0]?.downloadUrl).toBeNull();
    expect(storagePut).not.toHaveBeenCalled();
    expect(upsertEvidenceArtifact).toHaveBeenCalledWith(
      expect.objectContaining({
        verified: false,
        verificationError: expect.stringContaining("SHA-256"),
      }),
      1,
      null,
      sha256(fixture.fileBytes)
    );
  });

  it("rejects an archive-level SHA-256 mismatch before extraction", async () => {
    const fixture = archiveFixture();
    await expect(
      prepareVerifiedEvidence({
        gateway: gatewayFor(fixture.archive, "b".repeat(64)),
        ownerUserId: 1,
        traceId: fixture.traceId,
      })
    ).rejects.toMatchObject({ code: "archive_verification_failed" });
    expect(storagePut).not.toHaveBeenCalled();
  });

  it("rejects traversal paths before any storage operation", async () => {
    const fixture = archiveFixture({ relativePath: "../private/token.txt" });
    await expect(
      prepareVerifiedEvidence({
        gateway: gatewayFor(fixture.archive),
        ownerUserId: 1,
        traceId: fixture.traceId,
      })
    ).rejects.toBeInstanceOf(EvidenceVerificationError);
    expect(storagePut).not.toHaveBeenCalled();
  });
});
