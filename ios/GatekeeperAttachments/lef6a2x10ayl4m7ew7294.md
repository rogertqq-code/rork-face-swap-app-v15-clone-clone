# Gatekeeper - Hardened Offline Access Wall

**Fully Swift • Argon2id • 45-min Soft Session + 5-min Inactivity • One-time Codes**

This is a production-grade, offline-only authentication gate for iOS apps. It restricts access using 1,000 single-use 6-digit codes protected by memory-hard Argon2id hashing.

## Key Features

- **100% Offline** — No network required at any point.
- **Strong Cryptography** — Argon2id with unique salts per code.
- **Build-time Security** — Codes are hashed once and the generator is deleted afterward. Original codes become unrecoverable from source.
- **Soft Session Model**:
  - 45-minute hard maximum session lifetime.
  - 5-minute inactivity timeout (resets on foreground).
- **Robust Protections**:
  - Exponential backoff (persisted across restarts).
  - `ptrace(PT_DENY_ATTACH)` anti-debug.
  - Custom secure keypad (no system keyboard).
  - Generic error messages only.
  - Strict Swift 6 concurrency with actors.
- **Persistent State** — Uses Keychain (`AfterFirstUnlockThisDeviceOnly`).

## Project Structure

| File | Purpose | Keep After Build? |
|------|---------|-------------------|
| `Improved_Gatekeeper.swift` | Main implementation (actors, views, logic) | Yes |
| `generate_hashes.swift` | One-time build script to create hashes | **Delete after use** |
| `EmbeddedCodeHashes.swift` | Contains the 1,000 Argon2id hashes | Yes |
| `valid_codes.txt` | Your 1,000 secret codes | **Delete after hashing** |
| `Bulletproof_Gatekeeper_Prompt.txt` | Detailed spec for another AI | Optional |
| `Handoff_Instructions.txt` | Quick instructions for handoff | Optional |
| `README_Gatekeeper.md` | This file | Yes |

## Setup Instructions (One Time)

### 1. Add Argon2 Dependency

Add a Swift Argon2 package via **Swift Package Manager**:

**Recommended:**
- [kyzmitch/Swift-Argon2](https://github.com/kyzmitch/Swift-Argon2)

Alternative: Use a thin C target wrapping the official `libargon2`.

### 2. Generate the Hashes

1. Open `generate_hashes.swift`.
2. Implement the `computeArgon2idHash(for:)` function using your chosen Argon2 library.
3. Run the script:
   ```bash
   swift generate_hashes.swift
   ```
4. It will produce `EmbeddedCodeHashes.swift` containing only the hashes.

### 3. Integrate Into Xcode

1. Add the generated `EmbeddedCodeHashes.swift` to your target.
2. Add `Improved_Gatekeeper.swift` to your project.
3. Make sure `embeddedValidHashes` is accessible (it's declared as `internal`).

### 4. Clean Up (Important for Security)

After building successfully:

- **Delete** `generate_hashes.swift`
- **Delete** `valid_codes.txt`
- (Optional) Delete the prompt and handoff files if not needed

This ensures the original 1,000 codes are no longer present in your source repository.

### 5. Wire the Real Verifier

In `Improved_Gatekeeper.swift`, replace the placeholder in `verifyAgainstArgon2Hash(...)` with a real call from your Argon2 package.

Example:

```swift
import Argon2

private func verifyAgainstArgon2Hash(code: String, encodedHash: String) -> Bool {
    do {
        return try Argon2.verify(password: code, encoded: encodedHash)
    } catch {
        return false
    }
}
```

## Recommended Argon2 Parameters

For mobile devices, start with:

- Memory: `4096` KiB (4 MiB)
- Iterations (`t`): `3`
- Parallelism (`p`): `2`
- Hash length: `32`

Tune these on real devices. The goal is ~5–10 seconds for a full scan of 1000 hashes on worst-case invalid attempts. This acts as an additional brute-force deterrent.

## Session Behavior

- On successful code entry → Session starts with **45-minute hard cap**.
- Activity is recorded automatically when the app comes to foreground.
- If the app is idle for **5 continuous minutes** → Session is revoked.
- If you reach the 45-minute cap → Session is revoked regardless of activity.
- Session state survives app termination (stored in Keychain).

## Security Considerations

- All sensitive state lives in Keychain with `AfterFirstUnlockThisDeviceOnly`.
- Codes are single-use and permanently burned on first success.
- No plaintext codes exist in the final binary — only Argon2id hashes.
- Deleting the generator script after use removes the ability to recover the original codes from source.

## Testing Recommendations

1. Test with placeholder hashes first (current state) to verify UI and session logic.
2. Once real hashes are generated, test:
   - Valid code → unlocks
   - Already used code → generic denial
   - Invalid format → generic denial
   - Rapid failed attempts → backoff increases
   - Backgrounding the app for >5 min → locks
   - Relaunch within session window → resumes correctly

## Files You Should Keep Long-Term

- `Improved_Gatekeeper.swift`
- `EmbeddedCodeHashes.swift` (with real hashes)
- `README_Gatekeeper.md`

Everything else can be deleted after initial setup.

---

**This system prioritizes security while remaining practical through the soft session model.**

If you need further refinements, split files, additional logging guards, or integration with a larger app, let me know.