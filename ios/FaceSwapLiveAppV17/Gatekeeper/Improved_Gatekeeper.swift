import CryptoKit
import Foundation
import Security
import SwiftArgon2
import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Early Runtime Protection

#if canImport(Darwin)
private let gatekeeperPTDenyAttach: CInt = 31
@_silgen_name("ptrace")
private func gatekeeperPtrace(_ request: CInt, _ pid: pid_t, _ address: UnsafeMutableRawPointer?, _ data: CInt) -> CInt
#endif

/// Runs the app's earliest debugger-denial hook. Kept as a no-op for simulator/debug builds
/// so local previews and CI remain usable while release device builds are protected.
@inline(__always)
nonisolated func gatekeeperDenyDebuggerAttachment() {
#if canImport(Darwin) && !targetEnvironment(simulator) && !DEBUG
    _ = gatekeeperPtrace(gatekeeperPTDenyAttach, 0, nil, 0)
#endif
}

// MARK: - Access Models

nonisolated enum GatekeeperAccessKind: Sendable {
    case beta(index: Int)
    case masterOverride
}

nonisolated struct GatekeeperSessionRecord: Codable, Sendable, Equatable {
    let absoluteExpiration: Date
    let lastActivity: Date
}

nonisolated struct GatekeeperBackoffRecord: Codable, Sendable, Equatable {
    var failedAttempts: Int
    var lockedUntil: Date?

    static let empty = GatekeeperBackoffRecord(failedAttempts: 0, lockedUntil: nil)
}

nonisolated enum GatekeeperValidationOutcome: Sendable, Equatable {
    case granted(GatekeeperSessionRecord)
    case denied
    case configurationMissing
}

nonisolated enum GatekeeperError: Error, Sendable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case encodingFailed
    case invalidStoredData
}

// MARK: - Compact Spent-Code Store

nonisolated enum GatekeeperSpentCodeBits {
    static let capacity: Int = 1_000
    static let byteCount: Int = 125

    static func emptyData() -> Data {
        Data(repeating: 0, count: byteCount)
    }

    static func normalized(_ data: Data?) -> Data {
        guard var data else { return emptyData() }
        if data.count < byteCount {
            data.append(Data(repeating: 0, count: byteCount - data.count))
        }
        if data.count > byteCount {
            data = data.prefix(byteCount)
        }
        return data
    }

    static func contains(index: Int, in data: Data) -> Bool {
        guard index >= 0, index < capacity else { return false }
        let byteIndex = index / 8
        let bitIndex = index % 8
        guard byteIndex < data.count else { return false }
        return (data[byteIndex] & UInt8(1 << bitIndex)) != 0
    }

    static func markSpent(index: Int, in data: Data) -> Data {
        guard index >= 0, index < capacity else { return normalized(data) }
        var updated = normalized(data)
        let byteIndex = index / 8
        let bitIndex = index % 8
        updated[byteIndex] |= UInt8(1 << bitIndex)
        return updated
    }
}

// MARK: - Keychain State Manager

