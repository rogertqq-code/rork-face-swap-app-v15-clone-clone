import Foundation
import UIKit

/// Builds a genuinely complete, top-to-bottom readable report from a full-test
/// run (plus any supporting logs) and writes it to a shareable text file. This
/// replaces the old mostly-empty JSON bundle as the primary Export Log.
@Observable
@MainActor
final class DiagnosticsReportExporter {
    var isExporting: Bool = false
    var lastExportURL: URL?

    func export(
        report: DiagnosticsFullTestReport?,
        profile: DeviceProfile?,
        constraintLogs: [ConstraintLogEntry],
        siteHistory: [SiteHistoryEntry],
        injectionReports: [InjectionInspectionReport]
    ) async -> URL? {
        isExporting = true
        defer { isExporting = false }

        let text = Self.buildText(
            report: report,
            profile: profile,
            constraintLogs: constraintLogs,
            siteHistory: siteHistory,
            injectionReports: injectionReports
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "fsl_diagnostics_\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url)
            lastExportURL = url
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Text builder

    static func buildText(
        report: DiagnosticsFullTestReport?,
        profile: DeviceProfile?,
        constraintLogs: [ConstraintLogEntry],
        siteHistory: [SiteHistoryEntry],
        injectionReports: [InjectionInspectionReport]
    ) -> String {
        var out = ""
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        func line(_ s: String = "") { out += s + "\n" }
        func rule() { line(String(repeating: "=", count: 60)) }

        rule()
        line("FACE SWAP LIVE — DIAGNOSTICS REPORT")
        line("Generated: \(df.string(from: Date()))")
        rule()
        line()

        // ---- Environment ----
        line("ENVIRONMENT")
        line(String(repeating: "-", count: 60))
        if let env = report?.environment {
            line("Browser identity : \(env.userAgent.isEmpty ? "unknown" : env.userAgent)")
            line("iOS version      : \(env.iosVersion.isEmpty ? "unknown" : env.iosVersion)")
            line("Secure context   : \(env.secureContext ? "yes (trusted)" : "NO")")
            line("Camera APIs      : \(env.hasMediaDevices ? "present" : "MISSING")")
            line("Worker / WebCodecs: Worker \(yn(env.hasWorker)), VideoFrame \(yn(env.hasVideoFrame)), VideoTrackGenerator \(yn(env.hasVideoTrackGenerator))")
            line("Device profile   : \(env.deviceProfileName) (\(env.profileResolution))")
        } else {
            line("No full test has been run yet.")
            line("Device profile   : \(profile?.name ?? "None")")
        }
        line()

        // ---- Summary ----
        if let report {
            line("SUMMARY")
            line(String(repeating: "-", count: 60))
            line(report.summaryLine)
            line("Recommended method for a clean phone: \(report.recommendedMethodLabel)")
            line()
            line("Method results (overall):")
            for r in report.results {
                line("  • \(pad(r.methodLabel + " / " + r.mediaLabel, 34)) \(r.overall.label.uppercased())")
            }
            line("  • \(pad("Passthrough (real camera)", 34)) \(report.passthrough.status.label.uppercased())")
            line("  • \(pad("Block step (refuses feed)", 34)) \(report.block.status.label.uppercased())")
            line("  • \(pad("Native AVFoundation → WebRTC", 34)) \(report.nativeWebRTC.status.label.uppercased())")
            line()

            // ---- Detail per combination ----
            line("DETAILED RESULTS")
            line(String(repeating: "-", count: 60))
            for r in report.results {
                line("[\(r.methodLabel) · \(r.mediaLabel)] — \(r.overall.label.uppercased())")
                line("   Takeover armed     : \(yn(r.armed))\(r.armError.isEmpty ? "" : " (\(r.armError))")")
                line("   getUserMedia        : \(r.gumSucceeded ? "served" : "failed")\(r.gumError.isEmpty ? "" : " — \(r.gumError)")")
                line("   Site received       : \(r.resolutionLabel) @ \(fmt(r.claimedFps)) fps claimed")
                line("   Delivery engine     : \(r.feedLabel)")
                if r.downgraded && r.reason != "photo-step" {
                    line("   Downgrade reason    : \(InjectionFeed.reasonText(r.reason))")
                }
                line("   Sensor realism      : \(r.sensorRealismLog)")
                line("   Frames flowing      : \(yn(r.framesFlowing)) (\(r.frameCount) sampled, ~\(fmt(r.measuredFps)) fps measured)")
                line("   File-picker returned: \(r.pickerReturnedMedia ? "media (\(r.pickerFileType), \(bytes(r.pickerFileSize)))" : "nothing")")
                line("   Camera capture      : \(r.captureReturnedMedia ? "media (\(r.captureFileType), \(bytes(r.captureFileSize)))" : "nothing")")
                line("   Detector score      : \(r.detectorScore)%")
                for c in r.detectorChecks {
                    line("      - [\(c.status.label)] \(c.title)\(c.detail.isEmpty ? "" : " — \(c.detail)")")
                }
                if !r.notes.isEmpty { line("   Note                : \(r.notes)") }
                line()
            }

            line("NATIVE AVFOUNDATION → WEBRTC")
            line(String(repeating: "-", count: 60))
            line("Status             : \(report.nativeWebRTC.status.label.uppercased())")
            line("Request ID         : \(report.nativeWebRTC.requestID.isEmpty ? "—" : report.nativeWebRTC.requestID)")
            line("Video rendered     : \(yn(report.nativeWebRTC.receivedVideo)) (\(report.nativeWebRTC.videoTrackCount) track(s))")
            line("Audio               : \(report.nativeWebRTC.audioOutcome.isEmpty ? "—" : report.nativeWebRTC.audioOutcome) (\(report.nativeWebRTC.audioTrackCount) track(s))")
            line("Raw sample mode     : \(report.nativeWebRTC.rawSampleMode.isEmpty ? "—" : report.nativeWebRTC.rawSampleMode)")
            line("Lifecycle stopped   : \(yn(report.nativeWebRTC.lifecycleStopped))")
            if !report.nativeWebRTC.error.isEmpty { line("Error               : \(report.nativeWebRTC.error)") }
            line()

            // ---- Passthrough + block ----
            line("PASSTHROUGH")
            line(String(repeating: "-", count: 60))
            line("Status: \(report.passthrough.status.label.uppercased())")
            line("Virtual feed engaged: \(yn(report.passthrough.virtualFeedEngaged))")
            line(report.passthrough.note)
            line()
            line("BLOCK STEP")
            line(String(repeating: "-", count: 60))
            line("Status: \(report.block.status.label.uppercased())")
            line("Refused the request: \(yn(report.block.refused))")
            line(report.block.note)
            line()
        }

        // ---- Supporting logs ----
        line("CONSTRAINT LOG (recent)")
        line(String(repeating: "-", count: 60))
        if constraintLogs.isEmpty {
            line("No constraint entries logged.")
        } else {
            for e in constraintLogs.prefix(20) {
                line("\(df.string(from: e.timestamp)) — \(e.siteURL)")
                line("   requested: \(e.requestedConstraints)")
                line("   result   : \(e.negotiatedResult) [\(e.wasSuccessful ? "ok" : "failed")]")
            }
        }
        line()

        line("SITE HISTORY (recent)")
        line(String(repeating: "-", count: 60))
        if siteHistory.isEmpty {
            line("No site history recorded.")
        } else {
            for e in siteHistory.prefix(20) {
                line("\(df.string(from: e.timestamp)) — \(e.siteURL) [\(e.wasSuccessful ? "ok" : "failed")] profile: \(e.profileUsed)")
            }
        }
        line()

        line("SITE INSPECTION REPORTS (recent)")
        line(String(repeating: "-", count: 60))
        if injectionReports.isEmpty {
            line("No inspection reports.")
        } else {
            for r in injectionReports.prefix(10) {
                line("\(r.host) — risk \(r.riskScore)% — likely blocker: \(r.mostLikelyBlocker.label)")
            }
        }
        line()

        // ---- Device profile ----
        line("DEVICE PROFILE")
        line(String(repeating: "-", count: 60))
        if let profile {
            line("Name: \(profile.name)")
            if let f = profile.frontCamera { line("Front camera: \(f.activeWidth)×\(f.activeHeight) @ \(Int(f.activeFrameRate)) fps") }
            if let b = profile.backCamera { line("Back camera : \(b.activeWidth)×\(b.activeHeight) @ \(Int(b.activeFrameRate)) fps") }
        } else {
            line("No device profile is set.")
        }
        line()
        rule()
        line("End of report.")
        rule()

        return out
    }

    // MARK: - Formatting helpers

    private static func yn(_ b: Bool) -> String { b ? "yes" : "no" }
    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    private static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(n / 1000) KB" }
        return "\(n) B"
    }
}
