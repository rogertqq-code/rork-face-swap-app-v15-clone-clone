import Foundation
import WebKit

/// Outcome of a one-tap fixer, in plain language the user can act on.
nonisolated struct DiagFixResult: Codable, Sendable {
    var ok: Bool
    var headline: String
    var lines: [String]
    var timestamp: Date

    init(ok: Bool = false, headline: String = "", lines: [String] = [], timestamp: Date = Date()) {
        self.ok = ok
        self.headline = headline
        self.lines = lines
        self.timestamp = timestamp
    }
}

/// The two targeted one-tap fixers surfaced on the Diagnostics screen. Both act
/// on the LIVE browser web view (shared via `InjectionStreamRegistry`) so they
/// fix the site the user is actually on.
@Observable
@MainActor
final class DiagnosticsFixService {
    var isFixingInjection: Bool = false
    var isFixingTrusted: Bool = false
    var injectionResult: DiagFixResult?
    var trustedResult: DiagFixResult?

    // MARK: - Fix Injection

    /// Re-installs the camera takeover on the current page if it silently failed
    /// to arm (self-heal via `engineArmCheckScript`), then reports honestly what
    /// it found and fixed — the deliberate, visible version of the "real camera
    /// passing through" reliability fix.
    func fixInjection() async {
        guard !isFixingInjection else { return }
        isFixingInjection = true
        defer { isFixingInjection = false }

        guard let webView = InjectionStreamRegistry.shared.activeWebView else {
            injectionResult = DiagFixResult(ok: false, headline: "No page to fix", lines: ["Open the Browser tab and load a site first, then tap Fix Injection."])
            return
        }

        // engineArmCheckScript self-heals: it re-runs arm() for any missing piece.
        let armRaw = await evaluateJSON(webView, StyleSheetProvider.engineArmCheckScript)
        let timingRaw = await callAsyncJSON(webView, StyleSheetProvider.injectedFrameTimingBody)

        guard let arm = armRaw else {
            injectionResult = DiagFixResult(ok: false, headline: "Couldn't reach the page engine", lines: ["The page blocked the check. Reload the site and try again."])
            return
        }

        let present = boolVal(arm["present"])
        let armed = boolVal(arm["armed"])
        let partial = boolVal(arm["partial"])
        let gum = boolVal(arm["gum"])
        let method = arm["method"] as? String ?? ""
        let armError = arm["error"] as? String ?? ""

        var lines: [String] = []
        lines.append(present ? "Engine loaded on the page: yes" : "Engine loaded on the page: NO")

        if !present {
            injectionResult = DiagFixResult(
                ok: false,
                headline: "Engine not loaded",
                lines: lines + ["The camera engine hasn't installed on this page. Reload the site to load it, then tap Fix Injection again."]
            )
            return
        }

        lines.append(armed ? "Camera takeover armed: yes (self-healed if needed)" : "Camera takeover armed: NO")
        if partial { lines.append("Some secondary pieces (device list / picker / srcObject) needed re-installing — done.") }
        if !gum { lines.append("The core getUserMedia gate is missing — the real camera can still pass through.") }
        if !armError.isEmpty { lines.append("Arm detail: \(armError)") }

        // What is actually being served right now.
        if let timing = timingRaw {
            let active = boolVal(timing["active"])
            let feed = timing["feed"] as? String ?? ""
            let lane = timing["lane"] as? String ?? ""
            let downgraded = boolVal(timing["downgraded"])
            let reason = timing["reason"] as? String ?? ""
            let methodLabel = InjectionMethodKind(rawValue: method)?.label ?? "current method"

            if !active {
                lines.append("Media is not currently on — turn on Enable Media in the browser to serve your media.")
            } else if feed == "vtg" {
                lines.append(lane == "private" ? "Serving now: clean track via the private lane (\(methodLabel))." : "Serving now: clean background track (\(methodLabel)).")
            } else if feed == "canvas" {
                if downgraded && reason != "photo-step" {
                    lines.append("Serving now: Canvas — downgraded from the clean feed because \(InjectionFeed.reasonText(reason))")
                } else {
                    lines.append("Serving now: Canvas feed (\(methodLabel)).")
                }
            } else {
                lines.append("No feed engine has engaged yet — request the camera on the site to start it.")
            }
        }

        let healthy = present && armed && gum
        injectionResult = DiagFixResult(
            ok: healthy,
            headline: healthy ? "Injection is armed" : "Injection needs attention",
            lines: lines
        )
    }

