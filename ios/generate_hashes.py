#!/usr/bin/env python3
"""
ONE-TIME LOCAL GENERATOR FOR THE OFFLINE BETA GATE (Python).
Produces ios/FaceSwapLiveAppV12/Gatekeeper/EmbeddedCodeHashes.swift
from ios/valid_codes.txt.

IMPORTANT — performance/design:
  Every stored entry shares ONE app-wide Argon2id salt. This lets the app
  compute Argon2id exactly ONCE per login attempt and then do a fast
  constant-time membership check against the embedded digests. Using a unique
  salt per code (the previous approach) forced the app to recompute Argon2id
  1,001 times per attempt, which took minutes-to-tens-of-minutes on device.

  A shared, app-specific salt still blocks generic precomputed (rainbow-table)
  attacks, and the per-guess Argon2id cost (the real protection for a 6-digit
  keyspace baked into a shipped binary) is fully preserved.

Argon2id parameters: memory=4096 KiB, iterations=3, parallelism=2, tag=32 bytes.
Master override 323207 is hashed separately and is NOT counted among the
1,000 one-time beta codes (it never burns a beta slot).

SECURITY: Delete plaintext code material (ios/valid_codes.txt) and this
generator before shipping or sharing source.
"""

import os
import sys
import base64
import secrets

from argon2.low_level import hash_secret_raw, Type

CODES_PATH = "ios/valid_codes.txt"
OUTPUT_PATH = "ios/FaceSwapLiveAppV12/Gatekeeper/EmbeddedCodeHashes.swift"
EXPECTED_COUNT = 1_000
MASTER_CODE = "323207"

MEMORY_KIB = 4096
ITERATIONS = 3
PARALLELISM = 2
TAG_LENGTH = 32
SALT_LENGTH = 16


def read_codes(path: str) -> list[str]:
    if not os.path.exists(path):
        sys.exit(f"Missing input file: {path}")
    with open(path) as f:
        raw = f.read()
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    for i, code in enumerate(lines, 1):
        if len(code) != 6 or not code.isdigit():
            sys.exit(f"Invalid code at line {i}: {code!r} — must be exactly six digits")
    if len(lines) != EXPECTED_COUNT:
        sys.exit(f"Expected exactly {EXPECTED_COUNT} codes, found {len(lines)}")
    if len(set(lines)) != EXPECTED_COUNT:
        sys.exit("Duplicate codes found in valid_codes.txt")
    return lines


def digest(code: str, salt: bytes) -> bytes:
    return hash_secret_raw(
        secret=code.encode("utf-8"),
        salt=salt,
        time_cost=ITERATIONS,
        memory_cost=MEMORY_KIB,
        parallelism=PARALLELISM,
        hash_len=TAG_LENGTH,
        type=Type.ID,
    )


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def main() -> None:
    codes = read_codes(CODES_PATH)
    print(f"Read {len(codes)} valid codes from {CODES_PATH}")

    salt = secrets.token_bytes(SALT_LENGTH)

    beta_digests: list[str] = []
    seen: set[str] = set()
    for i, code in enumerate(codes, 1):
        encoded = b64(digest(code, salt))
        beta_digests.append(encoded)
        seen.add(encoded)
        if i % 100 == 0:
            print(f"Hashed {i}/{len(codes)} beta codes")

    if len(seen) != EXPECTED_COUNT:
        sys.exit("Digest collision detected among beta codes — aborting")

    master_digest = b64(digest(MASTER_CODE, salt))
    print("Hashed master override code")

    # Self-verify: recompute a sample and the master, confirm they match.
    sample_index = 0
    assert b64(digest(codes[sample_index], salt)) == beta_digests[sample_index], "Sample re-derivation mismatch"
    assert b64(digest(MASTER_CODE, salt)) == master_digest, "Master re-derivation mismatch"

    def swift_str(s: str) -> str:
        escaped = s.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'

    beta_body = "\n".join(f"        {swift_str(h)}," for h in beta_digests)

    output = f"""import Foundation

/// Auto-generated offline access material. Do not edit by hand.
///
/// This file contains only Argon2id digests derived from the authorized
/// one-time beta codes plus a reusable protected owner/admin override digest.
/// It contains no plaintext beta codes.
///
/// Every digest shares one app-wide salt so the app computes Argon2id exactly
/// once per login attempt, then performs a constant-time membership check.
nonisolated enum EmbeddedCodeHashes {{
    static let expectedBetaCodeCount: Int = 1_000
    static let isPlaceholder: Bool = false

    // Shared Argon2id parameters for every embedded digest.
    static let argonMemoryKiB: UInt32 = {MEMORY_KIB}
    static let argonIterations: UInt32 = {ITERATIONS}
    static let argonParallelism: UInt32 = {PARALLELISM}
    static let argonTagLength: UInt32 = {TAG_LENGTH}

    /// App-wide salt (base64) shared by every digest below.
    static let sharedSaltBase64: String = {swift_str(b64(salt))}

    /// Exactly 1,000 one-time beta access-code digests (base64), index-aligned
    /// with valid_codes.txt.
    static let betaDigestsBase64: [String] = [
{beta_body}
    ]

    /// Protected reusable owner/admin override digest (base64) for the
    /// configured master code. Grants access without burning a beta slot.
    static let masterDigestBase64: String = {swift_str(master_digest)}
}}
"""

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w") as f:
        f.write(output)
    print(f"Wrote {OUTPUT_PATH} ({len(beta_digests)} beta + 1 master override, shared salt)")


if __name__ == "__main__":
    main()
