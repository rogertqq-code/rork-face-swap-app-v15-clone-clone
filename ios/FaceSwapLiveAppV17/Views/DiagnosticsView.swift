import SwiftUI
import AVFoundation
import UIKit
import WebKit

struct DiagnosticsView: View {
    @Environment(DeviceProfileManager.self) private var profileManager
    @Environment(OfflineVerificationStore.self) private var verificationStore
    @State private var diagnosticsService = DiagnosticsService()
    @State private var fingerprintService = FingerprintService()
    @State private var constraintLog = ConstraintLogService()
    @State private var siteHistory = SiteHistoryService()
    @State private var injectionInspector = InjectionInspectionService()
    @State private var selfTestService = DetectorSelfTestService()
    @State private var privateLaneProbe = PrivateLaneProbeService()
    @State private var siteMemory = SiteProfileMemoryService()
    @State private var harness = DiagnosticsTestHarness()
    @State private var fixService = DiagnosticsFixService()
    @State private var reportExporter = DiagnosticsReportExporter()
    @State private var mediaReport: MediaMetadataReport?
    @State private var conformanceScore: MediaConformanceScore?
    @State private var showFilePicker = false
    @State private var selectedMediaURL: URL?
    @State private var showShareSheet = false
    @State private var baselineSaveConfirmation: String?
    @State private var verificationProfile: DeviceProfile?
    @State private var showConnectionLogSheet = false
    @State private var showConnectionLogShareSheet = false
    @State private var connectionLogExportURL: URL?

