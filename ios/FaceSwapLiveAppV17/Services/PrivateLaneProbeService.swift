import Foundation
import WebKit

/// The app-only isolated JS world ("private lane") the viability check uses.
/// WebKit gives scripts in a named isolated content world their own global
/// scope and a separate security-policy path — the same lane Safari's own
/// extensions use — so a background engine started here can, in principle, run
/// on sites that block the page's own lane. Stage 1 confirms that empirically.
@MainActor
enum PrivateLane {
    static let worldName = "fslPrivateLane"
    static let world: WKContentWorld = .world(name: worldName)
}

/// Runs the Stage 1 private-lane viability check against the live browser page:
/// it starts the clean-feed engine in the site's own lane and in the private
/// lane, side by side, then reports which one came alive. It never touches the
/// user's live feed — both probes are self-contained and self-cleaning.
@Observable
@MainActor
final class PrivateLaneProbeService {
    var latestReport: PrivateLaneProbeReport?
    var isRunning: Bool = false
    var status: String = ""

    private let storeKey = "private_lane_probe_reports_v1"
    private var records: [String: PrivateLaneProbeReport] = [:]

    init() { loadRecords() }

    /// Shows the cached outcome for the currently-loaded site instantly, so
    /// re-opening Diagnostics doesn't require re-running the check.
    func loadCachedForCurrentSite() {
        guard let host = InjectionStreamRegistry.shared.activeWebView?.url?.host(), !host.isEmpty else { return }
        if let cached = records[host] { latestReport = cached }
    }

    /// Runs the identical engine-start probe in the page world and the private
    /// lane against the same loaded page, then builds and caches the verdict.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        status = "Opening the private lane and starting the engine…"
        defer { isRunning = false }

        guard let webView = InjectionStreamRegistry.shared.activeWebView else {
            status = "Open the Browser tab and load a site first, then run this check."
            return
        }
        let host = webView.url?.host() ?? ""

        // Sequential rather than concurrent: two Dedicated-Worker VideoTrackGenerator
        // pipelines in the same web-content process at once can contend, which
        // would muddy the side-by-side comparison. Both run against the same
        // loaded page, so the difference is still genuinely page-controlled.
        let pageResult = await probe(webView: webView, world: .page)
        let privateResult = await probe(webView: webView, world: PrivateLane.world)

        guard pageResult != nil || privateResult != nil else {
            status = "The page blocked the check before it could finish. Reload the site and try again."
            return
        }

        let csp = InjectionStreamRegistry.shared.csp(for: host)
        let report = PrivateLaneProbeReport(
            host: host,
            cspEnforced: csp?.enforced ?? "",
            cspReportOnly: csp?.reportOnly ?? "",
            page: pageResult ?? PrivateLaneWorldResult(),
            privateLane: privateResult ?? PrivateLaneWorldResult()
        )
        latestReport = report
        status = ""

        if !host.isEmpty {
            records[host] = report
            persist()
        }
    }

    func clear() {
        latestReport = nil
        status = ""
    }

    func clearAll() {
        latestReport = nil
        records.removeAll()
        UserDefaults.standard.removeObject(forKey: storeKey)
        status = ""
    }

    // MARK: - Probe execution

    private func probe(webView: WKWebView, world: WKContentWorld) async -> PrivateLaneWorldResult? {
        let result = try? await webView.callAsyncJavaScript(
            StyleSheetProvider.privateLaneProbeBody,
            arguments: [:],
            contentWorld: world
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.parse(raw)
    }

    private static func parse(_ raw: [String: Any]) -> PrivateLaneWorldResult {
        func bool(_ key: String) -> Bool { (raw[key] as? Bool) ?? ((raw[key] as? NSNumber)?.boolValue ?? false) }
        func double(_ key: String) -> Double { (raw[key] as? Double) ?? ((raw[key] as? NSNumber)?.doubleValue ?? 0) }
        func int(_ key: String) -> Int { (raw[key] as? Int) ?? ((raw[key] as? NSNumber)?.intValue ?? 0) }
        func string(_ key: String) -> String { raw[key] as? String ?? "" }
        return PrivateLaneWorldResult(
            ran: bool("ran"),
            laneTag: double("laneTag"),
            capable: bool("capable"),
            workerStarted: bool("workerStarted"),
            trackProduced: bool("trackProduced"),
            frameVerified: bool("frameVerified"),
            error: string("error"),
            ms: int("ms"),
            metaCSP: string("metaCSP")
        )
    }

    // MARK: - Per-site memory

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: PrivateLaneProbeReport].self, from: data) else { return }
        records = decoded
    }

    private func persist() {
        // Keep the cache bounded to the most recent sites.
        if records.count > 40 {
            let trimmed = records.sorted { $0.value.timestamp > $1.value.timestamp }.prefix(40)
            records = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
