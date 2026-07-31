import Foundation

/// Persists, per site, which injection profile was used and whether it worked,
/// then blends that history into smarter recommendations — both for the exact
/// host and for the detected system category.
@Observable
@MainActor
final class SiteProfileMemoryService {
    var records: [SiteProfileRecord] = []

    private let storageKey = "site_profile_memory_v1"

    init() {
        load()
    }

    // MARK: - Lookups

    func record(for host: String) -> SiteProfileRecord? {
        let key = Self.normalizedHost(host)
        guard !key.isEmpty else { return nil }
        return records.first { $0.host == key }
    }

    /// Sorted most-recent-first for the memory list.
    var sortedRecords: [SiteProfileRecord] {
        records.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Writes

    /// Upserts the camera method and optional network backend a user confirmed
    /// for a host. Changing either part resets the outcome to untested;
    /// re-confirming the same setup keeps the learned verdict.
    func confirm(
        profile: InjectionMethodKind,
        networkBackend: NetworkBackendOptions = .off,
        host: String,
        detected: DetectedSystem?
    ) {
        let key = Self.normalizedHost(host)
        guard !key.isEmpty else { return }
        let cameraProfile = profile.migratedCameraMethod
        let backend = profile.migratedNetworkBackend ?? networkBackend
        if let idx = records.firstIndex(where: { $0.host == key }) {
            var record = records[idx]
            if record.profile != cameraProfile || record.networkBackend != backend {
                record.profile = cameraProfile
                record.networkBackend = backend
                record.outcome = .untested
                record.autoGuessed = false
            }
            if let detected {
                record.detectedCategory = detected.category
                record.detectedSystemName = detected.systemName
            }
            record.updatedAt = Date()
            records[idx] = record
        } else {
            records.append(SiteProfileRecord(
                host: key,
                profile: cameraProfile,
                networkBackend: backend,
                outcome: .untested,
                autoGuessed: false,
                detectedCategory: detected?.category,
                detectedSystemName: detected?.systemName
            ))
        }
        save()
    }

    /// Updates only the remembered network backend for a site, preserving the
    /// chosen camera method. Creates a record if this is the first setting saved
    /// for that host.
    func setNetworkBackend(
        _ backend: NetworkBackendOptions,
        for host: String,
        profile: InjectionMethodKind,
        detected: DetectedSystem?
    ) {
        confirm(profile: profile, networkBackend: backend, host: host, detected: detected)
    }

    /// User verdict — authoritative, never overwritten by later auto-guesses.
    func setOutcome(_ outcome: SiteOutcome, for host: String) {
        let key = Self.normalizedHost(host)
        guard let idx = records.firstIndex(where: { $0.host == key }) else { return }
        records[idx].outcome = outcome
        records[idx].autoGuessed = false
        records[idx].updatedAt = Date()
        save()
    }

    func setOutcome(_ outcome: SiteOutcome, forRecordID id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].outcome = outcome
        records[idx].autoGuessed = false
        records[idx].updatedAt = Date()
        save()
    }

    /// Auto-guessed outcome from page signals. Only applied when the user has
    /// not set a verdict (untested, or a previous auto-guess).
    func autoGuess(_ outcome: SiteOutcome, for host: String) {
        let key = Self.normalizedHost(host)
        guard let idx = records.firstIndex(where: { $0.host == key }) else { return }
        let current = records[idx]
        guard current.outcome == .untested || current.autoGuessed else { return }
        guard current.outcome != outcome || !current.autoGuessed else { return }
        records[idx].outcome = outcome
        records[idx].autoGuessed = true
        records[idx].updatedAt = Date()
        save()
    }

    func delete(_ record: SiteProfileRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clearAll() {
        records = []
        save()
    }

    /// Re-reads persisted records (used by screens that hold their own instance).
    func reload() {
        load()
    }

    // MARK: - Recommendation blending

    /// Blends learning memory with the scanner's default pick. Per-host "worked"
    /// wins outright; otherwise per-category history breaks ties; a per-host
    /// "failed" steers away from the failing profile.
    func recommendation(
        forHost host: String,
        category: DetectedSystemCategory,
        deviceDefault: InjectionMethodKind? = nil,
        scannerDefault: InjectionMethodKind
    ) -> (profile: InjectionMethodKind, memoryInformed: Bool) {
        let siteRecord = record(for: host)
        let categoryWinner = bestProfile(forCategory: category)
        return RecommendationResolver.resolve(
            siteRecord: siteRecord,
            categoryWinner: categoryWinner,
            deviceDefault: deviceDefault,
            scannerDefault: scannerDefault
        )
    }

    /// The profile with the most "worked" verdicts for a detected category.
    func bestProfile(forCategory category: DetectedSystemCategory) -> InjectionMethodKind? {
        var scores: [InjectionMethodKind: Int] = [:]
        for record in records where record.detectedCategory == category {
            switch record.outcome {
            case .worked: scores[record.profile, default: 0] += 2
            case .failed: scores[record.profile, default: 0] -= 1
            case .untested: break
            }
        }
        return scores.filter { $0.value > 0 && !$0.key.isLegacyNetworkBackendMethod }.max { $0.value < $1.value }?.key
    }

    // MARK: - Persistence

    private static func normalizedHost(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            return host
        }
        return trimmed
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            records = try JSONDecoder().decode([SiteProfileRecord].self, from: data)
            save()
        } catch {
            records = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Best-effort persistence.
        }
    }
}