    @State private var expandedSections: Set<String> = []
    @State private var advancedExpanded = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(spacing: 14) {
                        offlineVerificationCard
                        fullTestLeadCard
                        fixButtonsRow
                        if let result = fixService.injectionResult {
                            fixResultCard("Fix Injection", result: result) { fixService.clearInjectionResult() }
                        }
                        if let result = fixService.trustedResult {
                            fixResultCard("Fix Trusted-Browser", result: result) { fixService.clearTrustedResult() }
                        }
                        exportLogCard
                        connectionLogCard
                        sensorRealismCard
                        advancedDisclosure

                        DSVersionBadge()
                            .padding(.top, 4)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 40)
                }

                // The hidden built-in camera test page. Kept mounted and rendered
                // (not hidden) while Diagnostics is open so the media pipelines
                // actually run during the full test; near-transparent and
                // non-interactive so it never disturbs the screen.
                DiagnosticsHarnessWebView(harness: harness)
                    .frame(width: 64, height: 48)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .padding(.top, 2)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Diagnostics")
            .onAppear {
                siteMemory.reload()
                privateLaneProbe.loadCachedForCurrentSite()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            if let url = reportExporter.lastExportURL {
                ActivityShareSheet(activityItems: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showConnectionLogSheet) {
            ConnectionLogSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showConnectionLogShareSheet) {
            if let url = connectionLogExportURL {
                ActivityShareSheet(activityItems: [url])
                    .presentationDetents([.medium])
            }
        }
        .sheet(item: $verificationProfile) { profile in
            OfflineVerificationFlowView(profile: profile) { report in
                verificationStore.append(report)
                verificationProfile = nil
            }
        }
    }

    // MARK: - Offline verification and mounted fixture

    private var offlineVerificationCard: some View {
        DSCard {
            DSSectionHeader("Offline Device Verification", icon: "checkmark.shield.fill")
            if let profile = profileManager.activeProfile {
                let status = verificationStore.status(for: profile)
                HStack(spacing: 10) {
                    Image(systemName: status.iconName)
                        .foregroundStyle(verificationTint(status.tintName))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title)
                            .font(.subheadline.weight(.semibold))
                        Text("Runs local, privacy-conscious checks. External browser and third-party-site behavior remain separately unverified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button {
                        verificationProfile = profile
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)

                    NavigationLink {
                        OfflineVerificationReportView(profile: profile, store: verificationStore)
                    } label: {
                        Label("View Report", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Create a device profile before running offline verification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fullTestLeadCard: some View {
        DSCard {
            DSSectionHeader("Mounted Fixture Test", icon: "checkmark.seal.fill")
            Text("Runs each delivery method against an app-owned, mounted offline camera page with a real local image payload. It records only what this fixture observes and does not claim external-site compatibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if harness.isRunning {
                ProgressView(value: harness.progress)
                    .tint(DS.accent)
                Text(harness.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DSActionButton(
                    title: harness.latestReport == nil ? "Run Full Test" : "Run Full Test Again",
                    icon: "play.fill",
                    role: .primary
                ) {
                    Task { await harness.runFullTest(profileManager: profileManager, verificationStore: verificationStore) }
                }
            }

            if !harness.lastError.isEmpty {
                Text(harness.lastError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = harness.latestReport {
                fullTestSummary(report)
            }
        }
    }

    private func fullTestSummary(_ report: DiagnosticsFullTestReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                statPill("\(report.passCount)", "Passed", .green)
                statPill("\(report.warnCount)", "Downgraded", .orange)
                statPill("\(report.failCount)", "Failed", .red)
            }
            if !report.recommendedMethodRaw.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    Text("Fixture-backed method: \(report.recommendedMethodLabel)")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
            }
            if !report.environment.secureContext {
                Text("Note: the test page was not a secure context on this device, so live-camera results are limited.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NavigationLink {
                DiagnosticsFullTestReportView(report: report)
            } label: {
                HStack {
                    Text("View full breakdown")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.accent)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text("Last run \(report.timestamp, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func verificationTint(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }

    private func statPill(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    // MARK: - Fix buttons

    private var fixButtonsRow: some View {
        HStack(spacing: 10) {
            DSActionButton(
                title: fixService.isFixingInjection ? "Fixing…" : "Fix Injection",
                icon: "bandage.fill",
                role: .secondary,
                tint: DS.good,
                isLoading: fixService.isFixingInjection
            ) {
                Task { await fixService.fixInjection() }
            }
            DSActionButton(
                title: fixService.isFixingTrusted ? "Checking…" : "Fix Trusted-Browser",
                icon: "checkmark.shield.fill",
                role: .secondary,
                tint: DS.accent,
                isLoading: fixService.isFixingTrusted
            ) {
                Task { await fixService.fixTrustedBrowser(profile: profileManager.activeProfile) }
            }
        }
    }

    private func fixResultCard(_ title: String, result: DiagFixResult, onDismiss: @escaping () -> Void) -> some View {
        let tint: Color = result.ok ? DS.good : DS.caution
        return DSCard {
            HStack(spacing: 8) {
                Image(systemName: result.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(result.headline).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(tint.opacity(0.6)).padding(.top, 5)
                    Text(entry).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Export log (lead)

    private var exportLogCard: some View {
        DSActionButton(
            title: reportExporter.isExporting ? "Building…" : "Export Log",
            icon: "square.and.arrow.up",
            role: .primary,
            tint: DS.accent,
            isLoading: reportExporter.isExporting
        ) {
            Task {
                let url = await reportExporter.export(
                    report: harness.latestReport,
                    profile: profileManager.activeProfile,
                    constraintLogs: constraintLog.entries,
                    siteHistory: siteHistory.entries,
                    injectionReports: injectionInspector.reports
                )
                if url != nil { showShareSheet = true }
            }
        }
    }

    // MARK: - Connection log viewer/export

    private var connectionLogCard: some View {
        DSCard {
            DSSectionHeader("Connection Log", icon: "doc.text.magnifyingglass")
            Text("Records initialization steps and errors from the camera-injection pipeline so connection issues can be diagnosed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let log = ConnectionLogService.shared
            HStack(spacing: 8) {
                statPill("\(log.entries.count)", "Entries", DS.accent)
                statPill("\(log.entries(for: .error).count)", "Errors", DS.blocked)
                statPill("\(log.entries(for: .lifecycle).count)", "Events", DS.good)
            }

            if let lastError = log.latestError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Error")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(lastError.formattedLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.blocked)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Button {
                    showConnectionLogSheet = true
                } label: {
                    Label("View Log", systemImage: "list.bullet.rectangle")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(DS.accent)

                Button {
                    if let url = ConnectionLogService.shared.exportToFile() {
                        connectionLogExportURL = url
                        showConnectionLogShareSheet = true
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(DS.good)

                Button(role: .destructive) {
                    ConnectionLogService.shared.clear()
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

    // MARK: - Sensor realism toggle (Round 2)

    /// One-tap safety switch for the sensor-realism layer (capture-clock timing +
    /// grain on the clean feed). On by default, remembered, and pushed straight
    /// into the live page so it takes effect on the next frame with no reload.
    private var sensorRealismCard: some View {
        @Bindable var store = SensorRealismStore.shared
        return DSCard {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(store.isEnabled ? DS.good : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sensor Realism")
                        .font(.subheadline.weight(.semibold))
                    Text(store.isEnabled
                         ? "Clean feed gets real capture-clock timing and living sensor grain."
                         : "Off \u{2014} the clean feed serves plain decoded frames.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $store.isEnabled)
                    .labelsHidden()
                    .tint(DS.good)
            }
        }
    }

    // MARK: - Advanced (collapsed)

    private var advancedDisclosure: some View {
        DSDisclosureCard(title: "Advanced Tools", icon: "wrench.and.screwdriver.fill", isExpanded: $advancedExpanded) {
            VStack(spacing: 12) {
                cameraComparisonSection
                audioRouteSection
                driftMonitorSection
                fingerprintSection
                metadataInspectorSection
                injectionInspectorSection
                detectorSelfTestSection
                privateLaneSection
                networkRewriteSection
                adaptiveInjectionSection
                constraintLogSection
                siteHistorySection
            }
        }
    }

    // MARK: - Camera Comparison

    private var cameraComparisonSection: some View {
        sectionCard("Camera Comparison", icon: "camera.on.rectangle", sectionID: "camera") {
            if let profile = profileManager.activeProfile,
               let front = profile.frontCamera,
               let back = profile.backCamera {
                VStack(spacing: 0) {
                    comparisonHeader
                    Divider().padding(.vertical, 6)
                    comparisonRow("Resolution", "\(front.activeWidth)×\(front.activeHeight)", "\(back.activeWidth)×\(back.activeHeight)")
                    comparisonRow("Frame Rate", "\(Int(front.activeFrameRate)) fps", "\(Int(back.activeFrameRate)) fps")
                    comparisonRow("Codec", front.testClipCodec ?? "—", back.testClipCodec ?? "—")
                    comparisonRow("Bitrate", formatBitrate(front.testClipBitrate), formatBitrate(back.testClipBitrate))
                    comparisonRow("Color Space", front.activeColorSpace ?? "—", back.activeColorSpace ?? "—")
                    if let frontFOV = front.supportedFormats.first?.videoFieldOfView,
                       let backFOV = back.supportedFormats.first?.videoFieldOfView {
                        comparisonRow("FOV", String(format: "%.0f°", frontFOV), String(format: "%.0f°", backFOV))
                    }
                }
            } else {
                Text("Requires a profile with front and back cameras.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
    }

    private var comparisonHeader: some View {
        HStack {
            Text("")
                .frame(width: 80, alignment: .leading)
            Spacer()
            Text("Front")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
            Spacer()
            Text("Back")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
    }

    private func comparisonRow(_ label: String, _ frontVal: String, _ backVal: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            Text(frontVal)
                .font(.caption)
                .foregroundStyle(.cyan)
                .frame(maxWidth: .infinity)
            Spacer()
            Text(backVal)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Fingerprint Consistency

    private var fingerprintSection: some View {
        sectionCard("Fingerprint Consistency", icon: "fingerprint", sectionID: "fingerprint") {
            VStack(spacing: 10) {
                // Suspect Score Badge — local heuristic evaluation
                if fingerprintService.baseline != nil {
                    let badge = fingerprintService.suspectScoreBadge
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suspect Score")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(fingerprintService.suspectScoreText)
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(badgeColor(badge.color))
                        }
                        Spacer()
                        Text(badge.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(badgeColor(badge.color), in: .capsule)
                    }
                    .padding(10)
                    .background(badgeColor(badge.color).opacity(0.08), in: .rect(cornerRadius: 10))
                }

                if let passed = fingerprintService.testPassed {
                    HStack(spacing: 8) {
                        Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(passed ? .green : .red)
                        Text(passed ? "All Consistent" : "Inconsistencies Found")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(passed ? .green : .red)
                        Spacer()
                    }
                    .padding(10)
                    .background((passed ? Color.green : Color.red).opacity(0.1), in: .rect(cornerRadius: 8))
                }

                if !fingerprintService.consistencyResults.isEmpty {
                    ForEach(fingerprintService.consistencyResults) { result in
                        HStack(spacing: 8) {
                            Image(systemName: result.isConsistent ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.isConsistent ? .green : .red)
                                .font(.caption)
                            Text(result.field)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(result.values.prefix(3).joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if let confirmation = baselineSaveConfirmation {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(confirmation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.green.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            if let spec = await fingerprintService.captureBaseline() {
                                saveBaselineToActiveProfile(spec)
                            } else {
                                baselineSaveConfirmation = "Capture failed — the fingerprint reading could not be completed. Try again."
                            }
                        }
                    } label: {
                        Label(fingerprintService.isCapturing ? "Capturing…" : "Capture Baseline", systemImage: "camera.viewfinder")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                    .disabled(fingerprintService.isCapturing)

                    NavigationLink {
                        FingerprintConsistencyView(service: fingerprintService)
                    } label: {
                        Label("Run Test", systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func saveBaselineToActiveProfile(_ spec: FingerprintBaselineSpec) {
        guard var profile = profileManager.activeProfile else {
            baselineSaveConfirmation = "Baseline captured — add a device profile to store it for live injection."
            return
        }
        profile.fingerprintBaseline = spec
        profileManager.updateProfile(profile)
        baselineSaveConfirmation = "Saved to \(profile.name). Live camera injection now uses this exact fingerprint."
    }

    private func badgeColor(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        case "cyan": return .cyan
        case "teal": return .teal
        default: return .gray
        }
    }

    // MARK: - Metadata Inspector

    private var metadataInspectorSection: some View {
        sectionCard("Metadata Inspector", icon: "doc.text.magnifyingglass", sectionID: "metadata") {
            VStack(spacing: 10) {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Select Media File", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.purple.opacity(0.15), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.purple)
                }

                if let report = mediaReport {
                    VStack(spacing: 6) {
                        diagRow("Container", report.container)
                        diagRow("Video Codec", report.videoCodec)
                        diagRow("Resolution", "\(report.videoWidth)×\(report.videoHeight)")
                        diagRow("Bitrate", formatBitrate(report.videoBitrate))
                        diagRow("Frame Rate", String(format: "%.1f fps", report.videoFrameRate))
                        diagRow("Pixel Format", report.pixelFormat)
                        diagRow("Rotation", "\(report.rotationDegrees)°")
                        diagRow("HDR", report.isHDR ? "Yes" : "No")
                        diagRow("Color", "\(report.colorPrimaries) / \(report.transferFunction)")

                        if report.hasAudio {
                            Divider().padding(.vertical, 2)
                            diagRow("Audio Codec", report.audioCodec)
                            diagRow("Audio Bitrate", formatBitrate(report.audioBitrate))
                            diagRow("Sample Rate", "\(Int(report.audioSampleRate)) Hz")
                            diagRow("Channels", "\(report.audioChannels)")
                        }
                    }

                    if let score = conformanceScore {
                        VStack(spacing: 6) {
                            Divider().padding(.vertical, 2)
                            HStack {
                                Text("Conformance")
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text(String(format: "%.0f%%", score.overallScore))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(score.overallScore >= 80 ? .green : score.overallScore >= 50 ? .yellow : .red)
                            }
                            conformanceField("Resolution", score.resolutionMatch)
                            conformanceField("FPS", score.fpsMatch)
                            conformanceField("Codec", score.codecMatch)
                            conformanceField("Bitrate", score.bitrateMatch)
                            conformanceField("Orientation", score.orientationMatch)
                            conformanceField("Audio", score.audioMatch)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.movie, .video, .quickTimeMovie]) { result in
                if case .success(let url) = result {
                    Task { @MainActor in
                        selectedMediaURL = url
                    }
                    Task {
                        // Files from the system picker live outside the sandbox
                        // and need security-scoped access held open for the whole
                        // read, or inspection intermittently fails.
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let report = await DiagnosticsService.inspectMediaFile(at: url)
                        Task { @MainActor in
                            mediaReport = report
                            if let report = mediaReport,
                               let camera = profileManager.activeProfile?.frontCamera {
                                conformanceScore = DiagnosticsService.scoreConformance(media: report, camera: camera)
                            }
                        }
                    }
                }
            }
        }
    }

    private func conformanceField(_ label: String, _ passed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Audio Route

    private var audioRouteSection: some View {
        sectionCard("Audio Route", icon: "speaker.wave.2.fill", sectionID: "audio") {
            VStack(spacing: 10) {
                if let route = diagnosticsService.audioRouteProfile {
                    diagRow("Input", route.inputRoute)
                    diagRow("Sample Rate", "\(Int(route.sampleRate)) Hz")
                    diagRow("Channels", "\(route.channelCount)")
                    diagRow("Bit Depth", "\(route.bitDepth)")
                    diagRow("Echo Cancel", route.echoCancellation ? "On" : "Off")
                    diagRow("Mode", route.audioSessionMode)
                    diagRow("Buffer", String(format: "%.3f s", route.ioBufferDuration))
                }

                Button {
                    diagnosticsService.captureAudioRouteProfile()
                } label: {
                    Label("Capture Audio Route", systemImage: "mic.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.cyan.opacity(0.15), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    // MARK: - Drift Monitor

    private var driftMonitorSection: some View {
        sectionCard("Drift Monitor", icon: "chart.xyaxis.line", sectionID: "drift") {
            VStack(spacing: 10) {
                if let fe = diagnosticsService.feedEngine, fe.active {
                    feedEngineRow(fe)
                }
                if let report = diagnosticsService.driftReport {
                    diagRow("Average FPS", String(format: "%.2f", report.averageFPS))
                    diagRow("Jitter Frames", "\(report.jitterCount)")
                    diagRow("Duplicates", "\(report.duplicateCount)")
                    diagRow("Sampled Frames", "\(report.totalFrames)")
                    diagRow("Min Delta", String(format: "%.4f s", report.minDelta))
                    diagRow("Max Delta", String(format: "%.4f s", report.maxDelta))
                } else {
                    ContentUnavailableView {
                        Label("No Injected Stream", systemImage: "waveform.path.ecg")
                            .font(.subheadline)
                    } description: {
                        Text(diagnosticsService.driftStatus ?? "Turn on Enable Media in the browser to start an injected stream, then analyze its real frame cadence here.")
                            .font(.caption)
                    }
                    .frame(height: 110)
                }

                Button {
                    Task { await diagnosticsService.generateDriftReport() }
                } label: {
                    Label(diagnosticsService.isMeasuringDrift ? "Measuring…" : "Analyze Injected Stream", systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.cyan.opacity(0.15), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.cyan)
                }
                .disabled(diagnosticsService.isMeasuringDrift)
            }
        }
    }

    /// Shows which feed engine actually engaged (clean track vs Canvas) and, when
    /// a clean-feed method downgraded, the plain-language reason why.
    @ViewBuilder
    private func feedEngineRow(_ fe: FeedEngineStatus) -> some View {
        let clean = fe.isClean
        let intentional = fe.isIntentionalCanvas
        let privateLaneFallback = fe.isPrivateLaneFallback
        let downgraded = fe.downgraded && !intentional
        let tint: Color = clean ? (privateLaneFallback ? .orange : .green) : (downgraded ? .orange : (intentional ? .cyan : .secondary))
        let icon = clean ? (privateLaneFallback ? "exclamationmark.triangle.fill" : "checkmark.seal.fill") : (downgraded ? "arrow.down.right.circle.fill" : "paintbrush.pointed.fill")
        let headline = clean
            ? (fe.isPrivateLane ? "Clean feed · private lane" : (privateLaneFallback ? "Clean feed · private fallback" : "Clean feed live"))
            : (downgraded ? "Downgraded to Canvas" : (intentional ? "Canvas draw (photo step)" : "Canvas feed live"))
        VStack(alignment: .leading, spacing: 6) {
            if fe.isActiveButUnarmed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("Camera takeover not armed — real camera passing through")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                Text(fe.intendedLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: .capsule)
            }
            if (downgraded || intentional || privateLaneFallback), !fe.reasonText.isEmpty {
                Text(fe.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if clean {
                Text(fe.isPrivateLane ? "\(fe.intendedLabel) is running through the private lane — no canvas tell." : "\(fe.intendedLabel) is running its clean background track — no canvas tell.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if clean {
                HStack(spacing: 6) {
                    Image(systemName: fe.sensorGrainEngaged ? "waveform.badge.magnifyingglass" : (fe.sensorTimingEngaged ? "clock.badge.checkmark" : "waveform"))
                        .font(.system(size: 10))
                        .foregroundStyle(fe.sensorRealismEnabled ? tint : Color.secondary)
                    Text("Sensor realism: \(fe.sensorRealismSummary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    // MARK: - Injection Inspector

    private var injectionInspectorSection: some View {
        sectionCard("Injection Inspector", icon: "shield.lefthalf.filled", sectionID: "inspector") {
            VStack(spacing: 10) {
                if let latest = injectionInspector.reports.first {
                    NavigationLink {
                        InjectionInspectionReportDetailView(report: latest)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: inspectorIcon(for: latest))
                                .foregroundStyle(inspectorColor(for: latest))
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(latest.verdictTitle)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(latest.host)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("Likely blocker: \(latest.mostLikelyBlocker.label)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(latest.riskScore)%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(inspectorColor(for: latest))
                        }
                        .padding(10)
                        .background(inspectorColor(for: latest).opacity(0.1), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        inspectorMetric("Blocked", latest.blockedCount, color: .red)
                        inspectorMetric("Warnings", latest.warningCount, color: .orange)
                        inspectorMetric("Reports", injectionInspector.reports.count, color: .cyan)
                    }
                } else {
                    Text("No site inspection reports yet. Open the browser and tap the shield button to test the current site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 6)
                }

                if !injectionInspector.reports.isEmpty {
                    NavigationLink {
                        InjectionInspectionHistoryView(inspector: injectionInspector)
                    } label: {
                        Text("View All (\(injectionInspector.reports.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        injectionInspector.clearReports()
                    } label: {
                        Label("Clear Reports", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func inspectorMetric(_ title: String, _ value: Int, color: Color) -> some View {
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

    private func inspectorIcon(for report: InjectionInspectionReport) -> String {
        if report.hasBlockingEvidence { return "xmark.shield.fill" }
        if report.warningCount > 0 { return "exclamationmark.shield.fill" }
        return "checkmark.shield.fill"
    }

    private func inspectorColor(for report: InjectionInspectionReport) -> Color {
        if report.hasBlockingEvidence { return .red }
        if report.warningCount > 0 { return .orange }
        return .green
    }

    // MARK: - Detector Self-Test

    private var detectorSelfTestSection: some View {
        sectionCard("Detector Self-Test", icon: "checkmark.shield.fill", sectionID: "selftest") {
            VStack(spacing: 10) {
                if let report = selfTestService.latestReport {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.methodLabel)
                                .font(.subheadline.weight(.bold))
                            Text(report.active ? "Tested against the live injected feed" : "Static checks only — turn on Enable Media to test the live feed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 1) {
                            Text("\(report.score)%")
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(badgeColor(report.scoreTintName))
                            Text("\(report.passCount)/\(report.checks.filter { $0.status != .skip }.count) pass")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(badgeColor(report.scoreTintName).opacity(0.12), in: .rect(cornerRadius: 10))
                    }

                    ForEach(report.checks) { check in
                        selfTestRow(check)
                    }
                } else {
                    Text("Run the same tricks detection sites use against your active method — function genuineness, resolution honoring, identity stability, feed timing, and device/stream consistency — and get a scored pass/fail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 4)
                }

                if !selfTestService.status.isEmpty {
                    Text(selfTestService.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await selfTestService.run() }
                } label: {
                    Label(selfTestService.isRunning ? "Testing…" : "Run Self-Test", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.cyan.opacity(0.15), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.cyan)
                }
                .disabled(selfTestService.isRunning)
            }
        }
    }

    private func selfTestRow(_ check: DetectorSelfTestCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.status.icon)
                .foregroundStyle(badgeColor(check.status.tintName))
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.caption.weight(.medium))
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(check.status.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(badgeColor(check.status.tintName))
        }
        .padding(.vertical, 1)
    }

    // MARK: - Private Lane Viability

    private var privateLaneSection: some View {
        sectionCard("Private Lane Viability", icon: "lock.shield.fill", sectionID: "privatelane") {
            VStack(alignment: .leading, spacing: 10) {
                if let report = privateLaneProbe.latestReport {
                    privateLaneVerdict(report)
                    privateLaneCSP(report)
                    ForEach(report.checks) { check in
                        privateLaneRow(check)
                    }
                    Text("Tested on \(report.host.isEmpty ? "this page" : report.host) • \(report.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Proves the make-or-break first link of the private-lane plan on your device: that the clean-feed engine, started from an app-only private lane, comes alive on a strict site that blocks the normal lane. This is a check only — it never touches your live feed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Open a strict verification site (and a known-strict control), then run the check.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !privateLaneProbe.status.isEmpty {
                    Text(privateLaneProbe.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await privateLaneProbe.run() }
                } label: {
                    Label(privateLaneProbe.isRunning ? "Checking…" : "Run Viability Check", systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.cyan.opacity(0.15), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.cyan)
                }
                .disabled(privateLaneProbe.isRunning)
            }
        }
    }

    private func privateLaneVerdict(_ report: PrivateLaneProbeReport) -> some View {
        let tint = badgeColor(report.verdictTintName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: report.verdictIcon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(report.verdictTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(report.verdictReason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    private func privateLaneCSP(_ report: PrivateLaneProbeReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.cspLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if report.displayCSP.isEmpty {
                Text("No Content-Security-Policy was seen for this site — it may not be a strict site.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(report.displayCSP)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 8))
    }

    private func privateLaneRow(_ check: PrivateLaneCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.status.icon)
                .foregroundStyle(badgeColor(check.status.tintName))
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.caption.weight(.medium))
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(check.status.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(badgeColor(check.status.tintName))
        }
        .padding(.vertical, 1)
    }

    // MARK: - Network Rewrite Proxy

    private var networkRewriteSection: some View {
        sectionCard("Network Rewrite Proxy", icon: "arrow.triangle.swap", sectionID: "netrewrite") {
            let proxy = NetworkRewriteProxyService.shared
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: proxy.isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(proxy.isRunning ? .green : .secondary)
                        .font(.caption)
                    Text(proxy.isRunning ? "Running" : "Stopped")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(proxy.isRunning ? .green : .secondary)
                    Spacer()
                    if proxy.port > 0 {
                        Text("127.0.0.1:\(proxy.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(proxy.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Turn on Rewrite proxy from the browser's Network backend switches to route the page through this proxy. Plain-HTTP pages are rewritten (security policies and integrity locks stripped); HTTPS pages are tunneled and keep relying on the selected camera method. Verify on a real device.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Adaptive Injection

    private var adaptiveInjectionSection: some View {
        sectionCard("Adaptive Injection", icon: "slider.horizontal.2.square", sectionID: "adaptive") {
            VStack(spacing: 10) {
                let worked = siteMemory.records.filter { $0.outcome == .worked }.count
                let failed = siteMemory.records.filter { $0.outcome == .failed }.count
                HStack(spacing: 8) {
                    inspectorMetric("Sites", siteMemory.records.count, color: .cyan)
                    inspectorMetric("Worked", worked, color: .green)
                    inspectorMetric("Failed", failed, color: .red)
                }

                NavigationLink {
                    SiteMemoryView(siteMemory: siteMemory)
                } label: {
                    HStack {
                        Label("Site Memory", systemImage: "externaldrive.fill.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Constraint Log

    private var constraintLogSection: some View {
        sectionCard("Constraint Log", icon: "list.clipboard", sectionID: "constraints") {
            VStack(spacing: 10) {
                if constraintLog.entries.isEmpty {
                    Text("No constraint entries logged yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    ForEach(constraintLog.entries.prefix(5)) { entry in
                        constraintEntryRow(entry)
                    }

                    NavigationLink {
                        ConstraintLogView(constraintLog: constraintLog)
                    } label: {
                        Text("View All (\(constraintLog.entries.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        constraintLog.clearLog()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func constraintEntryRow(_ entry: ConstraintLogEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.wasSuccessful ? .green : .red)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.siteURL)
                    .font(.caption)
                    .lineLimit(1)
                Text(entry.requestedConstraints.prefix(60))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Site History

    private var siteHistorySection: some View {
        sectionCard("Site History", icon: "clock.arrow.circlepath", sectionID: "sites") {
            VStack(spacing: 10) {
                let sites = siteHistory.uniqueSites()
                if sites.isEmpty {
                    Text("No site history recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    ForEach(sites.prefix(5), id: \.self) { site in
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .foregroundStyle(.cyan)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site)
                                    .font(.caption)
                                    .lineLimit(1)
                                if let profile = siteHistory.lastSuccessfulProfile(for: site) {
                                    Text("Last: \(profile)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }

                    NavigationLink {
                        SiteHistoryView(siteHistory: siteHistory)
                    } label: {
                        Text("View All (\(sites.count) sites)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        siteHistory.clearHistory()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(
        _ title: String,
        icon: String,
        sectionID: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    if expandedSections.contains(sectionID) {
                        expandedSections.remove(sectionID)
                    } else {
                        expandedSections.insert(sectionID)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                        .frame(width: 24)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expandedSections.contains(sectionID) ? 180 : 0))
                }
                .padding(14)
            }

            if expandedSections.contains(sectionID) {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func formatBitrate(_ bitrate: Int?) -> String {
        guard let br = bitrate, br > 0 else { return "—" }
        if br >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(br) / 1_000_000)
        }
        return "\(br / 1000) kbps"
    }

    private func formatBitrate(_ bitrate: Int) -> String {
        formatBitrate(Optional(bitrate))
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Scrollable viewer for the connection debug log.
struct ConnectionLogSheet: View {
    @State private var entries: [ConnectionLogService.Entry] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.formattedLine)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(entry.category == .error ? DS.blocked : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                                .opacity(0.3)
                                .padding(.vertical, 1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Connection Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { }
                }
            }
            .onAppear {
                entries = ConnectionLogService.shared.entries
            }
        }
        .preferredColorScheme(.dark)
    }
}
