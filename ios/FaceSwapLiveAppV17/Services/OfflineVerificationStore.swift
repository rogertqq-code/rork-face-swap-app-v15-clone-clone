import Foundation
import Observation

/// Persists a small, profile-scoped history of offline verification evidence.
/// Captured media is never stored here—only result statuses and compact technical
/// context needed to explain a rerun.
@MainActor
@Observable
final class OfflineVerificationStore {
    static let defaultStorageKey = "offline_profile_verification_reports_v1"
    static let maximumReportsPerProfile = 5

    private let defaults: UserDefaults
    private let storageKey: String
    private var reportsByProfileID: [String: [OfflineVerificationReport]] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = OfflineVerificationStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func reports(for profileID: UUID) -> [OfflineVerificationReport] {
        reportsByProfileID[profileID.uuidString] ?? []
    }

    func latestReport(for profileID: UUID) -> OfflineVerificationReport? {
        reports(for: profileID).first
    }

    func status(for profile: DeviceProfile) -> OfflineVerificationStatus {
        guard let report = latestReport(for: profile.id) else { return .notStarted }
        guard report.isCurrent(for: profile) else { return .outdated }
        switch report.outcome {
        case .verified:
            return .verified
        case .needsAttention:
            return .needsAttention
        case .inconclusive:
            return .inconclusive
        case .skipped:
            return .skipped
        }
    }

    /// An incomplete or stale report must never be used as a device-wide method
    /// recommendation. A mounted app-owned browser fixture has to add concrete
    /// method evidence after the offline core checks are complete.
    func allowsRecommendation(for profile: DeviceProfile) -> Bool {
        guard let report = latestReport(for: profile.id),
              report.isCurrent(for: profile),
              report.outcome == .verified,
              report.fixtureMethod != nil,
              report.check(.browserFixture)?.status == .passed
        else {
            return false
        }
        return true
    }

    func append(_ report: OfflineVerificationReport) {
        let key = report.profileID.uuidString
        var next = reportsByProfileID[key] ?? []
        next.removeAll { $0.id == report.id }
        next.append(report)
        next.sort { $0.timestamp > $1.timestamp }
        reportsByProfileID[key] = Array(next.prefix(Self.maximumReportsPerProfile))
        save()
    }

    func removeAll(for profileID: UUID) {
        guard reportsByProfileID.removeValue(forKey: profileID.uuidString) != nil else { return }
        save()
    }

    /// Adds or replaces concrete evidence from the mounted app-owned browser
    /// fixture. This does not convert the deliberately unverified external-site
    /// check into a pass.
    func recordFixtureEvidence(
        for profile: DeviceProfile,
        method: InjectionMethodKind?,
        passed: Bool,
        summary: String
    ) {
        guard var report = latestReport(for: profile.id), report.isCurrent(for: profile) else { return }

        report.checks.removeAll { $0.id == .browserFixture }
        report.checks.append(OfflineVerificationCheck(
            id: .browserFixture,
            status: passed ? .passed : .needsAttention,
            summary: summary,
            evidence: method?.rawValue ?? "",
            isRequired: false
        ))
        report.fixtureMethod = passed ? method : nil
        report.fixtureSummary = summary
        append(report)
    }

    func clearAll() {
        reportsByProfileID = [:]
        defaults.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        reportsByProfileID = (try? JSONDecoder().decode([String: [OfflineVerificationReport]].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reportsByProfileID) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