    // MARK: - Fix Trusted-Browser

    /// Re-asserts the phone's Safari identity, fingerprint stabilization, and the
    /// native-code disguises, then reports whether the page now looks like a
    /// genuine untouched phone browser.
    func fixTrustedBrowser(profile: DeviceProfile?) async {
        guard !isFixingTrusted else { return }
        isFixingTrusted = true
        defer { isFixingTrusted = false }

        guard let webView = InjectionStreamRegistry.shared.activeWebView else {
            trustedResult = DiagFixResult(ok: false, headline: "No page to fix", lines: ["Open the Browser tab and load a site first, then tap Fix Trusted-Browser."])
            return
        }

        // Re-apply identity + fingerprint stabilization on the spot.
        if let profile {
            webView.evaluateJavaScript(StyleSheetProvider.profileApplyScript(from: profile, method: .canvasPipeline), completionHandler: nil)
            webView.evaluateJavaScript(StyleSheetProvider.buildFingerprintStabilizationJS(from: profile), completionHandler: nil)
            try? await Task.sleep(for: .milliseconds(120))
        }

        guard let raw = await evaluateJSON(webView, DiagnosticsHarnessScripts.trustedBrowserCheckScript) else {
            trustedResult = DiagFixResult(ok: false, headline: "Couldn't read the page identity", lines: ["The page blocked the check. Reload the site and try again."])
            return
        }

        let trusted = boolVal(raw["trusted"])
        let looksSafari = boolVal(raw["looksSafari"])
        let looksApple = boolVal(raw["looksApple"])
        let secure = boolVal(raw["secureContext"])
        let gumNative = boolVal(raw["gumNative"])
        let enumerateNative = boolVal(raw["enumerateNative"])
        let toStringNative = boolVal(raw["toStringNative"])
        let webdriver = boolVal(raw["webdriver"])
        let hasChrome = boolVal(raw["hasChrome"])

        var lines: [String] = []
        lines.append(looksSafari ? "Reads as mobile Safari: yes" : "Reads as mobile Safari: NO")
        lines.append(looksApple ? "Reads as an Apple device: yes" : "Reads as an Apple device: NO")
        lines.append(secure ? "Secure (trusted) context: yes" : "Secure (trusted) context: no")
        lines.append((gumNative && enumerateNative) ? "Camera functions look native: yes" : "Camera functions look native: NO")
        lines.append(toStringNative ? "Native-code disguises intact: yes" : "Native-code disguises intact: NO")
        if webdriver { lines.append("navigator.webdriver is exposed — a strong automation tell.") }
        if hasChrome { lines.append("A Chrome object is present — unexpected for Safari.") }
        if let profile { lines.append("Re-applied identity from profile: \(profile.name)") }
        else { lines.append("No device profile is set — add one so a specific phone identity is presented.") }

        trustedResult = DiagFixResult(
            ok: trusted,
            headline: trusted ? "Looks like a genuine phone browser" : "Browser identity needs attention",
            lines: lines
        )
    }

    func clearInjectionResult() { injectionResult = nil }
    func clearTrustedResult() { trustedResult = nil }

    // MARK: - Helpers

    private func evaluateJSON(_ webView: WKWebView, _ script: String) async -> [String: Any]? {
        let result = try? await webView.evaluateJavaScript(script)
        return decode(result)
    }

    private func callAsyncJSON(_ webView: WKWebView, _ body: String) async -> [String: Any]? {
        let result = try? await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
        return decode(result)
    }

    private func decode(_ result: Any?) -> [String: Any]? {
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func boolVal(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }
}
