import Foundation

@Observable
@MainActor
final class SiteHistoryService {
    var entries: [SiteHistoryEntry] = []

    private let storageKey = "site_history_v1"

    init() {
        loadEntries()
    }

    func addEntry(_ entry: SiteHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
        saveEntries()
    }

    func entriesForSite(_ url: String) -> [SiteHistoryEntry] {
        guard let targetHost = Self.host(from: url) else {
            let needle = url.lowercased()
            return entries.filter { $0.siteURL.lowercased() == needle }
        }
        // Match on real host identity (exact or subdomain), never a loose
        // substring — otherwise "evil-example.com" would match "example.com".
        return entries.filter { entry in
            guard let entryHost = Self.host(from: entry.siteURL) else { return false }
            return Self.hostsMatch(entryHost, targetHost)
        }
    }

    /// Extracts a lowercased host, tolerating bare hosts that carry no scheme
    /// (where `URL(string:).host` returns nil).
    static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let host = URL(string: trimmed)?.host, !host.isEmpty { return host }
        var candidate = trimmed
        if let range = candidate.range(of: "://") { candidate = String(candidate[range.upperBound...]) }
        if let slash = candidate.firstIndex(of: "/") { candidate = String(candidate[..<slash]) }
        if let colon = candidate.firstIndex(of: ":") { candidate = String(candidate[..<colon]) }
        return candidate.isEmpty ? nil : candidate
    }

    /// True when two hosts are the same site: exact match or one a subdomain of
    /// the other. Rejects lookalikes a plain `contains` would wrongly accept.
    static func hostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased()
        let b = rhs.lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    func lastSuccessfulProfile(for url: String) -> String? {
        entriesForSite(url).first(where: { $0.wasSuccessful })?.profileUsed
    }

    func clearHistory() {
        entries = []
        saveEntries()
    }

    func addEntries(_ newEntries: [SiteHistoryEntry]) {
        entries.insert(contentsOf: newEntries, at: 0)
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
        saveEntries()
    }

    func uniqueSites() -> [String] {
        var sitesByKey: [String: String] = [:]

        for entry in entries {
            let key = normalizedSiteKey(for: entry.siteURL)
            if sitesByKey[key] == nil {
                sitesByKey[key] = entry.siteURL
            }
        }

        return Array(sitesByKey.values).sorted()
    }

    private func normalizedSiteKey(for urlString: String) -> String {
        let normalizedInput = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard
            let url = URL(string: normalizedInput),
            let host = url.host?.lowercased()
        else {
            return normalizedInput
        }

        if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            return "\(scheme)://\(host)"
        }

        return host
    }

    private func loadEntries() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            entries = try JSONDecoder().decode([SiteHistoryEntry].self, from: data)
        } catch {
            entries = []
        }
    }

    private func saveEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Silently fail on encode error
        }
    }
}
