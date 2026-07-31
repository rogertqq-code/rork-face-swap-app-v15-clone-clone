# Argon2id Memory-Hardening Parameters for Gatekeeper

This document explores good Argon2id parameter choices for the Gatekeeper system (1,000 codes, mobile iOS, ~5–10s worst-case verification time).

## Argon2id Parameters Overview

| Parameter | Name in Libraries | Meaning | Impact | Recommended Range (Mobile) |
|-----------|-------------------|---------|--------|---------------------------|
| **Memory Cost** (`m`) | `memory` | Amount of memory used during hashing (in KiB) | **Highest** for memory-hardness | 4,096 – 65,536 (4 MiB – 64 MiB) |
| **Time Cost** (`t`) | `iterations` or `timeCost` | Number of passes over memory | High | 2 – 5 |
| **Parallelism** (`p`) | `parallelism` or `lanes` | Number of threads used | Medium | 1 – 4 (usually 2 on phones) |
| **Hash Length** | `hashLength` or `tagLength` | Output size in bytes | Low | 32 (256-bit) is standard |

**Most important parameter**: **Memory cost (`m`)**. This is what makes Argon2 "memory-hard" and resistant to GPU/ASIC attacks.

## Recommended Starting Parameters

For the Gatekeeper use case (1,000 hashes, mobile login gate), start with these values:

```swift
let params = Argon2Params(
    memory: 4096,      // 4 MiB
    iterations: 3,     // t = 3
    parallelism: 2,    // p = 2
    hashLength: 32
)
```

### Expected Performance (Modern iPhone)

| Memory (`m`) | Iterations (`t`) | Single Verify | Full 1000-hash Scan (worst case) | Recommendation |
|--------------|------------------|---------------|----------------------------------|----------------|
| 4,096 (4 MiB) | 3 | ~5–12 ms | **~5–12 seconds** | **Good starting point** |
| 8,192 (8 MiB) | 3 | ~10–20 ms | ~10–20 seconds | Stronger, still usable |
| 16,384 (16 MiB) | 2 | ~8–15 ms | ~8–15 seconds | Good balance |
| 32,768 (32 MiB) | 2 | ~15–30 ms | ~15–30 seconds | Aggressive |
| 65,536 (64 MiB) | 2 | ~30–60 ms | ~30–60 seconds | Very strong (may feel slow) |

**Target**: Aim for a **full scan of 1,000 hashes in roughly 5–12 seconds** on target devices. This provides excellent brute-force resistance while remaining acceptable for a high-security gate.

## Tuning Strategy

### 1. Start Conservative
Begin with:
- `m = 4096`
- `t = 3`
- `p = 2`

Test on real devices (especially older ones like iPhone 12/13).

### 2. Measure Real Performance
You should benchmark on actual hardware. Add temporary timing code during development:

```swift
let start = Date()
let success = verifyAgainstArgon2Hash(code: testCode, encodedHash: hash)
let elapsed = Date().timeIntervalSince(start)
print("Single verification took \(elapsed * 1000) ms")
```

Then multiply by ~1000 for worst-case full scan time.

### 3. Adjust Based on Results

| Observation | Action |
|-------------|--------|
| Full scan > 15 seconds | Lower memory or iterations |
| Full scan < 4 seconds | Increase memory (preferred) or iterations |
| Device feels sluggish during login | Slightly reduce memory |
| Want maximum security | Increase memory first, then iterations |

**Rule of thumb**: Increasing memory (`m`) gives better security per unit of time than increasing iterations (`t`).

## Security Considerations

### Why Memory Matters

- Low-memory hashes (e.g. `m=256`) can be attacked efficiently on GPUs.
- High-memory hashes force attackers to use a lot of RAM per attempt, which is expensive.
- With 1,000 codes, an attacker who extracts the binary must still perform up to 1,000 expensive Argon2id computations per guess.

### Trade-offs

| Goal | Priority | Suggested Parameters |
|------|----------|----------------------|
| Best UX (fast login) | High | `m=4096`, `t=2` or `3` |
| Strong security | High | `m=8192` or `16384`, `t=2` or `3` |
| Maximum paranoia | Medium | `m=32768`, `t=2` |
| Balanced (recommended) | **Best** | `m=4096–8192`, `t=3`, `p=2` |

## Final Recommendations for This Project

| Use Case | Memory (`m`) | Iterations (`t`) | Parallelism (`p`) | Expected Full Scan |
|----------|--------------|------------------|-------------------|--------------------|
| **Recommended Default** | **4096** | **3** | **2** | **~5–10 seconds** |
| Stronger Security | 8192 | 3 | 2 | ~10–15 seconds |
| Very Strong | 16384 | 2 | 2 | ~10–15 seconds |
| Maximum (if UX allows) | 32768 | 2 | 2 | ~20–30 seconds |

After choosing parameters:
1. Generate all 1,000 hashes using **exactly** these parameters.
2. Use the **same parameters** in the runtime verification function.
3. Document the chosen parameters in your codebase.

## Example: Generating Hashes with Specific Parameters

In `generate_hashes.swift`, make parameters explicit and configurable:

```swift
struct Argon2Config {
    static let memory: UInt32 = 4096
    static let iterations: UInt32 = 3
    static let parallelism: UInt32 = 2
    static let hashLength: Int = 32
}
```

This makes future rotation or tuning much easier.

## Summary

- **Start with**: `m=4096`, `t=3`, `p=2`
- **Target**: 5–10 second worst-case full scan
- **Tune memory first**, then iterations
- **Always use the same parameters** for generation and verification
- **Benchmark on real devices**, especially older ones

These parameters, combined with the 1,000-code limit and exponential backoff, make offline brute-forcing extremely expensive while keeping the gate usable.

---

Would you like me to generate a small Swift snippet that helps benchmark different parameter combinations on device? Or adjust any of the recommendations?