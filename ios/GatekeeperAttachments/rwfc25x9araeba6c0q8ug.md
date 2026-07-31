# Argon2id Integration Guide for Gatekeeper

This guide explains how to replace the placeholder Argon2 verifier with a real implementation.

## Step 1: Add Dependency via Swift Package Manager

### Recommended Package

**Option A (Pure Swift - Recommended for simplicity):**
- Repository: `https://github.com/kyzmitch/Swift-Argon2`

**Option B (C-backed - Often more performant):**
- Many teams create a small Swift package that wraps the official `libargon2` using a C target.

In Xcode:
1. Go to **File → Add Package Dependencies**
2. Paste the repository URL
3. Add it to your main app target

## Step 2: Import the Module

At the top of `Improved_Gatekeeper.swift`, add:

```swift
import Argon2   // or whatever the module name is from your chosen package
```

## Step 3: Implement `verifyAgainstArgon2Hash`

Replace the placeholder function with a real implementation.

### Example Implementation (using Swift-Argon2 style)

```swift
private func verifyAgainstArgon2Hash(code: String, encodedHash: String) -> Bool {
    do {
        // Most Argon2 Swift wrappers expose a verify function like this:
        return try Argon2.verify(password: code, encoded: encodedHash)
    } catch {
        // Important: Do not log the actual error or the code in production
        #if DEBUG
        print("Argon2 verification failed (debug only)")
        #endif
        return false
    }
}
```

### Alternative (if your package uses a different API)

Some packages require you to parse the hash first:

```swift
private func verifyAgainstArgon2Hash(code: String, encodedHash: String) -> Bool {
    guard let parsedHash = try? PasswordHash(encodedHash) else {
        return false
    }
    
    do {
        return try Argon2.verify(password: code.data(using: .utf8)!, hash: parsedHash)
    } catch {
        return false
    }
}
```

Check the documentation of the specific package you chose.

## Step 4: Recommended Argon2 Parameters

When generating hashes in `generate_hashes.swift`, use these starting parameters:

```swift
let params = Argon2Params(
    memory: 4096,      // 4 MiB - good balance for mobile
    iterations: 3,     // t = 3
    parallelism: 2,    // p = 2
    hashLength: 32
)
```

These parameters usually result in:
- ~5–10 seconds for a full scan of 1000 hashes on modern iPhones (worst case)
- Strong protection against offline brute force

**Tune these values** after testing on real devices. Higher memory/iterations = slower login but much harder to brute force.

## Step 5: Update `generate_hashes.swift`

You must also implement hashing in the generator script using the **same parameters** you use for verification.

Example skeleton inside `generate_hashes.swift`:

```swift
private func computeArgon2idHash(for code: String) -> String? {
    let salt = generateRandomSalt() // 16 bytes
    
    do {
        let encoded = try Argon2.hash(
            password: code.data(using: .utf8)!,
            salt: salt,
            params: params,           // Must match verification params
            variant: .id              // Argon2id
        )
        return encoded
    } catch {
        return nil
    }
}
```

## Step 6: Testing Strategy

### Phase 1: Placeholder Testing (Current State)
- Use current placeholder code
- Verify UI flow, session timing, backoff, and Keychain persistence work correctly

### Phase 2: Real Argon2 Testing
1. Generate real hashes using your updated `generate_hashes.swift`
2. Replace placeholder in `verifyAgainstArgon2Hash`
3. Test the following cases:
   - Valid unused code → Success + session starts
   - Valid but already used code → Generic denial
   - Wrong 6-digit code → Generic denial
   - Malformed input → Generic denial
   - Rapid failed attempts → Backoff increases correctly
   - App backgrounded > 5 minutes → Session revoked on return

## Common Issues & Solutions

| Problem | Likely Cause | Solution |
|---------|--------------|----------|
| Verification always fails | Wrong parameters between hash & verify | Ensure `memory`, `iterations`, and `parallelism` match exactly |
| Very slow verification | Parameters too high | Lower memory or iterations |
| Crashes on verify | Wrong data types passed to Argon2 | Check if package expects `Data` or `String` |
| Hashes look different | Different Argon2 library/version | Stick to one consistent package for both generation and verification |

## Final Security Checklist

- [ ] Same Argon2 parameters used in both generator and verifier
- [ ] `generate_hashes.swift` deleted after producing real hashes
- [ ] `valid_codes.txt` deleted after hashing
- [ ] No plaintext codes exist anywhere in the final app binary
- [ ] All verification failures return the exact same generic message
- [ ] Backoff and Keychain persistence tested

---

Once Argon2 is properly integrated, the Gatekeeper becomes significantly stronger against offline attacks while remaining practical for users thanks to the soft session model.

If you need help choosing a specific Argon2 package or want example code for a particular library, provide the package name and I can give more targeted integration code.