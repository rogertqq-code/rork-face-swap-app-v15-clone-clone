import Foundation

/// Studies a completed site-inspection report and classifies the camera /
/// anti-spoof / anti-bot system most likely in front of you. Pure logic with
/// no stored state — the view model blends the result with learning memory.
nonisolated struct DetectionScannerService: Sendable {

    /// A known third-party vendor marker. Matched against the host, full URL,
    /// and the page's Content-Security-Policy (which frequently lists the
    /// vendor's API domains in connect-src / script-src).
    private struct VendorMarker {
        let tokens: [String]
        let name: String
        let category: DetectedSystemCategory
    }

    private static let vendors: [VendorMarker] = [
        // Identity / liveness vendors
        VendorMarker(tokens: ["onfido"], name: "Onfido", category: .livenessDetection),
        VendorMarker(tokens: ["jumio"], name: "Jumio", category: .livenessDetection),
        VendorMarker(tokens: ["veriff"], name: "Veriff", category: .livenessDetection),
        VendorMarker(tokens: ["iproov"], name: "iProov", category: .livenessDetection),
        VendorMarker(tokens: ["idnow"], name: "IDnow", category: .livenessDetection),
        VendorMarker(tokens: ["sumsub", "sum-sub"], name: "Sumsub", category: .livenessDetection),
        VendorMarker(tokens: ["facetec"], name: "FaceTec", category: .livenessDetection),
        VendorMarker(tokens: ["au10tix"], name: "AU10TIX", category: .livenessDetection),
        VendorMarker(tokens: ["incode"], name: "Incode", category: .livenessDetection),
        VendorMarker(tokens: ["socure"], name: "Socure", category: .livenessDetection),
        VendorMarker(tokens: ["sensity"], name: "Sensity", category: .livenessDetection),
        VendorMarker(tokens: ["regula"], name: "Regula", category: .livenessDetection),
        VendorMarker(tokens: ["mitek", "miteksystems"], name: "Mitek", category: .livenessDetection),
        // Anti-bot / fingerprint / consistency vendors
        VendorMarker(tokens: ["fingerprintjs", "fpjs", "fpcdn.io"], name: "FingerprintJS", category: .consistencyChecker),
        VendorMarker(tokens: ["datadome"], name: "DataDome", category: .consistencyChecker),
        VendorMarker(tokens: ["perimeterx", "px-cdn", "pxchk", "captcha.px"], name: "PerimeterX / HUMAN", category: .consistencyChecker),
        VendorMarker(tokens: ["recaptcha"], name: "Google reCAPTCHA", category: .consistencyChecker),
        VendorMarker(tokens: ["hcaptcha"], name: "hCaptcha", category: .consistencyChecker),
        VendorMarker(tokens: ["arkoselabs", "funcaptcha", "arkose"], name: "Arkose Labs", category: .consistencyChecker),
        VendorMarker(tokens: ["turnstile", "challenges.cloudflare"], name: "Cloudflare Turnstile", category: .consistencyChecker),
        VendorMarker(tokens: ["castle.io"], name: "Castle", category: .consistencyChecker),
        VendorMarker(tokens: ["kasada"], name: "Kasada", category: .consistencyChecker)
    ]

    /// Produce a best-guess detection from a finished inspection report.
    nonisolated func scan(report: InjectionInspectionReport) -> DetectedSystem {
        let haystack = [report.host, report.siteURL, report.cspPolicyText, report.userAgent]
            .joined(separator: " ")
            .lowercased()

        var signals: [String] = []
        let findingSignals = self.findingSignals(report)

        // 1) Authoritative vendor match (host / URL / CSP domains).
        if let vendor = Self.vendors.first(where: { marker in
            marker.tokens.contains { haystack.contains($0) }
        }) {
            signals.append("Recognized marker: \(vendor.name)")
            signals.append(contentsOf: findingSignals)
            // Vendor naming is strong; corroborating findings push confidence higher.
            let corroboration = corroboratesVendor(report, category: vendor.category) ? 20 : 0
            let confidence = min(96, 72 + corroboration)
            return DetectedSystem(
                host: report.host,
                systemName: vendor.name,
                category: vendor.category,
                confidence: confidence,
                signals: signals.isEmpty ? ["Identified from page markers"] : signals,
                recommendedProfile: vendor.category.recommendedProfile,
                baseRecommendation: vendor.category.recommendedProfile
            )
        }

        // 2) Finding-pattern classification.
        let classification = classifyFromFindings(report)
        signals.append(contentsOf: classification.signals)
        if signals.isEmpty { signals = findingSignals }
        if signals.isEmpty { signals = ["No strong detection signals found"] }

        return DetectedSystem(
            host: report.host,
            systemName: classification.name,
            category: classification.category,
            confidence: classification.confidence,
            signals: signals,
            recommendedProfile: classification.category.recommendedProfile,
            baseRecommendation: classification.category.recommendedProfile
        )
    }

    // MARK: - Finding-pattern classification

    private struct Classification {
        let category: DetectedSystemCategory
        let name: String
        let confidence: Int
        let signals: [String]
    }

    private func classifyFromFindings(_ report: InjectionInspectionReport) -> Classification {
        let blocked = report.findings.filter { $0.severity == .blocked }
        let warnings = report.findings.filter { $0.severity == .warning }

        // Permission gate — hardest stop, evaluated first.
        if blocked.contains(where: { $0.blocker == .cameraPermission }) {
            return Classification(
                category: .permissionGate,
                name: "Browser permission gate",
                confidence: 80,
                signals: blocked.filter { $0.blocker == .cameraPermission }.map { $0.title }
            )
        }

        // Strict policy lockdown — CSP / permissions policy.
        let policyHits = report.findings.filter {
            ($0.blocker == .contentSecurityPolicy || $0.blocker == .permissionsPolicy)
                && ($0.severity == .blocked || $0.severity == .warning)
        }
        if report.mostLikelyBlocker == .permissionsPolicy,
           blocked.contains(where: { $0.blocker == .permissionsPolicy }) {
            return Classification(
                category: .cspLockdown,
                name: "Permissions-policy lockdown",
                confidence: 78,
                signals: policyHits.map { $0.title }
            )
        }
        if policyHits.count >= 2 || report.mostLikelyBlocker == .contentSecurityPolicy {
            return Classification(
                category: .cspLockdown,
                name: "Strict content-security policy",
                confidence: policyHits.count >= 3 ? 72 : 58,
                signals: policyHits.map { $0.title }
            )
        }

        // Consistency checker — API-integrity tells.
        let integrityHits = report.findings.filter { $0.blocker == .apiIntegrity && $0.severity == .warning }
        if !integrityHits.isEmpty {
            return Classification(
                category: .consistencyChecker,
                name: "Tamper / consistency checks",
                confidence: integrityHits.count >= 2 ? 66 : 50,
                signals: integrityHits.map { $0.title }
            )
        }

        // Native picker — file inputs that request the camera.
        if report.findings.contains(where: { $0.blocker == .nativePicker }) {
            let liveCamera = report.findings.contains { $0.title.contains("virtual stream") || $0.blocker == .streamShape && $0.severity == .pass }
            if !liveCamera {
                return Classification(
                    category: .nativePicker,
                    name: "Native camera picker",
                    confidence: 55,
                    signals: report.findings.filter { $0.blocker == .nativePicker }.map { $0.title }
                )
            }
        }

        // Deep camera probe — active stream settings captured / rich shape reads.
        let probesStream = report.findings.contains { $0.title.contains("virtual stream settings") }
        let mediaDeliveryWarn = warnings.contains { $0.blocker == .mediaDelivery }
        if probesStream || (report.mediaWasActive && mediaDeliveryWarn) {
            return Classification(
                category: .deepCameraProbe,
                name: "In-depth camera inspection",
                confidence: probesStream ? 60 : 48,
                signals: warnings.filter { $0.blocker == .mediaDelivery || $0.blocker == .streamShape }.map { $0.title }
            )
        }

        // No blockers and the core camera surface passed — ordinary WebRTC.
        let secureOK = report.findings.contains { $0.title.contains("Secure context") && $0.severity == .pass }
        let mediaDevicesOK = report.findings.contains { $0.title.contains("MediaDevices is present") }
        if blocked.isEmpty && warnings.isEmpty && secureOK && mediaDevicesOK {
            return Classification(
                category: .standardWebRTC,
                name: "Standard WebRTC camera",
                confidence: 64,
                signals: ["No policy, delivery, or integrity blockers found"]
            )
        }

        // Fallback.
        return Classification(
            category: .unknown,
            name: "Unidentified system",
            confidence: max(25, 40 - report.warningCount * 3),
            signals: report.findings.prefix(2).map { $0.title }
        )
    }

    // MARK: - Helpers

    private func corroboratesVendor(_ report: InjectionInspectionReport, category: DetectedSystemCategory) -> Bool {
        switch category {
        case .consistencyChecker:
            return report.findings.contains { $0.blocker == .apiIntegrity }
        case .livenessDetection:
            return report.findings.contains { $0.blocker == .streamShape || $0.title.contains("virtual stream") }
                || report.mediaWasActive
        case .cspLockdown:
            return report.findings.contains { $0.blocker == .contentSecurityPolicy || $0.blocker == .permissionsPolicy }
        default:
            return false
        }
    }

    private func findingSignals(_ report: InjectionInspectionReport) -> [String] {
        report.findings
            .filter { $0.severity == .blocked || $0.severity == .warning }
            .prefix(4)
            .map { $0.title }
    }
}
