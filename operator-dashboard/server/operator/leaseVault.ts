import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";

const VERSION = "v1";
const IV_BYTES = 12;
const TAG_BYTES = 16;

export class LeaseVaultError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LeaseVaultError";
  }
}

function key() {
  const secret = process.env.JWT_SECRET ?? "";
  if (secret.length < 32) {
    throw new LeaseVaultError("Server credential vault is unavailable.");
  }
  return createHash("sha256").update(secret, "utf8").digest();
}

export function sealLiveLease(sessionId: string, token: string) {
  if (!sessionId || token.length < 16 || token.length > 2048) {
    throw new LeaseVaultError("Live lease credential is invalid.");
  }
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  cipher.setAAD(Buffer.from(sessionId, "utf8"));
  const ciphertext = Buffer.concat([
    cipher.update(token, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return [
    VERSION,
    iv.toString("base64url"),
    tag.toString("base64url"),
    ciphertext.toString("base64url"),
  ].join(".");
}

export function openLiveLease(sessionId: string, sealed: string) {
  const [version, ivSource, tagSource, ciphertextSource, ...extra] =
    sealed.split(".");
  if (
    version !== VERSION ||
    !ivSource ||
    !tagSource ||
    !ciphertextSource ||
    extra.length > 0
  ) {
    throw new LeaseVaultError("Stored live lease credential is malformed.");
  }
  try {
    const iv = Buffer.from(ivSource, "base64url");
    const tag = Buffer.from(tagSource, "base64url");
    const ciphertext = Buffer.from(ciphertextSource, "base64url");
    if (
      iv.length !== IV_BYTES ||
      tag.length !== TAG_BYTES ||
      !ciphertext.length
    ) {
      throw new Error("invalid credential components");
    }
    const decipher = createDecipheriv("aes-256-gcm", key(), iv);
    decipher.setAAD(Buffer.from(sessionId, "utf8"));
    decipher.setAuthTag(tag);
    return Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ]).toString("utf8");
  } catch (error) {
    if (error instanceof LeaseVaultError) throw error;
    throw new LeaseVaultError(
      "Stored live lease credential could not be opened."
    );
  }
}
