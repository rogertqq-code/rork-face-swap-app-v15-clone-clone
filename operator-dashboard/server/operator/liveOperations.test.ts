import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  OPERATOR_POLL_INTERVALS_MS,
  type EvidenceArtifact,
  type JobRecord,
} from "../../shared/operator";
import {
  liveActionInputSchema,
  liveObservationInputSchema,
} from "../routers/operator";
import { openLiveLease, sealLiveLease } from "./leaseVault";
import { selectLatestVerifiedScreenshot } from "./liveOperations";
import { duplicateJobResult } from "./service";

const originalSecret = process.env.JWT_SECRET;

function artifact(
  id: string,
  createdAt: number,
  overrides: Partial<EvidenceArtifact> = {}
): EvidenceArtifact {
  return {
    id,
    traceId: "9e92f38a-f08b-4265-aebd-86d434a6850d",
    name: `${id}.png`,
    kind: "live-screenshot",
    sizeBytes: 128,
    sha256: "a".repeat(64),
    mediaType: "image/png",
    verified: true,
    verificationError: null,
    sanitized: false,
    createdAt,
    downloadUrl: `/manus-storage/${id}.png`,
    ...overrides,
  };
}

describe("guarded live-operation contracts", () => {
  it("defines bounded live polling intervals for every operator feed", () => {
    expect(OPERATOR_POLL_INTERVALS_MS).toEqual({
      overview: 3_000,
      active: 2_000,
      index: 15_000,
      screenshot: 5_000,
    });
    expect(
      Math.max(...Object.values(OPERATOR_POLL_INTERVALS_MS))
    ).toBeLessThanOrEqual(15_000);
  });

  it("accepts only allowlisted live actions and enforces QA command shape", () => {
    expect(
      liveActionInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "query_app_state",
      }).success
    ).toBe(true);
    expect(
      liveActionInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "qa_command",
        command: { name: "snapshot" },
      }).success
    ).toBe(true);
    expect(
      liveActionInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "qa_command",
      }).success
    ).toBe(false);
    expect(
      liveActionInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "tap_arbitrary_coordinate",
      }).success
    ).toBe(false);
    expect(
      liveActionInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "query_app_state",
        command: { unexpected: true },
      }).success
    ).toBe(false);
  });

  it("accepts only the bounded observation allowlist", () => {
    expect(
      liveObservationInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "screenshot",
      }).success
    ).toBe(true);
    expect(
      liveObservationInputSchema.safeParse({
        sessionId: "live-session-1",
        kind: "unbounded_video_stream",
      }).success
    ).toBe(false);
  });

  it("selects the most recent verified image independently of input order", () => {
    const selected = selectLatestVerifiedScreenshot([
      artifact("older", 1_700_000_000_000),
      artifact("newest-rejected", 1_700_000_003_000, {
        verified: false,
        downloadUrl: null,
      }),
      artifact("newest-valid", 1_700_000_002_000),
      artifact("newer-non-image", 1_700_000_004_000, {
        mediaType: "application/json",
      }),
      artifact("middle", 1_700_000_001_000),
    ]);
    expect(selected?.id).toBe("newest-valid");
  });

  it("returns no screenshot when every candidate is unverified or linkless", () => {
    expect(
      selectLatestVerifiedScreenshot([
        artifact("rejected", 10, { verified: false }),
        artifact("linkless", 20, { downloadUrl: null }),
      ])
    ).toBeNull();
  });
});

describe("idempotent job submission", () => {
  it("returns the original job as a duplicate without replacement work", () => {
    const job: JobRecord = {
      id: "job-1",
      scenario: "canary",
      deviceUdid: "00008110-001234567890001E",
      idempotencyKey: "9e92f38a-f08b-4265-aebd-86d434a6850d",
      retryCount: 0,
      attempt: 0,
      status: "queued",
      phase: "Queued",
      traceId: "6af129ea-8f96-4e45-b546-cbcb99134fe3",
      createdAt: 1,
      startedAt: null,
      finishedAt: null,
      updatedAt: 1,
      errorCode: null,
      errorMessage: null,
    };
    expect(duplicateJobResult(job)).toEqual({ job, duplicate: true });
    expect(duplicateJobResult(null)).toBeNull();
  });
});

describe("encrypted live-session lease vault", () => {
  beforeEach(() => {
    process.env.JWT_SECRET =
      "test-only-jwt-secret-with-at-least-thirty-two-characters";
  });

  afterEach(() => {
    if (originalSecret === undefined) delete process.env.JWT_SECRET;
    else process.env.JWT_SECRET = originalSecret;
  });

  it("round-trips a lease without exposing it in the sealed value", () => {
    const token = "lease-token-that-never-crosses-the-browser-boundary";
    const sealed = sealLiveLease("live-session-1", token);
    expect(sealed).not.toContain(token);
    expect(openLiveLease("live-session-1", sealed)).toBe(token);
  });

  it("binds ciphertext to the live session and rejects tampering", () => {
    const sealed = sealLiveLease(
      "live-session-1",
      "lease-token-that-never-crosses-the-browser-boundary"
    );
    expect(() => openLiveLease("live-session-2", sealed)).toThrow(
      "Stored live lease credential could not be opened."
    );
    const last = sealed.at(-1) === "A" ? "B" : "A";
    expect(() =>
      openLiveLease("live-session-1", `${sealed.slice(0, -1)}${last}`)
    ).toThrow("Stored live lease credential could not be opened.");
  });
});
