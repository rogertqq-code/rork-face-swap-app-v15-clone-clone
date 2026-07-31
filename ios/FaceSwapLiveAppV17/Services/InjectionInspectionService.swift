import Foundation
import WebKit

@Observable
@MainActor
final class InjectionInspectionService {
    var reports: [InjectionInspectionReport] = []
    var isInspecting: Bool = false

    private let storageKey = "injection_inspection_reports_v1"

    init() {
        loadReports()
    }

    func inspectCurrentPage(
        in webView: WKWebView,
        mediaWasActive: Bool,
        sequenceLength: Int
    ) async -> InjectionInspectionReport? {
        guard !isInspecting else { return nil }
        isInspecting = true
        defer { isInspecting = false }

        guard let jsonString = await evaluateInspectorScript(in: webView),
              let data = jsonString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let fallbackURL = webView.url?.absoluteString ?? "Unknown page"
            let fallbackReport = buildEvaluationFailureReport(
                url: fallbackURL,
                title: webView.title ?? "",
                mediaWasActive: mediaWasActive,
                sequenceLength: sequenceLength
            )
            addReport(fallbackReport)
            return fallbackReport
        }

        let report = buildReport(
            from: raw,
            mediaWasActive: mediaWasActive,
            sequenceLength: sequenceLength
        )
        addReport(report)
        return report
    }

    func reportsForSite(_ siteURL: String) -> [InjectionInspectionReport] {
        let host = normalizedHost(for: siteURL)
        // An empty host would make a substring match every report, leaking
        // another site's verdict into the current page's delivery decisions.
        // Bail out so callers fall back to safe defaults instead.
        guard !host.isEmpty else { return [] }
        // Match on real host identity (exact or subdomain), never a loose
        // substring — otherwise "evil-example.com" would match "example.com".
        return reports.filter { report in
            if Self.hostsMatch(report.host, host) { return true }
            let reportHost = normalizedHost(for: report.siteURL)
            return Self.hostsMatch(reportHost, host)
        }
    }

    func latestReport(for siteURL: String) -> InjectionInspectionReport? {
        reportsForSite(siteURL).first
    }

    func clearReports() {
        reports = []
        saveReports()
    }

    func reload() {
        loadReports()
    }

    private func evaluateInspectorScript(in webView: WKWebView) async -> String? {
        // The inspection routine is async (image decode, permission queries), so it
        // MUST be awaited via callAsyncJavaScript. evaluateJavaScript returns an
        // unsupported-type error for the Promise, which produced the false
        // "Inspection blocked" verdict on every run.
        let result = try? await webView.callAsyncJavaScript(
            StyleSheetProvider.injectionInspectionBody,
            arguments: [:],
            contentWorld: .page
        )
        return result as? String
    }

    private func buildReport(
        from raw: [String: Any],
        mediaWasActive: Bool,
        sequenceLength: Int
    ) -> InjectionInspectionReport {
        let url = string(raw["url"], fallback: "Unknown page")
        let host = normalizedHost(for: url)
        let title = string(raw["title"])
        let userAgent = string(raw["userAgent"])
        let cspText = string(raw["cspText"])
        let findings = buildFindings(from: raw, mediaWasActive: mediaWasActive, sequenceLength: sequenceLength)
        let likelyBlocker = mostLikelyBlocker(from: findings)
        let riskScore = calculateRiskScore(from: findings)
        let verdict = verdict(for: findings, likelyBlocker: likelyBlocker, riskScore: riskScore)

        return InjectionInspectionReport(
            siteURL: url,
            host: host,
            pageTitle: title,
            verdictTitle: verdict.title,
            verdictDetail: verdict.detail,
            mostLikelyBlocker: likelyBlocker,
            riskScore: riskScore,
            userAgent: userAgent,
            cspPolicyText: cspText,
            mediaWasActive: mediaWasActive,
            sequenceLength: sequenceLength,
            findings: findings
        )
    }

    private func buildEvaluationFailureReport(
        url: String,
        title: String,
        mediaWasActive: Bool,
        sequenceLength: Int
    ) -> InjectionInspectionReport {
        let finding = InjectionProbeFinding(
            severity: .blocked,
            blocker: .unknown,
            title: "Inspector could not run",
            detail: "The page prevented or interrupted the diagnostic script before it could return a report.",
            evidence: "No JavaScript result returned"
        )
        return InjectionInspectionReport(
            siteURL: url,
            host: normalizedHost(for: url),
            pageTitle: title,
            verdictTitle: "Inspection blocked",
            verdictDetail: "The page did not allow the diagnostic pass to complete, so this site needs manual testing with console/runtime logs.",
            mostLikelyBlocker: .unknown,
            riskScore: 100,
            userAgent: "",
            cspPolicyText: "",
            mediaWasActive: mediaWasActive,
            sequenceLength: sequenceLength,
            findings: [finding]
        )
    }

    private func buildFindings(
        from raw: [String: Any],
        mediaWasActive: Bool,
        sequenceLength: Int
    ) -> [InjectionProbeFinding] {
        var findings: [InjectionProbeFinding] = []

        if bool(raw["secureContext"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "Secure context available",
                detail: "Camera APIs are allowed to run on this page origin."
            ))
        } else {
            findings.append(.init(
                severity: .blocked,
                blocker: .cameraPermission,
                title: "Page is not a secure context",
                detail: "Browser camera APIs require a secure HTTPS context. This page may not be able to request camera access at all.",
                evidence: "window.isSecureContext=false"
            ))
        }

        if bool(raw["hasMediaDevices"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "MediaDevices is present",
                detail: "navigator.mediaDevices is available on this page."
            ))
        } else {
            findings.append(.init(
                severity: .blocked,
                blocker: .cameraPermission,
                title: "MediaDevices is missing",
                detail: "The page cannot reach navigator.mediaDevices, so camera replacement cannot be evaluated here."
            ))
        }

        let cspText = string(raw["cspText"])
        if cspText.isEmpty {
            findings.append(.init(
                severity: .info,
                blocker: .none,
                title: "No visible in-page security policy",
                detail: "No Content-Security-Policy meta tag was found in the loaded document. Header-only policies may still exist but are not visible to page JavaScript."
            ))
        } else {
            let policyFindings = analyzeCSP(cspText)
            findings.append(contentsOf: policyFindings)
        }

        let policyCamera = string(raw["policyCameraAllowed"], fallback: "unknown")
        if policyCamera == "false" {
            findings.append(.init(
                severity: .blocked,
                blocker: .permissionsPolicy,
                title: "Camera blocked by permissions policy",
                detail: "This page reports that its active policy does not allow camera use in the current frame.",
                evidence: "camera policy=false"
            ))
        } else if policyCamera == "true" {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "Camera policy allows this frame",
                detail: "The browser policy reports camera access is allowed for the current frame."
            ))
        }

        let permissionState = string(raw["cameraPermissionState"])
        if permissionState == "denied" {
            findings.append(.init(
                severity: .blocked,
                blocker: .cameraPermission,
                title: "Camera permission is denied",
                detail: "The browser permission state is denied for this origin.",
                evidence: "permissions.query(camera)=denied"
            ))
        } else if !permissionState.isEmpty && permissionState != "unsupported" {
            findings.append(.init(
                severity: .info,
                blocker: .cameraPermission,
                title: "Camera permission state captured",
                detail: "The page reports camera permission as \(permissionState).",
                evidence: permissionState
            ))
        }

        addDeliveryFinding(
            &findings,
            ok: bool(raw["dataImageOK"]),
            title: "Data-image delivery",
            blockedTitle: "Data-image delivery blocked",
            detail: "An in-page data image can be decoded and drawn without a network-style request.",
            evidence: string(raw["dataImageError"])
        )
        addDeliveryFinding(
            &findings,
            ok: bool(raw["blobImageOK"]),
            title: "Blob-image delivery",
            blockedTitle: "Blob-image delivery blocked",
            detail: "An in-page blob URL can be decoded and drawn by the page.",
            evidence: string(raw["blobImageError"])
        )

        if bool(raw["createImageBitmapOK"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "CSP-immune createImageBitmap path available",
                detail: "createImageBitmap is present. Photos can be delivered with zero network requests, bypassing all CSP directives."
            ))
        } else {
            let err = string(raw["createImageBitmapError"])
            findings.append(.init(
                severity: .warning,
                blocker: .mediaDelivery,
                title: "CSP-immune createImageBitmap path unavailable",
                detail: "createImageBitmap is not available in this page context. Photos will fall back to fetch-based delivery which may be blocked by CSP.",
                evidence: err.isEmpty ? "createImageBitmap not found" : err
            ))
        }

        if bool(raw["putImageDataOK"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "CSP-immune putImageData path available",
                detail: "putImageData is functional. This is the highest-confidence delivery method — raw pixel writes to canvas that CSP cannot block."
            ))
        } else {
            let err = string(raw["putImageDataError"])
            findings.append(.init(
                severity: .warning,
                blocker: .mediaDelivery,
                title: "CSP-immune putImageData path unavailable",
                detail: "putImageData is not available in this page context. The strongest CSP-immune photo delivery path is offline.",
                evidence: err.isEmpty ? "putImageData or ImageData constructor is not available" : err
            ))
        }

        if bool(raw["canvasCaptureOK"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "Canvas stream creation works",
                detail: "The page can create a MediaStream from an in-page canvas."
            ))
        } else {
            findings.append(.init(
                severity: .blocked,
                blocker: .streamShape,
                title: "Canvas stream creation failed",
                detail: "The replacement camera stream cannot be assembled if canvas.captureStream is unavailable or blocked.",
                evidence: string(raw["canvasCaptureError"])
            ))
        }

        let customSchemeName = string(raw["customSchemeFetchName"])
        if customSchemeName.isEmpty || customSchemeName == "ok" {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "Custom media request completed",
                detail: "The current custom-scheme media request path returned a response during the probe."
            ))
        } else {
            findings.append(.init(
                severity: .warning,
                blocker: .mediaDelivery,
                title: "Current custom media path failed probe",
                detail: "The existing fslimage/fslvideo fetch path failed in this page context. This is the most likely reason media never reaches strict pages.",
                evidence: [customSchemeName, string(raw["customSchemeFetchMessage"])].filter { !$0.isEmpty }.joined(separator: ": ")
            ))
        }

        if bool(raw["gumLooksNative"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "getUserMedia appears native",
                detail: "Function.toString() does not expose a JavaScript wrapper."
            ))
        } else {
            findings.append(.init(
                severity: .warning,
                blocker: .apiIntegrity,
                title: "getUserMedia wrapper is detectable",
                detail: "A page can inspect Function.toString() and see that getUserMedia is implemented by script rather than native browser code.",
                evidence: string(raw["gumStringSnippet"])
            ))
        }

        if bool(raw["enumerateLooksNative"]) {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: "enumerateDevices appears native",
                detail: "Function.toString() does not expose a JavaScript wrapper."
            ))
        } else {
            findings.append(.init(
                severity: .warning,
                blocker: .apiIntegrity,
                title: "enumerateDevices wrapper is detectable",
                detail: "A page can inspect device enumeration and see that it is script-controlled.",
                evidence: string(raw["enumerateStringSnippet"])
            ))
        }

        if bool(raw["iframeCompareAvailable"]), bool(raw["iframeFunctionMismatch"]) {
            findings.append(.init(
                severity: .warning,
                blocker: .apiIntegrity,
                title: "Cross-frame API mismatch detected",
                detail: "The page can compare camera APIs against another same-origin frame and detect different function shapes.",
                evidence: string(raw["iframeEvidence"])
            ))
        }

        let captureCount = int(raw["captureInputCount"])
        if captureCount > 0 {
            findings.append(.init(
                severity: .info,
                blocker: .nativePicker,
                title: "Native camera picker inputs found",
                detail: "The page contains \(captureCount) file input(s) that can request the native camera picker instead of WebRTC.",
                evidence: string(raw["captureInputSummary"])
            ))
        }

        // Native camera hand-off proof uses an app-owned detached input. It is a
        // safe engine check, not a claim that a third-party site will accept media.
        let handoffError = string(raw["nativeHandoffError"])
        if !handoffError.isEmpty {
            findings.append(.init(
                severity: .blocked,
                blocker: .nativePicker,
                title: "Native hand-off probe failed",
                detail: "The app-owned hand-off check stopped before it could return a result. No delivery recommendation was recorded.",
                evidence: handoffError
            ))
        } else if bool(raw["nativeHandoffAttempted"]) {
            let landed = bool(raw["nativeHandoffLanded"])
            let name = string(raw["nativeHandoffFileName"])
            let size = int(raw["nativeHandoffFileSize"])
            let type = string(raw["nativeHandoffFileType"])
            // Which control answered matters: only the site's own control proves a
            // real hand-off lands where the site will actually read it.
            let control = string(raw["nativeHandoffControl"])
            let controlNote: String
            switch control {
            case "site":
                controlNote = "Tested on this site's own camera control."
            case "app-fixture":
                controlNote = "Tested on a detached app-owned control. This proves only the app's local hand-off path."
            case "app-copy":
                controlNote = "Tested on an app-created control that matches the page's file input. This does not prove external-site acceptance."
            default:
                controlNote = "Tested on an app-created control. This does not prove external-site acceptance."
            }
            if landed {
                findings.append(.init(
                    severity: .pass,
                    blocker: .none,
                    title: "Built-in native hand-off delivered a photo",
                    detail: "The app-owned capture control received the queued photo through WebKit's native FileList path. \(controlNote)",
                    evidence: "control=\(control.isEmpty ? "app" : control), name=\(name), type=\(type), bytes=\(size)"
                ))
            } else {
                let reason = "The photo never arrived in the input through WebKit's native FileList path within the capture window."
                findings.append(.init(
                    severity: .blocked,
                    blocker: .nativePicker,
                    title: "Built-in native hand-off did not deliver",
                    detail: "The app-owned capture control did not receive the queued photo. \(reason) \(controlNote) Retry from Diagnostics after reviewing the failure message.",
                    evidence: "control=\(control.isEmpty ? "app" : control), no native file landed"
                ))
            }
        } else {
            // The test deliberately stood aside; say so instead of staying silent.
            let skipped = string(raw["nativeHandoffSkipped"])
            if !skipped.isEmpty {
                findings.append(.init(
                    severity: .info,
                    blocker: .none,
                    title: "Native camera hand-off test skipped",
                    detail: "The hand-off test did not run because \(skipped). Run it again once that has finished.",
                    evidence: skipped
                ))
            }
        }

        if mediaWasActive {
            findings.append(.init(
                severity: sequenceLength > 0 ? .info : .warning,
                blocker: sequenceLength > 0 ? .none : .mediaDelivery,
                title: "Injection state was active during test",
                detail: sequenceLength > 0 ? "The active sequence had \(sequenceLength) step(s) available." : "Injection was active but the sequence had no servable media steps.",
                evidence: "active=\(mediaWasActive), steps=\(sequenceLength)"
            ))
        }

        if let trackSettings = raw["activeTrackSettings"] as? [String: Any], !trackSettings.isEmpty {
            let width = int(trackSettings["width"])
            let height = int(trackSettings["height"])
            let frameRate = double(trackSettings["frameRate"])
            findings.append(.init(
                severity: width > 0 && height > 0 ? .info : .warning,
                blocker: .streamShape,
                title: "Active virtual stream settings captured",
                detail: "The currently published stream reports \(width)×\(height) at \(String(format: "%.1f", frameRate)) fps.",
                evidence: compactJSONString(trackSettings)
            ))
        }

        return findings.sorted { lhs, rhs in
            if lhs.severity.rank == rhs.severity.rank { return lhs.title < rhs.title }
            return lhs.severity.rank > rhs.severity.rank
        }
    }

    private func analyzeCSP(_ policy: String) -> [InjectionProbeFinding] {
        var findings: [InjectionProbeFinding] = [
            .init(
                severity: .info,
                blocker: .contentSecurityPolicy,
                title: "Security policy detected",
                detail: "The page declares an in-page Content-Security-Policy. The inspector checked it for media-delivery risks.",
                evidence: policy
            )
        ]

        // Parse directives once and evaluate each fetch directive against its OWN
        // token list (falling back to default-src). Scanning the whole policy for
        // "*" let an unrelated permissive directive (e.g. `img-src *`) suppress a
        // genuinely restrictive connect-src/media-src, producing false negatives.
        let tokens = cspDirectiveTokens(policy)
        let defaultSrc = tokens["default-src"]

        if let connect = tokens["connect-src"] ?? defaultSrc,
           !connect.contains("*"), !connect.contains("fslimage:"), !connect.contains("fslvideo:") {
            findings.append(.init(
                severity: .warning,
                blocker: .contentSecurityPolicy,
                title: "Policy may block custom-scheme fetches",
                detail: "The current media pipeline fetches fslimage/fslvideo URLs. The effective connect-src policy does not visibly allow those schemes.",
                evidence: directiveSnippet(named: tokens["connect-src"] != nil ? "connect-src" : "default-src", in: policy)
            ))
        }

        if let img = tokens["img-src"] ?? defaultSrc,
           !img.contains("*"), !img.contains("blob:"), !img.contains("data:") {
            findings.append(.init(
                severity: .warning,
                blocker: .contentSecurityPolicy,
                title: "Policy may block in-page image sources",
                detail: "The effective image policy does not visibly allow blob: or data: image sources.",
                evidence: directiveSnippet(named: tokens["img-src"] != nil ? "img-src" : "default-src", in: policy)
            ))
        }

        if let media = tokens["media-src"] ?? defaultSrc,
           !media.contains("*"), !media.contains("blob:") {
            findings.append(.init(
                severity: .warning,
                blocker: .contentSecurityPolicy,
                title: "Policy may block blob video sources",
                detail: "The video path uses a blob URL after loading bytes. The effective media-src policy does not visibly allow blob: sources.",
                evidence: directiveSnippet(named: tokens["media-src"] != nil ? "media-src" : "default-src", in: policy)
            ))
        }

        return findings
    }

    /// Splits a CSP into a `directive name -> lowercased token list` map.
    private func cspDirectiveTokens(_ policy: String) -> [String: String] {
        var map: [String: String] = [:]
        for segment in policy.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let spaceIndex = trimmed.firstIndex(of: " ") {
                let name = trimmed[..<spaceIndex].lowercased()
                let value = trimmed[trimmed.index(after: spaceIndex)...].lowercased()
                map[name] = value
            } else {
                map[trimmed.lowercased()] = ""
            }
        }
        return map
    }

    private func addDeliveryFinding(
        _ findings: inout [InjectionProbeFinding],
        ok: Bool,
        title: String,
        blockedTitle: String,
        detail: String,
        evidence: String
    ) {
        if ok {
            findings.append(.init(
                severity: .pass,
                blocker: .none,
                title: title,
                detail: detail
            ))
        } else {
            findings.append(.init(
                severity: .warning,
                blocker: .mediaDelivery,
                title: blockedTitle,
                detail: "This page did not accept one of the safe in-page media probes. Strict security policy or image decoding rules may be involved.",
                evidence: evidence
            ))
        }
    }

    private func mostLikelyBlocker(from findings: [InjectionProbeFinding]) -> InjectionBlockerKind {
        let priority: [InjectionBlockerKind] = [
            .contentSecurityPolicy,
            .permissionsPolicy,
            .cameraPermission,
            .mediaDelivery,
            .apiIntegrity,
            .streamShape,
            .nativePicker,
            .unknown
        ]
        for blocker in priority {
            if findings.contains(where: { $0.blocker == blocker && ($0.severity == .blocked || $0.severity == .warning) }) {
                return blocker
            }
        }
        return .none
    }

    private func calculateRiskScore(from findings: [InjectionProbeFinding]) -> Int {
        let score = findings.reduce(0) { partial, finding in
            switch finding.severity {
            case .blocked: return partial + 30
            case .warning: return partial + 12
            case .info: return partial + 2
            case .pass: return partial
            }
        }
        return min(100, score)
    }

    private func verdict(
        for findings: [InjectionProbeFinding],
        likelyBlocker: InjectionBlockerKind,
        riskScore: Int
    ) -> (title: String, detail: String) {
        if findings.contains(where: { $0.severity == .blocked }) {
            return (
                "Likely blocked by \(likelyBlocker.label.lowercased())",
                "The inspector found hard blocking evidence. Open the report details to see the exact browser surface that failed."
            )
        }
        if findings.contains(where: { $0.severity == .warning }) {
            return (
                "Risk detected: \(likelyBlocker.label)",
                "The site may still load, but the current injection path exposes signals or delivery failures that can explain unreliable replacement."
            )
        }
        return (
            "No major blocker detected",
            "The inspected page passed the available policy, delivery, and camera API checks. If replacement still fails, capture a runtime log while triggering the camera request."
        )
    }

    private func addReport(_ report: InjectionInspectionReport) {
        reports.insert(report, at: 0)
        if reports.count > 100 {
            reports = Array(reports.prefix(100))
        }
        saveReports()
    }

    private func loadReports() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            reports = try JSONDecoder().decode([InjectionInspectionReport].self, from: data)
        } catch {
            reports = []
        }
    }

    private func saveReports() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(reports)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Keep diagnostics best-effort only.
        }
    }

    private func normalizedHost(for urlString: String) -> String {
        if let url = URL(string: urlString), let host = url.host?.lowercased() {
            return host
        }
        return urlString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when two hosts are the same site: exact match, or one is a
    /// subdomain of the other. Rejects lookalikes like "evil-example.com"
    /// vs "example.com" that a plain `contains` would wrongly accept.
    static func hostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased()
        let b = rhs.lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    private func directiveSnippet(named directive: String, in policy: String) -> String {
        let parts = policy.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.first { $0.lowercased().hasPrefix(directive) } ?? policy
    }

    private func compactJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value }
        if let value = value { return String(describing: value) }
        return fallback
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "true" }
        return false
    }

    private func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func double(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }
}
