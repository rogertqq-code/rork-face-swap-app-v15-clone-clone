import SwiftUI
import UIKit

/// The single unified "Site Check" screen. Merges what used to be Analyze Site
/// and Live Diagnostics — they answered overlapping questions from two places.
/// One screen now covers: is the takeover live on this page, what did the site
/// ask for and receive, which route delivered it, what is likely to refuse the
/// media, and what to do about it.
struct AnalyzeSiteView: View {
    @Bindable var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reportToShow: InjectionInspectionReport?
    @State private var recorder = InjectionTraceRecorder.shared
    @State private var didCopyLog = false

    private var host: String { viewModel.currentURL?.host() ?? "" }

    private var report: InjectionInspectionReport? {
        viewModel.injectionInspector.latestReport(for: host) ?? viewModel.injectionInspector.reports.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.groupSpacing) {
                    statusBanner
                    liveEngineCard
                    detectionCard
                    reportCard
                    requestPatternCard
                    failureRecorderCard
                    guideLink
                    DSVersionBadge().padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Site Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.refreshSiteAnalysis()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.currentURL == nil || viewModel.isAnalyzingSite)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $reportToShow) { report in
            InjectionInspectionReportDetailView(report: report)
        }
    }

    // MARK: - Status

    private var statusBanner: some View {
        DSCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DS.accent.opacity(0.15))
                        .frame(width: 40, height: 40)
                    if viewModel.isAnalyzingSite {
                        ProgressView().controlSize(.small).tint(DS.accent)
                    } else {
                        Image(systemName: "scope")
                            .font(.headline)
                            .foregroundStyle(DS.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.isAnalyzingSite ? "Analyzing\u{2026}" : "Site analysis")
                        .font(.subheadline.weight(.semibold))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusDetail: String {
        if viewModel.isInspectingCurrentSite { return viewModel.inspectionStatus.isEmpty ? "Testing this site\u{2026}" : viewModel.inspectionStatus }
        if viewModel.isProbingCurrentSite { return viewModel.probeStatus.isEmpty ? "Learning request pattern\u{2026}" : viewModel.probeStatus }
        if host.isEmpty { return "Open a site to analyze it." }
        return host
    }

    // MARK: - Live engine state

    /// What is happening on this page RIGHT NOW. This is the half that used to
    /// live in a separate Live Diagnostics sheet.
    private var liveEngineCard: some View {
        DSCard {
            DSSectionHeader("On This Page Now", icon: "bolt.horizontal.fill")

            liveStateRow(
                title: "Camera takeover",
                value: viewModel.engineArmed ? "Active" : "Not active",
                detail: viewModel.engineArmed
                    ? "This page's camera requests reach the app."
                    : "This page would reach the real camera. Reload to re-arm.",
                tint: viewModel.engineArmed ? DS.good : DS.blocked,
                icon: viewModel.engineArmed ? "checkmark.shield.fill" : "xmark.shield.fill"
            )

            liveStateRow(
                title: "Serving media",
                value: viewModel.isMediaActive ? "On" : "Off",
                detail: viewModel.isMediaActive
                    ? "Requests are answered from your media list."
                    : "Turn on Serve Media in the toolbar to answer requests.",
                tint: viewModel.isMediaActive ? DS.good : .secondary,
                icon: viewModel.isMediaActive ? "web.camera.fill" : "web.camera"
            )

            liveStateRow(
                title: "Delivery route",
                value: viewModel.activeMethodDisplayName,
                detail: routeDetail,
                tint: viewModel.liveFeedDidDowngrade ? DS.caution : DS.accent,
                icon: "arrow.triangle.branch"
            )

            if !viewModel.lastAction.isEmpty {
                liveStateRow(
                    title: "Last request",
                    value: lastActionText,
                    detail: "",
                    tint: .secondary,
                    icon: "clock.arrow.circlepath"
                )
            }
        }
    }

    private var routeDetail: String {
        if !viewModel.liveFeedEngaged {
            return "No feed has been delivered on this page yet."
        }
        if viewModel.liveFeedDidDowngrade {
            return "Fell back to a simpler route — \(viewModel.liveFeedReasonText)"
        }
        if viewModel.liveFeedIsPrivateLane {
            return "Delivered through the private lane."
        }
        if viewModel.liveFeedIntentionalCanvas {
            return "A still photo is drawn as live footage by design."
        }
        if viewModel.liveFeedIsClean {
            return "Delivered through the clean background track."
        }
        return "Delivered through the canvas feed."
    }

    private var lastActionText: String {
        switch viewModel.lastAction {
        case "serve": "Media served"
        case "blockWebRTC", "refuse": "Live camera blocked"
        case "blockNative": "Phone camera blocked"
        case "hardBlock": "Blocked (real camera withheld)"
        case "deny": "Skipped (not this side's turn)"
        case "nativePicker": "Picker opened (nothing to serve)"
        case "nativePickerRetry", "nativePickerFail": "Hand-off needs another tap"
        case "realCamera", "real": "Real camera requested"
        default: viewModel.lastAction
        }
    }

    private func liveStateRow(
        title: String,
        value: String,
        detail: String,
        tint: Color,
        icon: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.trailing)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(tint.opacity(0.07), in: .rect(cornerRadius: 10))
    }

    // MARK: - Failure recorder

    /// Opt-in, off by default. When on it names the exact stage a request died
    /// at, so an injection regression is pinpointed instead of guessed at.
    private var failureRecorderCard: some View {
        DSCard {
            DSSectionHeader("Record Injection Failures", icon: "waveform.path.ecg")

            Toggle(isOn: Binding(
                get: { recorder.isEnabled },
                set: { newValue in
                    recorder.isEnabled = newValue
                    // Apply to the page now, so the next request is recorded
                    // without needing a reload.
                    viewModel.syncFailureRecorderState()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.isEnabled ? "Recording" : "Off")
                        .font(.caption.weight(.semibold))
                    Text("Records which stage a camera request failed at. Off by default; no media is ever stored.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(DS.accent)

            if recorder.isEnabled {
                if recorder.records.isEmpty {
                    Text("No failures recorded yet. Reproduce the problem and the failing stage will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(recorder.stageTally.prefix(3), id: \.stage) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.stage.iconName)
                                .font(.caption)
                                .foregroundStyle(DS.caution)
                                .frame(width: 18)
                            Text(entry.stage.title)
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                            Text("\(entry.count)×")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(DS.caution)
                        }
                        .padding(8)
                        .background(DS.caution.opacity(0.08), in: .rect(cornerRadius: 8))
                    }

                    if let latest = recorder.latest {
                        Text(latest.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = recorder.exportText
                            didCopyLog = true
                            Haptics.success()
                        } label: {
                            Label(didCopyLog ? "Copied" : "Copy Log", systemImage: didCopyLog ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(DS.accent)

                        Button(role: .destructive) {
                            recorder.clear()
                            didCopyLog = false
                        } label: {
                            Label("Clear", systemImage: "trash")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Detection

    @ViewBuilder
    private var detectionCard: some View {
        DSCard {
            DSSectionHeader("Detected System", icon: "dot.radiowaves.left.and.right")
            if let detected = viewModel.latestDetectedSystem {
                detectionBody(detected)
            } else if viewModel.isAnalyzingSite {
                DSEmptyState(icon: "scope", title: "Scanning\u{2026}", message: "Identifying the camera or anti-spoof system on this site.")
            } else {
                DSEmptyState(icon: "scope", title: "Not analyzed yet", message: "Tap Analyze to identify the camera or anti-spoof system and get a recommended method.")
            }
        }
    }

    @ViewBuilder
    private func detectionBody(_ detected: DetectedSystem) -> some View {
        let tint = Color(themeName: detected.category.tintName)
        let bandColor = Color(themeName: detected.confidenceBand.tintName)

        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(tint.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: detected.category.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(detected.systemName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(detected.category.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("\(detected.confidence)%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(bandColor)
                Text(detected.confidenceBand.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(bandColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(bandColor.opacity(0.12), in: .rect(cornerRadius: 8))
        }

        if !detected.signals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(detected.signals.prefix(4).enumerated()), id: \.offset) { _, signal in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        Text(signal)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        recommendationRow(detected)

        DSActionButton(
            title: viewModel.activeInjectionProfile == detected.recommendedProfile ? "Applied \u{2014} remember for this site" : "Use \(detected.recommendedProfile.label)",
            icon: viewModel.activeInjectionProfile == detected.recommendedProfile ? "checkmark.circle.fill" : "wand.and.stars",
            role: .primary,
            tint: Color(themeName: detected.recommendedProfile.tintName)
        ) {
            Haptics.success()
            viewModel.confirmRecommendedProfile()
        }

        Divider()
        SiteOutcomeControl(viewModel: viewModel)
    }

    private func recommendationRow(_ detected: DetectedSystem) -> some View {
        let tint = Color(themeName: detected.recommendedProfile.tintName)
        return HStack(spacing: 10) {
            Image(systemName: detected.recommendedProfile.icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recommended: \(detected.recommendedProfile.label)")
                    .font(.caption.weight(.semibold))
                Text(detected.memoryInformed ? "Adjusted from your history for this kind of site." : detected.recommendedProfile.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    // MARK: - Injection & security report

    @ViewBuilder
    private var reportCard: some View {
        DSCard {
            DSSectionHeader("Injection & Security Report", icon: "shield.lefthalf.filled")
            if let report {
                Button {
                    reportToShow = report
                } label: {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: reportIcon(report))
                                .foregroundStyle(reportColor(report))
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(report.verdictTitle)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("Likely blocker: \(report.mostLikelyBlocker.label)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(report.riskScore)%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(reportColor(report))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 8) {
                            metricChip("Blocked", report.blockedCount, color: DS.blocked)
                            metricChip("Warnings", report.warningCount, color: DS.caution)
                            metricChip("Findings", report.findings.count, color: DS.accent)
                        }
                    }
                    .padding(10)
                    .background(reportColor(report).opacity(0.08), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.dsPress)
            } else if viewModel.isAnalyzingSite {
                DSEmptyState(icon: "shield.lefthalf.filled", title: "Inspecting\u{2026}", message: "Checking how this site loads and guards camera media.")
            } else {
                DSEmptyState(icon: "shield.lefthalf.filled", title: "No report yet", message: "Analyze the site to see its injection and security report.")
            }
        }
    }

    private func metricChip(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private func reportIcon(_ report: InjectionInspectionReport) -> String {
        if report.hasBlockingEvidence { return "xmark.shield.fill" }
        if report.warningCount > 0 { return "exclamationmark.shield.fill" }
        return "checkmark.shield.fill"
    }

    private func reportColor(_ report: InjectionInspectionReport) -> Color {
        if report.hasBlockingEvidence { return DS.blocked }
        if report.warningCount > 0 { return DS.caution }
        return DS.good
    }

    // MARK: - Request pattern

    private var requestPatternCard: some View {
        DSCard {
            DSSectionHeader("Front / Back Request Pattern", icon: "antenna.radiowaves.left.and.right")
            CameraRequestInsightCard(insight: viewModel.latestCameraRequestInsight)
        }
    }

    // MARK: - Guide

    private var guideLink: some View {
        NavigationLink {
            DetectionGuideView()
        } label: {
            DSCard {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.title3)
                        .foregroundStyle(DS.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detection Guide")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("What each detection type means and which method to use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
