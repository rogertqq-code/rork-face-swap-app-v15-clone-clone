import WebKit

/// Lightweight bridge that lets the Diagnostics drift monitor read the live
/// injected stream from the Browser tab's web view. It holds only a weak
/// reference to the active web view — it is a hardware/page bridge, not app
/// state, so it never owns or persists anything.
@MainActor
final class InjectionStreamRegistry {
    static let shared = InjectionStreamRegistry()

    weak var activeWebView: WKWebView?

    /// A site's Content-Security-Policy as seen on the main-frame response.
    struct CSPInfo: Sendable {
        var enforced: String
        var reportOnly: String
    }

    /// Latest CSP per host, captured by the browser's navigation delegate. Used
    /// by the private-lane viability check to show the strict rule a site uses.
    /// In-memory only — it is page state, never persisted.
    private var cspByHost: [String: CSPInfo] = [:]

    /// Records the CSP headers seen for a host's main-frame response.
    func recordCSP(host: String, enforced: String, reportOnly: String) {
        guard !host.isEmpty else { return }
        cspByHost[host] = CSPInfo(enforced: enforced, reportOnly: reportOnly)
    }

    /// The most recently captured CSP for a host, if any.
    func csp(for host: String) -> CSPInfo? { cspByHost[host] }

    private init() {}
}