actor KeychainStateManager {
    private enum StorageKey: String {
        case spentIndexes = "gatekeeper.spentIndexes.v1"
        case session = "gatekeeper.session.v1"
        case backoff = "gatekeeper.backoff.v1"
    }

    private let service = "app.rork.face-swap-live-app.gatekeeper"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func loadSpentIndexes() throws -> Data {
        try GatekeeperSpentCodeBits.normalized(readData(for: .spentIndexes))
    }

    func saveSpentIndexes(_ data: Data) throws {
        try writeData(GatekeeperSpentCodeBits.normalized(data), for: .spentIndexes)
    }

    func loadSession() throws -> GatekeeperSessionRecord? {
        guard let data = try readData(for: .session) else { return nil }
        do {
            return try decoder.decode(GatekeeperSessionRecord.self, from: data)
        } catch {
            try? deleteData(for: .session)
            throw GatekeeperError.invalidStoredData
        }
    }

    func saveSession(_ session: GatekeeperSessionRecord) throws {
        let data = try encoder.encode(session)
        try writeData(data, for: .session)
    }

    func clearSession() throws {
        try deleteData(for: .session)
    }

    func loadBackoff() throws -> GatekeeperBackoffRecord {
        guard let data = try readData(for: .backoff) else { return .empty }
        do {
            return try decoder.decode(GatekeeperBackoffRecord.self, from: data)
        } catch {
            try? deleteData(for: .backoff)
            return .empty
        }
    }

    func saveBackoff(_ backoff: GatekeeperBackoffRecord) throws {
        let data = try encoder.encode(backoff)
        try writeData(data, for: .backoff)
    }

    func clearBackoff() throws {
        try deleteData(for: .backoff)
    }

    func purgeAccessSessionState() throws {
        try deleteData(for: .session)
    }

    private func baseQuery(for key: StorageKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    private func readData(for key: StorageKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GatekeeperError.keychainReadFailed(status)
        }
        return result as? Data
    }

    private func writeData(_ data: Data, for key: StorageKey) throws {
        let query = baseQuery(for: key)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GatekeeperError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GatekeeperError.keychainWriteFailed(addStatus)
        }
    }

    private func deleteData(for key: StorageKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatekeeperError.keychainDeleteFailed(status)
        }
    }
}

// MARK: - Constant-Time Comparison

nonisolated enum GatekeeperConstantTime {
    static func isEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        // Fold the length mismatch in as a plain 0/1 flag. The previous
        // `UInt8(lhs.count ^ rhs.count)` would trap whenever the XOR of the two
        // counts exceeded 255 (e.g. lengths 256 vs 0), so this is both safe and
        // still constant-time over the longer of the two buffers.
        var difference: UInt8 = (lhs.count == rhs.count) ? 0 : 1
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let leftByte = index < lhs.count ? lhs[index] : 0
            let rightByte = index < rhs.count ? rhs[index] : 0
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }
}

// MARK: - Validator Actor

