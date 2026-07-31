import Foundation
import WebKit

@Observable
@MainActor
final class DiagnosticsTestHarness {

    var latestReport: DiagnosticsFullTestReport?
    var isRunning: Bool = false
    var progress: Double = 0
    var progressLabel: String = ""
    var lastError: String = ""

    private(set) weak var webView: WKWebView?
    var pageReady: Bool = false
    private var profile: DeviceProfile?

    private static let baseURL = URL(string: "https://fsl.diagnostics.local/camera-test")!

    init() {}

    // MARK: - Web view attachment

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func markPageLoaded() {
        pageReady = true
    }

    // MARK: - Full test

    func runFullTest(
        profileManager: DeviceProfileManager,
        verificationStore: OfflineVerificationStore
    ) async {
        guard !isRunning else { return }
        guard var profile = profileManager.activeProfile else {
            lastError = "No profile available to run the test."
            return
        }
        guard let mountedWebView = webView else {
            lastError = "The built-in fixture is not mounted yet. Keep Diagnostics open for a moment, then try again."
            return
        }

        isRunning = true
        progress = 0
        lastError = ""
        progressLabel = "Preparing the mounted offline fixture…"
        defer { isRunning = false }

        let engine = DeviceTestEngine()
        let result = await engine.runMountedFixtureTest(profile: profile, on: mountedWebView) { [weak self] _, pct, label in
            Task { @MainActor in
                self?.progress = pct
                self?.progressLabel = label
            }
        }

        guard let result, let environment = result.environment else {
            lastError = "The built-in fixture did not complete. No recommendation was changed."
            progressLabel = ""
            return
        }

        latestReport = DiagnosticsFullTestReport(
            environment: environment,
            results: result.methodResults,
            passthrough: result.passthroughResult ?? DiagPassthroughResult(status: .skip, note: ""),
            block: result.blockResult ?? DiagBlockResult(refused: false, gumError: "", status: .skip, note: ""),
            recommendedMethodRaw: result.recommendedMethod?.rawValue ?? "",
            summaryLine: result.summaryLine
        )

        let fixturePassed = result.recommendedMethod != nil
        verificationStore.recordFixtureEvidence(
            for: profile,
            method: result.recommendedMethod,
            passed: fixturePassed,
            summary: fixturePassed
                ? "The mounted app-owned fixture observed complete stream and native file-delivery checks."
                : "The mounted app-owned fixture did not produce complete passing evidence for a delivery method."
        )

        if let method = result.recommendedMethod,
           verificationStore.allowsRecommendation(for: profile) {
            profile.recommendedMethod = method
            profile.recommendedAdjustments = result.recommendedAdjustments
            profileManager.updateProfile(profile)
        }

        progress = 1.0
        progressLabel = "Done — \(result.summaryLine)"
    }

    // MARK: - Scoring

    static func overall(for r: DiagMethodResult) -> DiagTestStatus {
        if !r.armed { return .fail }
        if !r.gumSucceeded { return .fail }
        if !r.framesFlowing { return .fail }
        // Both delivery surfaces must genuinely receive a non-empty native file:
        // an ordinary file pick and a camera-style capture take different paths.
        if !r.pickerReturnedMedia || r.pickerFileSize <= 0 { return .fail }
        if !r.captureReturnedMedia || r.captureFileSize <= 0 { return .fail }
        let intendedClean = (r.methodRaw == "rawFramePipe" || r.methodRaw == "privateLane")
        if intendedClean && r.feed == "canvas" && r.reason != "photo-step" { return .warn }
        if r.methodRaw == "privateLane" && r.feed == "vtg" && r.lane != "private" { return .warn }
        if r.detectorChecks.contains(where: { $0.status == .fail }) { return .warn }
        return .pass
    }

    static func notes(for r: DiagMethodResult) -> String {
        if !r.armed { return "Camera takeover not armed — the real camera would pass through. \(r.armError)" }
        if !r.gumSucceeded { return "getUserMedia failed: \(r.gumError)" }
        if !r.framesFlowing { return "No frames were delivered — the served feed is black/frozen." }
        if !r.pickerReturnedMedia || r.pickerFileSize <= 0 { return "The built-in file input did not receive a native file, so this method cannot be recommended." }
        if !r.captureReturnedMedia || r.captureFileSize <= 0 { return "The built-in camera-style capture did not receive a native file, so this method cannot be recommended." }
        if r.feed == "canvas" && r.reason == "photo-step" { return "Still photo intentionally uses the Canvas draw (no video to stream)." }
        if r.downgraded && !r.reason.isEmpty { return "Downgraded to Canvas — \(InjectionFeed.reasonText(r.reason))" }
        if r.methodRaw == "privateLane" && r.feed == "vtg" && r.lane == "private" { return "Clean feed ran through the private lane." }
        if r.feed == "vtg" { return "Clean background track engaged." }
        if r.feed == "canvas" { return "Canvas feed engaged (the engine for this method)." }
        return ""
    }

    static func recommendMethod(from results: [DiagMethodResult]) -> InjectionMethodKind? {
        var best: InjectionMethodKind?
        var bestScore = -1
        for method in InjectionMethodKind.deliveryMethods {
            let rows = results.filter { $0.methodRaw == method.rawValue }
            guard !rows.isEmpty else { continue }
            var score = 0
            for row in rows {
                switch row.overall {
                case .pass: score += 100
                case .warn: score += 40
                default: score += 0
                }
                score += row.detectorScore / 4
                if row.feed == "vtg" { score += 15 }
            }
            if score > bestScore { bestScore = score; best = method }
        }
        return best
    }

    static func summaryLine(results: [DiagMethodResult], recommended: InjectionMethodKind?) -> String {
        let pass = results.filter { $0.overall == .pass }.count
        let warn = results.filter { $0.overall == .warn }.count
        let fail = results.filter { $0.overall == .fail }.count
        var parts = ["\(pass) passed"]
        if warn > 0 { parts.append("\(warn) downgraded") }
        if fail > 0 { parts.append("\(fail) failed") }
        var line = parts.joined(separator: ", ")
        if let recommended { line += " · best: \(recommended.label)" }
        return line
    }

    static func parseDetectorChecks(_ raw: Any?) -> [DetectorSelfTestCheck] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.map { entry in
            DetectorSelfTestCheck(
                checkID: entry["id"] as? String ?? UUID().uuidString,
                title: entry["title"] as? String ?? "Check",
                status: DetectorCheckStatus(rawValue: entry["status"] as? String ?? "skip") ?? .skip,
                detail: entry["detail"] as? String ?? ""
            )
        }
    }

    static func iosVersion(from ua: String) -> String {
        guard let range = ua.range(of: "OS ") else { return "" }
        let tail = ua[range.upperBound...]
        let token = tail.prefix { $0.isNumber || $0 == "_" }
        return token.replacingOccurrences(of: "_", with: ".")
    }

    static func resolutionLabel(_ profile: DeviceProfile?) -> String {
        guard let cam = profile?.frontCamera else { return "1280×720 (default)" }
        return "\(cam.activeWidth)×\(cam.activeHeight)"
    }
}
