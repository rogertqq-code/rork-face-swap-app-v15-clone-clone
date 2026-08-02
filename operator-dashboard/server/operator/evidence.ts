import { createHash } from "node:crypto";
import { gunzipSync } from "node:zlib";
import type { EvidenceArtifact } from "../../shared/operator";
import { storageGet, storagePut } from "../storage";
import { AgentGateway, asOptionalString, asRecord } from "./agentGateway";
import {
  getEvidenceSummary,
  listEvidenceArtifacts,
  upsertEvidenceSummary,
  upsertEvidenceArtifact,
} from "./persistence";

const MAX_ARCHIVE_BYTES = 64 * 1024 * 1024;
const MAX_EXPANDED_BYTES = 128 * 1024 * 1024;
const MAX_FILE_BYTES = 32 * 1024 * 1024;
const MAX_FILES = 1_000;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;

export class EvidenceVerificationError extends Error {
  constructor(
    public readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "EvidenceVerificationError";
  }
}

type TarEntry = { name: string; bytes: Uint8Array; type: string };
type ManifestArtifact = {
  relativePath: string;
  kind: string;
  byteSize: number;
  expectedSha256: string;
  mediaType: string;
  createdAt: number;
  redactionState: string;
};

export async function prepareVerifiedEvidence(input: {
  gateway: AgentGateway;
  ownerUserId: number;
  traceId: string;
}) {
  const exportRaw = await input.gateway.request<unknown>(
    "POST",
    `/api/v1/traces/${encodeURIComponent(input.traceId)}/evidence`,
    { timeoutMs: 120_000 }
  );
  const exportDocument = asRecord(asRecord(exportRaw).evidence);
  const expectedArchiveHash = asOptionalString(
    exportDocument.sha256
  )?.toLowerCase();
  const expectedArchiveSize = Number(exportDocument.byte_size);
  if (!expectedArchiveHash || !SHA256_PATTERN.test(expectedArchiveHash)) {
    throw new EvidenceVerificationError(
      "archive_hash_missing",
      "Evidence export did not report a valid SHA-256 digest."
    );
  }
  if (
    !Number.isSafeInteger(expectedArchiveSize) ||
    expectedArchiveSize <= 0 ||
    expectedArchiveSize > MAX_ARCHIVE_BYTES
  ) {
    throw new EvidenceVerificationError(
      "archive_size_invalid",
      "Evidence export size is invalid or exceeds the dashboard limit."
    );
  }

  const download = await input.gateway.requestBytes(
    `/api/v1/traces/${encodeURIComponent(input.traceId)}/evidence/download`,
    { timeoutMs: 120_000, maximumBytes: MAX_ARCHIVE_BYTES }
  );
  const observedArchiveHash = sha256(download.bytes);
  if (
    download.bytes.byteLength !== expectedArchiveSize ||
    observedArchiveHash !== expectedArchiveHash ||
    (download.expectedSha256 && download.expectedSha256 !== expectedArchiveHash)
  ) {
    throw new EvidenceVerificationError(
      "archive_verification_failed",
      "Evidence archive size or SHA-256 did not match the signed inventory."
    );
  }

  const entries = parseTarGzip(download.bytes);
  const manifestEntry = entries.find(item => item.name === "manifest.json");
  if (!manifestEntry) {
    throw new EvidenceVerificationError(
      "manifest_missing",
      "Evidence archive does not contain manifest.json."
    );
  }
  const manifest = parseManifest(manifestEntry.bytes, input.traceId);
  const files = new Map(entries.map(entry => [entry.name, entry]));
  const verifiedArtifacts: EvidenceArtifact[] = [];

  for (const manifestArtifact of manifest.artifacts) {
    const entry = files.get(manifestArtifact.relativePath);
    const artifactId = stableArtifactId(
      input.traceId,
      manifestArtifact.relativePath,
      manifestArtifact.expectedSha256
    );
    if (!entry) {
      const missing = artifactDocument(
        artifactId,
        input.traceId,
        manifestArtifact,
        false,
        "Artifact is listed in the manifest but missing from the archive.",
        null
      );
      await upsertEvidenceArtifact(missing, input.ownerUserId, null, null);
      verifiedArtifacts.push(missing);
      continue;
    }
    const observed = sha256(entry.bytes);
    const valid =
      entry.bytes.byteLength === manifestArtifact.byteSize &&
      observed === manifestArtifact.expectedSha256;
    if (!valid) {
      const failed = artifactDocument(
        artifactId,
        input.traceId,
        manifestArtifact,
        false,
        "Artifact bytes do not match manifest size or SHA-256.",
        null
      );
      await upsertEvidenceArtifact(failed, input.ownerUserId, null, observed);
      verifiedArtifacts.push(failed);
      continue;
    }

    const safeName = sanitizeStorageName(manifestArtifact.relativePath);
    const stored = await storagePut(
      `operator-evidence/${input.traceId}/${safeName}`,
      entry.bytes,
      manifestArtifact.mediaType
    );
    const verified = artifactDocument(
      artifactId,
      input.traceId,
      manifestArtifact,
      true,
      null,
      stored.url
    );
    await upsertEvidenceArtifact(
      verified,
      input.ownerUserId,
      stored.key,
      observed
    );
    verifiedArtifacts.push(verified);
  }

  const summary = {
    traceId: input.traceId,
    status: manifest.status,
    reasons: manifest.reasons,
    archive: {
      sizeBytes: expectedArchiveSize,
      sha256: expectedArchiveHash,
      manifestSha256: sha256(manifestEntry.bytes),
    },
    artifacts: verifiedArtifacts,
    counts: {
      total: verifiedArtifacts.length,
      verified: verifiedArtifacts.filter(item => item.verified).length,
      rejected: verifiedArtifacts.filter(item => !item.verified).length,
    },
  };
  await upsertEvidenceSummary({
    ownerUserId: input.ownerUserId,
    traceId: input.traceId,
    status: summary.status,
    reasons: summary.reasons,
    archiveSizeBytes: summary.archive.sizeBytes,
    archiveSha256: summary.archive.sha256,
    manifestSha256: summary.archive.manifestSha256,
    totalCount: summary.counts.total,
    verifiedCount: summary.counts.verified,
    rejectedCount: summary.counts.rejected,
    sanitizedCount: verifiedArtifacts.filter(item => item.sanitized).length,
  });
  return summary;
}