actor HardenedAccessValidator {
    private enum Constants {
        static let hardSessionLifetime: TimeInterval = 45 * 60
        static let inactivityLifetime: TimeInterval = 5 * 60
        static let maximumBackoff: TimeInterval = 5 * 60
        static let failureMessage = "Access denied. Please check your code and try again."
    }

    private struct ScanResult: Sendable {
        let matchedBetaIndex: Int?
        let didMatchMaster: Bool
    }

    private let keychain: KeychainStateManager

    init(keychain: KeychainStateManager = KeychainStateManager()) {
        self.keychain = keychain
    }

    func restoreSession(now: Date = Date()) async -> GatekeeperSessionRecord? {
        guard let session = try? await keychain.loadSession(), isValid(session, now: now) else {
            try? await keychain.clearSession()
            return nil
        }
        return session
    }

    func validate(code rawCode: String, now: Date = Date()) async -> GatekeeperValidationOutcome {
        if EmbeddedCodeHashes.isPlaceholder || EmbeddedCodeHashes.betaDigestsBase64.count != EmbeddedCodeHashes.expectedBetaCodeCount {
            return .configurationMissing
        }

        guard !(await isBackoffLocked(now: now)) else {
            return .denied
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSixDigitCode(code) else {
            await recordFailure(now: now)
            return .denied
        }

        let password = Data(code.utf8)
        let scanResult = await scanAllHashes(password: password)
        let spentData = (try? await keychain.loadSpentIndexes()) ?? GatekeeperSpentCodeBits.emptyData()

        if scanResult.didMatchMaster {
            return await grantSession(withoutBurningCodeAt: nil, existingSpentData: spentData, now: now)
        }

        if let index = scanResult.matchedBetaIndex,
           !GatekeeperSpentCodeBits.contains(index: index, in: spentData) {
            return await grantSession(withoutBurningCodeAt: index, existingSpentData: spentData, now: now)
        }

        await recordFailure(now: now)
        return .denied
    }

    func recordForegroundActivity(now: Date = Date()) async -> GatekeeperSessionRecord? {
        guard let current = try? await keychain.loadSession(), isValid(current, now: now) else {
            try? await keychain.clearSession()
            return nil
        }

        let refreshed = GatekeeperSessionRecord(
            absoluteExpiration: current.absoluteExpiration,
            lastActivity: now
        )
        do {
            try await keychain.saveSession(refreshed)
            return refreshed
        } catch {
            try? await keychain.clearSession()
            return nil
        }
    }

    func currentSession(now: Date = Date()) async -> GatekeeperSessionRecord? {
        guard let current = try? await keychain.loadSession(), isValid(current, now: now) else {
            try? await keychain.clearSession()
            return nil
        }
        return current
    }

    func revokeSession() async {
        try? await keychain.clearSession()
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy(\.isNumber)
    }

    private func isBackoffLocked(now: Date) async -> Bool {
        guard let backoff = try? await keychain.loadBackoff(), let lockedUntil = backoff.lockedUntil else {
            return false
        }
        if lockedUntil > now { return true }
        return false
    }

    private func recordFailure(now: Date) async {
        var backoff = (try? await keychain.loadBackoff()) ?? .empty
        let attempts = min(backoff.failedAttempts + 1, 12)
        let exponent = max(0, attempts - 1)
        let delay = min(pow(2.0, Double(exponent)), Constants.maximumBackoff)
        backoff.failedAttempts = attempts
        backoff.lockedUntil = now.addingTimeInterval(delay)
        try? await keychain.saveBackoff(backoff)
    }

    private func grantSession(withoutBurningCodeAt index: Int?, existingSpentData: Data, now: Date) async -> GatekeeperValidationOutcome {
        let session = GatekeeperSessionRecord(
            absoluteExpiration: now.addingTimeInterval(Constants.hardSessionLifetime),
            lastActivity: now
        )

        // Grant access FIRST: only once the session is safely persisted do we
        // burn a one-time code. The old order saved the spent index before the
        // session, so a keychain failure on the session write could burn a code
        // forever without ever letting the user in.
        do {
            try await keychain.saveSession(session)
        } catch {
            try? await keychain.clearSession()
            return .denied
        }

        if let index {
            // A failure here only leaves the code re-usable (the safe direction);
            // the user still gets the access they just proved they're entitled to.
            let updatedSpentData = GatekeeperSpentCodeBits.markSpent(index: index, in: existingSpentData)
            try? await keychain.saveSpentIndexes(updatedSpentData)
        }
        try? await keychain.clearBackoff()
        return .granted(session)
    }

    private func isValid(_ session: GatekeeperSessionRecord, now: Date) -> Bool {
        guard session.absoluteExpiration > now else { return false }
        guard now.timeIntervalSince(session.lastActivity) <= Constants.inactivityLifetime else { return false }
        return true
    }

    /// Computes the entered code's Argon2id digest exactly once using the shared
    /// salt, then performs a constant-time membership check across the full
    /// embedded list. Every attempt performs the same single KDF plus full scan,
    /// so timing never reveals whether a code exists, was used, or is the master.
    private func scanAllHashes(password: Data) async -> ScanResult {
        guard let salt = Data(base64Encoded: EmbeddedCodeHashes.sharedSaltBase64),
              let computed = await computeDigest(password: password, salt: salt)
        else {
            return ScanResult(matchedBetaIndex: nil, didMatchMaster: false)
        }

        var matchedIndex: Int?
        for (index, encoded) in EmbeddedCodeHashes.betaDigestsBase64.enumerated() {
            guard let stored = Data(base64Encoded: encoded) else { continue }
            if GatekeeperConstantTime.isEqual(computed, stored) {
                matchedIndex = index
            }
        }

        var didMatchMaster = false
        if let masterStored = Data(base64Encoded: EmbeddedCodeHashes.masterDigestBase64) {
            didMatchMaster = GatekeeperConstantTime.isEqual(computed, masterStored)
        }

        return ScanResult(matchedBetaIndex: matchedIndex, didMatchMaster: didMatchMaster)
    }

    private func computeDigest(password: Data, salt: Data) async -> Data? {
        let params = Argon2Params(
            parallelism: EmbeddedCodeHashes.argonParallelism,
            tagLength: EmbeddedCodeHashes.argonTagLength,
            memorySize: EmbeddedCodeHashes.argonMemoryKiB,
            iterations: EmbeddedCodeHashes.argonIterations,
            variant: .argon2id
        )
        do {
            let argon2 = try Argon2(params: params)
            return try await argon2.compute(password: password, salt: salt)
        } catch {
            return nil
        }
    }
}

// MARK: - SwiftUI Bridge

/// Thread-safe holder for the monitor task so `deinit` (a nonisolated context)
/// can cancel it without touching main-actor state. `Task.cancel()` is safe to
/// call from any thread, so the lock only guards the reference itself.
private final class MonitorTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    func store(_ newTask: Task<Void, Never>) {
        lock.lock()
        task = newTask
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }
}

