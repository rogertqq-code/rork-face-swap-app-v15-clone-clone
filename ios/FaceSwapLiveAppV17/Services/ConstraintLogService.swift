import Foundation

@Observable
@MainActor
final class ConstraintLogService {
    var entries: [ConstraintLogEntry] = []

    private let storageKey = "constraint_log_v1"

    init() {
        loadEntries()
    }

    func addEntry(_ entry: ConstraintLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 {
            entries = Array(entries.prefix(200))
        }
        saveEntries()
    }

    func addEntries(_ newEntries: [ConstraintLogEntry]) {
        entries.insert(contentsOf: newEntries, at: 0)
        if entries.count > 200 {
            entries = Array(entries.prefix(200))
        }
        saveEntries()
    }

    func clearLog() {
        entries = []
        saveEntries()
    }

    func entriesForSite(_ url: String) -> [ConstraintLogEntry] {
        entries.filter { $0.siteURL == url }
    }

    func reload() {
        loadEntries()
    }

    private func loadEntries() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            entries = try JSONDecoder().decode([ConstraintLogEntry].self, from: data)
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
