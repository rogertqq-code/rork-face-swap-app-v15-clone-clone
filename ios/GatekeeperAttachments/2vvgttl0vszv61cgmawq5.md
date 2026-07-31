# Gatekeeper Security Audit Checklist

Use this checklist before releasing the Gatekeeper into production.

## 1. Cryptography

- [ ] Real Argon2id implementation is wired (placeholder removed)
- [ ] Same parameters used for hashing and verification (`m`, `t`, `p`)
- [ ] Each of the 1000 codes has a **unique random salt**
- [ ] `generate_hashes.swift` has been deleted after use
- [ ] `valid_codes.txt` has been deleted after use
- [ ] No plaintext codes exist in source control or the final binary

## 2. Code Burning & Reuse Prevention

- [ ] `markSpent()` is called immediately on successful validation
- [ ] `isSpent()` check happens **after** cryptographic verification
- [ ] Spent state is persisted in Keychain
- [ ] Already-used codes return the exact same generic error as wrong codes

## 3. Session Management

- [ ] Hard cap is set to 45 minutes
- [ ] Inactivity timeout is set to 5 minutes
- [ ] `lastActivityTime` is updated on `scenePhase == .active`
- [ ] Session state (absolute expiration + last activity) survives app termination
- [ ] Session is correctly revoked on both hard cap and inactivity
- [ ] Relaunch within valid window correctly resumes the session

## 4. Anti-Brute Force

- [ ] Exponential backoff is implemented in the validator actor
- [ ] Backoff state (count + lockout time) is persisted in Keychain
- [ ] Backoff survives app restarts
- [ ] Validation is blocked during active lockout period

## 5. Anti-Tampering & Runtime Protections

- [ ] `ptrace(PT_DENY_ATTACH)` is called early (`App.init()` and/or constructor)
- [ ] No sensitive data is logged (codes, hashes, indexes, etc.)
- [ ] All error paths return the same generic message
- [ ] No debug symbols or excessive metadata in release builds (recommended)

## 6. Keychain Security

- [ ] All sensitive items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- [ ] No `kSecAttrSynchronizable` is enabled
- [ ] Spent codes use efficient bit-packed storage (not bloated format)
- [ ] Keychain errors are handled gracefully without leaking information

## 7. Concurrency & Data Isolation

- [ ] `HardenedAccessValidator` is an actor
- [ ] `KeychainStateManager` is an actor
- [ ] All sensitive mutations happen on actor context
- [ ] `Gatekeeper` observable runs on `@MainActor`
- [ ] No data races possible under Swift 6 strict concurrency

## 8. User Interface Security

- [ ] Custom keypad is used (no system keyboard for code entry)
- [ ] Input is cleared on failure
- [ ] No success/failure distinction beyond generic message
- [ ] Progress indicator is shown during long cryptographic verification
- [ ] Remaining session time is displayed in the main app

## 9. Build & Deployment Hygiene

- [ ] `generate_hashes.swift` removed from final project
- [ ] `valid_codes.txt` removed from final project
- [ ] `EmbeddedCodeHashes.swift` contains only hashes (no comments revealing codes)
- [ ] Release build uses appropriate optimizations and symbol stripping
- [ ] App is tested in Release configuration (not just Debug)

## 10. Operational / Maintenance

- [ ] Clear process exists for rotating to a new set of 1000 codes in future versions
- [ ] Documentation exists for how to regenerate hashes if needed
- [ ] Team understands that deleting the generator is a security requirement, not optional

---

### Red Flags (Things That Should Never Happen)

- Plaintext codes committed to git
- Generator script left in the shipping app
- Different Argon2 parameters between hash generation and verification
- Logging of codes or verification results
- Distinguishable error messages for "wrong code" vs "already used"
- Session state stored in UserDefaults instead of Keychain

---

Print or copy this checklist and go through it methodically before shipping.

Would you like me to expand any section or create a version tailored for a security review meeting?