@MainActor
@Observable
final class Gatekeeper {
    private let validator: HardenedAccessValidator
    private let monitorBox = MonitorTaskBox()
    private var lastForegroundRefresh: Date = .distantPast
    /// Throttles the secure-storage re-validation so `tick()` doesn't hit the
    /// keychain every second while unlocked.
    private var lastSessionCheck: Date = .distantPast
    private var activeScenePhase: ScenePhase = .inactive

    var isBootstrapping: Bool = true
    var isUnlocked: Bool = false
    var isValidating: Bool = false
    var enteredCode: String = ""
    var message: String?
    var sessionExpiresAt: Date?
    var remainingSeconds: Int = 0
    var isPrivacyShieldVisible: Bool = true

    init(validator: HardenedAccessValidator = HardenedAccessValidator()) {
        self.validator = validator
    }

    deinit {
        monitorBox.cancel()
    }

    var remainingTimeText: String {
        let seconds = max(0, remainingSeconds)
        let minutes = seconds / 60
        let remaining = seconds % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }

    func start() {
        guard !monitorBox.isRunning else { return }
        let task = Task { [weak self] in
            await self?.restoreExistingSession()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        // Store the task so `isRunning` guards against duplicate monitor loops
        // and `deinit` can actually cancel it. Without this the countdown task
        // leaked and re-running `start()` spawned extra loops.
        monitorBox.store(task)
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        activeScenePhase = scenePhase
        switch scenePhase {
        case .active:
            isPrivacyShieldVisible = false
            Task { [weak self] in
                await self?.recordForegroundActivityIfNeeded(force: true)
            }
        case .inactive, .background:
            isPrivacyShieldVisible = true
        @unknown default:
            isPrivacyShieldVisible = true
        }
    }

    func appendDigit(_ digit: Int) {
        guard !isValidating, enteredCode.count < 6, (0...9).contains(digit) else { return }
        enteredCode.append(String(digit))
        message = nil
        if enteredCode.count == 6 {
            submitCode()
        }
    }

    func deleteDigit() {
        guard !isValidating, !enteredCode.isEmpty else { return }
        enteredCode.removeLast()
        message = nil
    }

    func clearCode() {
        guard !isValidating else { return }
        enteredCode.removeAll(keepingCapacity: true)
        message = nil
    }

    func submitCode() {
        guard !isValidating, enteredCode.count == 6 else { return }
        let code = enteredCode
        isValidating = true
        message = nil

        Task { [weak self] in
            guard let self else { return }
            let outcome = await validator.validate(code: code)
            await MainActor.run {
                self.enteredCode.removeAll(keepingCapacity: true)
                self.isValidating = false
                self.apply(outcome)
            }
        }
    }

    func revoke() {
        Task { [weak self] in
            guard let self else { return }
            await validator.revokeSession()
            await MainActor.run {
                self.lockLocalState()
            }
        }
    }

    private func restoreExistingSession() async {
        let session = await validator.restoreSession()
        await MainActor.run {
            self.isBootstrapping = false
            if let session {
                self.unlock(with: session)
            } else {
                self.lockLocalState()
            }
        }
    }

    private func tick() async {
        guard isUnlocked else { return }

        // Drive the visible countdown locally from the known expiry so we do not
        // read secure storage every second.
        if let expiresAt = sessionExpiresAt {
            remainingSeconds = max(0, Int(expiresAt.timeIntervalSince(Date()).rounded(.down)))
        }

        if activeScenePhase == .active {
            await recordForegroundActivityIfNeeded(force: false)
        }

        // Re-validate against secure storage on a slower cadence to honor
        // external revocation and the inactivity timeout.
        let now = Date()
        guard now.timeIntervalSince(lastSessionCheck) >= 15 else { return }
        lastSessionCheck = now

        guard let session = await validator.currentSession() else {
            lockLocalState()
            return
        }
        updateRemainingTime(session: session)
    }

    private func recordForegroundActivityIfNeeded(force: Bool) async {
        guard isUnlocked else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastForegroundRefresh) >= 30 else { return }
        lastForegroundRefresh = now
        let session = await validator.recordForegroundActivity(now: now)
        await MainActor.run {
            guard let session else {
                self.lockLocalState()
                return
            }
            self.updateRemainingTime(session: session)
        }
    }