export async function persistedEvidenceInventory(
  ownerUserId: number,
  traceId: string
) {
  const rows = await listEvidenceArtifacts(ownerUserId, traceId);
  return Promise.all(
    rows.map(async row => {
      const download =
        row.verified && row.storageKey
          ? await storageGet(row.storageKey)
          : null;
      const artifact: EvidenceArtifact = {
        id: row.id,
        traceId: row.traceId,
        name: row.name,
        kind: row.kind,
        sizeBytes: row.sizeBytes,
        sha256: row.sha256,
        mediaType: row.mediaType,
        verified: row.verified && row.computedSha256 === row.sha256,
        verificationError: row.verificationError,
        sanitized: row.sanitized,
        createdAt: row.createdAtMs,
        downloadUrl:
          row.verified && row.computedSha256 === row.sha256
            ? (download?.url ?? null)
            : null,
      };
      return artifact;
    })
  );
}

export async function persistedEvidenceSummary(
  ownerUserId: number,
  traceId: string
) {
  return getEvidenceSummary(ownerUserId, traceId);
}

function parseTarGzip(bytes: Uint8Array): TarEntry[] {
  let expanded: Buffer;
  try {
    expanded = gunzipSync(bytes, { maxOutputLength: MAX_EXPANDED_BYTES });
  } catch {
    throw new EvidenceVerificationError(
      "archive_decompression_failed",
      "Evidence archive failed bounded gzip decompression."
    );
  }
  const entries: TarEntry[] = [];
  let offset = 0;
  while (offset + 512 <= expanded.length) {
    const header = expanded.subarray(offset, offset + 512);
    if (header.every(byte => byte === 0)) break;
    const name = readTarText(header.subarray(0, 100));
    const prefix = readTarText(header.subarray(345, 500));
    const fullName = prefix ? `${prefix}/${name}` : name;
    assertSafeArchivePath(fullName);
    const sizeText = readTarText(header.subarray(124, 136)).trim();
    const size = Number.parseInt(sizeText || "0", 8);
    if (!Number.isSafeInteger(size) || size < 0 || size > MAX_FILE_BYTES) {
      throw new EvidenceVerificationError(
        "archive_entry_size_invalid",
        "Evidence archive entry exceeds the per-file limit."
      );
    }
    const type = String.fromCharCode(header[156] ?? 0).replace("\0", "0");
    if (!["0", ""].includes(type)) {
      throw new EvidenceVerificationError(
        "archive_entry_type_rejected",
        "Evidence archive contains a non-regular entry."
      );
    }
    const bodyStart = offset + 512;
    const bodyEnd = bodyStart + size;
    if (bodyEnd > expanded.length) {
      throw new EvidenceVerificationError(
        "archive_truncated",
        "Evidence archive entry is truncated."
      );
    }
    entries.push({
      name: fullName,
      bytes: expanded.subarray(bodyStart, bodyEnd),
      type,
    });
    if (entries.length > MAX_FILES) {
      throw new EvidenceVerificationError(
        "archive_entry_count_exceeded",
        "Evidence archive contains too many files."
      );
    }
    offset = bodyStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function parseManifest(bytes: Uint8Array, traceId: string) {
  if (bytes.byteLength > 2 * 1024 * 1024) {
    throw new EvidenceVerificationError(
      "manifest_too_large",
      "Evidence manifest exceeds the configured byte limit."
    );
  }
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new EvidenceVerificationError(
      "manifest_invalid",
      "Evidence manifest is not valid UTF-8 JSON."
    );
  }
  const record = asRecord(raw);
  const manifestTrace =
    asOptionalString(record.session_trace_id) ??
    asOptionalString(record.trace_id);
  if (manifestTrace?.toLowerCase() !== traceId.toLowerCase()) {
    throw new EvidenceVerificationError(
      "manifest_trace_mismatch",
      "Evidence manifest root trace does not match the requested trace."
    );
  }
  const rawArtifacts = Array.isArray(record.artifacts) ? record.artifacts : [];
  if (rawArtifacts.length > MAX_FILES) {
    throw new EvidenceVerificationError(
      "manifest_artifact_count_exceeded",
      "Evidence manifest lists too many artifacts."
    );
  }
  const artifacts = rawArtifacts.map(value => {
    const item = asRecord(value);
    const relativePath = asOptionalString(item.relative_path) ?? "";
    assertSafeArchivePath(relativePath);
    const expectedSha256 = (
      asOptionalString(item.expected_sha256) ??
      asOptionalString(item.sha256) ??
      ""
    ).toLowerCase();
    if (!SHA256_PATTERN.test(expectedSha256)) {
      throw new EvidenceVerificationError(
        "manifest_artifact_hash_invalid",
        "Evidence manifest contains an invalid artifact SHA-256."
      );
    }
    const byteSize = Number(item.byte_size);
    if (
      !Number.isSafeInteger(byteSize) ||
      byteSize < 0 ||
      byteSize > MAX_FILE_BYTES
    ) {
      throw new EvidenceVerificationError(
        "manifest_artifact_size_invalid",
        "Evidence manifest contains an invalid artifact size."
      );
    }
    const artifact: ManifestArtifact = {
      relativePath,
      kind: asOptionalString(item.kind) ?? "artifact",
      byteSize,
      expectedSha256,
      mediaType:
        asOptionalString(item.content_type) ?? "application/octet-stream",
      createdAt: timestampMs(item.created_at),
      redactionState: asOptionalString(item.redaction_state) ?? "unknown",
    };
    return artifact;
  });
  return {
    status: asOptionalString(record.status) ?? "unknown",
    reasons: Array.isArray(record.reasons)
      ? record.reasons
          .filter((value): value is string => typeof value === "string")
          .slice(0, 100)
      : [],
    artifacts,
  };
}

function artifactDocument(
  id: string,
  traceId: string,
  source: ManifestArtifact,
  verified: boolean,
  verificationError: string | null,
  downloadUrl: string | null
): EvidenceArtifact {
  return {
    id,
    traceId,
    name: source.relativePath,
    kind: source.kind,
    sizeBytes: source.byteSize,
    sha256: source.expectedSha256,
    mediaType: source.mediaType,
    verified,
    verificationError,
    sanitized:
      source.redactionState === "redacted" ||
      source.redactionState === "sanitized",
    createdAt: source.createdAt,
    downloadUrl,
  };
}

function assertSafeArchivePath(value: string) {
  if (
    !value ||
    value.startsWith("/") ||
    value.startsWith("\\") ||
    value.includes("\\") ||
    value.split("/").some(part => !part || part === "." || part === "..") ||
    value.includes("\0") ||
    value.length > 512
  ) {
    throw new EvidenceVerificationError(
      "archive_path_rejected",
      "Evidence archive contains an unsafe path."
    );
  }
}

function sanitizeStorageName(value: string) {
  return value
    .replaceAll("/", "__")
    .replace(/[^A-Za-z0-9._-]/g, "_")
    .slice(0, 240);
}

function stableArtifactId(traceId: string, name: string, digest: string) {
  return sha256(new TextEncoder().encode(`${traceId}:${name}:${digest}`)).slice(
    0,
    64
  );
}

function sha256(bytes: Uint8Array) {
  return createHash("sha256").update(bytes).digest("hex");
}

function readTarText(bytes: Uint8Array) {
  const zero = bytes.indexOf(0);
  return Buffer.from(zero >= 0 ? bytes.subarray(0, zero) : bytes)
    .toString("utf8")
    .trim();
}

function timestampMs(value: unknown) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return Date.now();
  return number < 10_000_000_000
    ? Math.round(number * 1000)
    : Math.round(number);
}
