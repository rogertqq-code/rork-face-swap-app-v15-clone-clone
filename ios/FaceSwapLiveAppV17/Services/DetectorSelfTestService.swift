import Foundation
import WebKit

/// Runs the detector self-test against the live browser page. The JS routine
/// exercises the same tricks detection sites use (function-string checks,
/// resolution changes, identity stability, frame timing, device-list and
/// stream-shape consistency) against whatever injection method is currently
/// live, and returns a scored pass/fail report.
@Observable
@MainActor
final class DetectorSelfTestService {
    var latestReport: DetectorSelfTestReport?
    var isRunning: Bool = false
    var status: String = ""

    /// Runs the test against the active browser web view (shared via the
    /// injection-stream registry, the same bridge the drift monitor uses).
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        status = "Running detector tricks…"
        defer { isRunning = false }

        guard let webView = InjectionStreamRegistry.shared.activeWebView else {
            status = "Open the Browser tab and load a site first, then run the self-test."
            return
        }

        // The routine is async (it opens a stream and samples frame timing), so
        // it must be awaited via callAsyncJavaScript.
        let result = try? await webView.callAsyncJavaScript(
            StyleSheetProvider.detectorSelfTestBody,
            arguments: [:],
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            status = "The page blocked the self-test before it could finish. Reload the site and try again."
            return
        }

        latestReport = Self.parse(raw)
        status = ""
    }

    func clear() {
        latestReport = nil
        status = ""
    }

    private static func parse(_ raw: [String: Any]) -> DetectorSelfTestReport {
        let method = raw["method"] as? String ?? ""
        let active = (raw["active"] as? Bool) ?? ((raw["active"] as? NSNumber)?.boolValue ?? false)
        let score = (raw["score"] as? Int) ?? ((raw["score"] as? NSNumber)?.intValue ?? 0)

        var checks: [DetectorSelfTestCheck] = []
        if let rawChecks = raw["checks"] as? [[String: Any]] {
            for entry in rawChecks {
                let id = entry["id"] as? String ?? UUID().uuidString
                let title = entry["title"] as? String ?? "Check"
                let statusRaw = entry["status"] as? String ?? "skip"
                let detail = entry["detail"] as? String ?? ""
                checks.append(DetectorSelfTestCheck(
                    checkID: id,
                    title: title,
                    status: DetectorCheckStatus(rawValue: statusRaw) ?? .skip,
                    detail: detail
                ))
            }
        }

        return DetectorSelfTestReport(
            methodRaw: method,
            active: active,
            score: score,
            checks: checks
        )
    }
}