    private func apply(_ outcome: GatekeeperValidationOutcome) {
        switch outcome {
        case .granted(let session):
            unlock(with: session)
        case .denied:
            message = "Access denied. Please check your code and try again."
        case .configurationMissing:
            message = "Access list not generated for this build. Run the local hash generator before distribution."
        }
    }

    private func unlock(with session: GatekeeperSessionRecord) {
        isUnlocked = true
        isPrivacyShieldVisible = activeScenePhase != .active
        message = nil
        sessionExpiresAt = session.absoluteExpiration
        updateRemainingTime(session: session)
    }

    private func lockLocalState() {
        isUnlocked = false
        isValidating = false
        enteredCode.removeAll(keepingCapacity: true)
        sessionExpiresAt = nil
        remainingSeconds = 0
        isPrivacyShieldVisible = activeScenePhase != .active
    }

    private func updateRemainingTime(session: GatekeeperSessionRecord) {
        sessionExpiresAt = session.absoluteExpiration
        remainingSeconds = max(0, Int(session.absoluteExpiration.timeIntervalSince(Date()).rounded(.down)))
    }
}

// MARK: - Root Wall

struct GatekeeperAccessWall<ProtectedContent: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var gatekeeper = Gatekeeper()

    private let protectedContent: () -> ProtectedContent

    init(@ViewBuilder protectedContent: @escaping () -> ProtectedContent) {
        self.protectedContent = protectedContent
    }

    var body: some View {
        ZStack {
            if gatekeeper.isBootstrapping {
                GatekeeperBootView()
                    .transition(.opacity)
            } else if gatekeeper.isUnlocked {
                protectedContent()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))

                GatekeeperSessionPill(
                    remainingTimeText: gatekeeper.remainingTimeText,
                    onRevoke: { gatekeeper.revoke() }
                )
                .padding(.top, 8)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                GatekeeperGateView(gatekeeper: gatekeeper)
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }

            if gatekeeper.isPrivacyShieldVisible {
                GatekeeperPrivacyShield()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: gatekeeper.isUnlocked)
        .animation(.easeOut(duration: 0.12), value: gatekeeper.isPrivacyShieldVisible)
        .preferredColorScheme(.dark)
        .task {
            gatekeeper.start()
            gatekeeper.handleScenePhase(scenePhase)
        }
        .onChange(of: scenePhase) { _, newPhase in
            gatekeeper.handleScenePhase(newPhase)
        }
    }
}

