import Foundation
import Observation

/// Persists the opt-in "ask me every request" settings plus any per-site
/// remembered answers. Everything defaults to off, so the app behaves exactly as
/// it always has until the mode is explicitly enabled.
@MainActor
@Observable
final class CameraPromptStore {
    private let settingsKey = "fslCameraPromptSettings"
    private let siteRulesKey = "fslCameraPromptSiteRules"
    /// One-time purge marker. Saved answers written before the rule below existed
    /// could divert or block a site's camera even with Ask Me switched off, and
    /// were keyed to embedded-frame addresses that never appear in the UI. There
    /// is no way to tell a deliberate answer from a stray one, so they all go.
    private let purgedLegacyRulesKey = "fslCameraPromptSiteRulesPurged_v2"

    private let defaults: UserDefaults

    private(set) var settings: CameraPromptSettings = .off
    /// host -> remembered action for that site.
    private(set) var siteRules: [String: CameraRequestAction] = [:]

    static let shared = CameraPromptStore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        purgeLegacySiteRulesIfNeeded()
    }

    // MARK: - Settings

    func update(_ transform: (inout CameraPromptSettings) -> Void) {
        var next = settings
        transform(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    func setEnabled(_ enabled: Bool) {
        update { $0.isEnabled = enabled }
    }

    // MARK: - Per-site rules

    /// A remembered answer for this site, if one may be applied.
    ///
    /// Requires Ask Me to be ON. A saved answer is a shortcut for a question the
    /// user chose to be asked — with the question turned off it must never act on
    /// its own. Without this guard a single saved "use the real camera" silently
    /// hijacked every later request to that address, with nothing on screen.
    func rule(for host: String) -> CameraRequestAction? {
        guard settings.isEnabled, settings.rememberPerSite, !host.isEmpty else { return nil }
        return siteRules[host.lowercased()]
    }

    func remember(_ action: CameraRequestAction, for host: String) {
        guard !host.isEmpty else { return }
        siteRules[host.lowercased()] = action
        saveSiteRules()
    }

    func forget(host: String) {
        guard siteRules.removeValue(forKey: host.lowercased()) != nil else { return }
        saveSiteRules()
    }

    func clearAllSiteRules() {
        guard !siteRules.isEmpty else { return }
        siteRules.removeAll()
        saveSiteRules()
    }

    /// Clears every saved answer AND returns the ask settings to off, so a stuck
    /// site cannot keep being diverted by anything remembered here.
    func resetToWorkingDefaults() {
        siteRules.removeAll()
        saveSiteRules()
        settings = .off
        save()
    }

    private func purgeLegacySiteRulesIfNeeded() {
        guard !defaults.bool(forKey: purgedLegacyRulesKey) else { return }
        defaults.set(true, forKey: purgedLegacyRulesKey)
        guard !siteRules.isEmpty else { return }
        siteRules.removeAll()
        saveSiteRules()
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(CameraPromptSettings.self, from: data) {
            settings = decoded
        }
        if let data = defaults.data(forKey: siteRulesKey),
           let decoded = try? JSONDecoder().decode([String: CameraRequestAction].self, from: data) {
            siteRules = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    private func saveSiteRules() {
        guard let data = try? JSONEncoder().encode(siteRules) else { return }
        defaults.set(data, forKey: siteRulesKey)
    }
}