private struct GatekeeperBootView: View {
    var body: some View {
        ZStack {
            GatekeeperBackground()
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Restoring secure session")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }
}

private struct GatekeeperGateView: View {
    let gatekeeper: Gatekeeper

    private let keypadRows: [[Int?]] = [
        [1, 2, 3],
        [4, 5, 6],
        [7, 8, 9],
        [nil, 0, nil]
    ]

    var body: some View {
        ZStack {
            GatekeeperBackground()
            VStack(spacing: 28) {
                Spacer(minLength: 22)

                VStack(spacing: 14) {
                    Image("BrandLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 132)
                        .clipShape(.rect(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(.white.opacity(0.14), lineWidth: 1)
                        }
                        .shadow(color: .cyan.opacity(0.4), radius: 24, y: 8)
                        .accessibilityLabel("Fraudomatic KYC")

                    Text("Gatekeeper")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Enter your authorized 6-digit beta access code.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 18) {
                    HStack(spacing: 12) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(index < gatekeeper.enteredCode.count ? .white : .white.opacity(0.12))
                                .overlay {
                                    Circle().stroke(.white.opacity(0.2), lineWidth: 1)
                                }
                                .frame(width: 16, height: 16)
                                .shadow(color: index < gatekeeper.enteredCode.count ? .white.opacity(0.35) : .clear, radius: 8)
                        }
                    }
                    .accessibilityLabel("Six digit code entry")
                    .accessibilityValue("\(gatekeeper.enteredCode.count) digits entered")

                    if gatekeeper.isValidating {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Checking access securely…")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.76))
                        }
                        .frame(height: 24)
                    } else {
                        Text(gatekeeper.message ?? "One-time beta codes burn permanently after first successful use.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(gatekeeper.message == nil ? .white.opacity(0.56) : .red.opacity(0.92))
                            .multilineTextAlignment(.center)
                            .frame(height: 38)
                            .padding(.horizontal, 24)
                    }
                }

                VStack(spacing: 12) {
                    ForEach(Array(keypadRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 14) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, digit in
                                if let digit {
                                    GatekeeperKeyButton(title: "\(digit)") {
                                        gatekeeper.appendDigit(digit)
                                    }
                                    .disabled(gatekeeper.isValidating)
                                } else {
                                    GatekeeperUtilityButton(systemImage: gatekeeper.enteredCode.isEmpty ? "xmark" : "delete.left") {
                                        gatekeeper.deleteDigit()
                                    }
                                    .opacity(gatekeeper.enteredCode.isEmpty ? 0.22 : 1)
                                    .disabled(gatekeeper.isValidating || gatekeeper.enteredCode.isEmpty)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 8) {
                    Label("Sessions last up to 45 minutes", systemImage: "timer")
                    Label("Access is revoked after 5 minutes without active foreground use", systemImage: "moon.zzz.fill")
                    Label("The app is obscured instantly in the app switcher", systemImage: "eye.slash.fill")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.white.opacity(0.055), in: .rect(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 18)
            }
        }
    }
}

private struct GatekeeperKeyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 78, height: 64)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityLabel("Digit \(title)")
    }
}

private struct GatekeeperUtilityButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 78, height: 64)
                .background(.white.opacity(0.045), in: .rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityLabel("Delete digit")
    }
}

private struct GatekeeperSessionPill: View {
    let remainingTimeText: String
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onRevoke) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lock now")

            Text(remainingTimeText)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.trailing, 5)
        }
        .padding(3)
        .background(.black.opacity(0.58), in: .capsule)
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

private struct GatekeeperPrivacyShield: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.02, green: 0.035, blue: 0.055), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Protected")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Secure content is hidden while the app is inactive.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .ignoresSafeArea()
    }
}

private struct GatekeeperBackground: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.cyan.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 360
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 420
            )
            LinearGradient(
                colors: [Color.white.opacity(0.055), Color.clear, Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let size = proxy.size
                Path { path in
                    let step: CGFloat = 34
                    var x: CGFloat = -size.height
                    while x < size.width + size.height {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        x += step
                    }
                }
                .stroke(.white.opacity(0.025), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}
