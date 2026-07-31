import SwiftUI

/// First-run and rerunnable offline device verification. The flow clearly
/// separates local evidence from browser behavior the app cannot prove offline.
struct OfflineVerificationFlowView: View {
    let profile: DeviceProfile
    let onComplete: (OfflineVerificationReport) -> Void

    @State private var service = OfflineVerificationService()
    @State private var report: OfflineVerificationReport?
    @State private var isCameraCapturePresented: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if service.isRunning {
                        progressCard
                    } else if let report {
                        resultContent(report)
                    } else {
                        introContent
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Device Verification")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(service.isRunning)
        .fullScreenCover(isPresented: $isCameraCapturePresented) {
            CameraCaptureView(source: .camera) { image, source in
                if let report {
                    self.report = service.recordGuidedCameraCapture(image: image, source: source, in: report)
                }
                isCameraCapturePresented = false
            } onCancel: {
                isCameraCapturePresented = false
            }
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: 76, height: 76)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            Text("Verify this device")
                .font(.title2.bold())
            Text("The app checks only what it can honestly confirm on this device. Browser permissions and external-site behavior remain clearly marked until they are observed separately.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }

    private var introContent: some View {
        VStack(spacing: 14) {
            infoCard(
                icon: "lock.fill",
                title: "Private by design",
                detail: "No test photo or audio sample is kept in your verification record. Only short result notes and device capability counts are saved."
            )
            infoCard(
                icon: "wifi.slash",
                title: "Offline-first",
                detail: "This run uses app-owned checks. It does not claim that an external browser or third-party site has accepted anything."
            )

            Button {
                startAutomaticChecks()
            } label: {
                Label("Start Offline Check", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.black)
                    .background(.cyan, in: .rect(cornerRadius: 14))
            }
            .accessibilityIdentifier("offlineVerificationStart")

            Button("Skip for Now") {
                finish(service.skippedReport(for: profile))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("offlineVerificationSkip")
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.cyan)
                Text(service.progressLabel)
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: service.progress)
                .tint(.cyan)
            Text("This takes only a moment and does not upload your media.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func resultContent(_ report: OfflineVerificationReport) -> some View {
        VStack(spacing: 14) {
            outcomeCard(report)
            guidedCaptureCard(report)
            browserScopeCard(report)

            ForEach(report.checks.filter { $0.id != .browserCompatibility && $0.id != .browserFixture }) { check in
                OfflineVerificationCheckRow(check: check)
            }

            if report.outcome == .verified {
                Button {
                    finish(report)
                } label: {
                    Label("Finish Verification", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.black)
                        .background(.cyan, in: .rect(cornerRadius: 14))
                }
                .accessibilityIdentifier("offlineVerificationFinish")
            } else {
                Button {
                    finish(report)
                } label: {
                    Label("Save as Needs Verification", systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.black)
                        .background(.orange, in: .rect(cornerRadius: 14))
                }
                .accessibilityIdentifier("offlineVerificationSaveWarning")

                Button("Skip Remaining Checks") {
                    finish(service.skippedReport(for: profile))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func outcomeCard(_ report: OfflineVerificationReport) -> some View {
        let tint = color(named: report.outcome.tintName)
        return HStack(spacing: 12) {
            Image(systemName: report.outcome.iconName)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.outcome.title)
                    .font(.headline)
                Text("\(report.passCount) local check\(report.passCount == 1 ? "" : "s") passed. You can rerun this anytime from the device profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
    }

    private func guidedCaptureCard(_ report: OfflineVerificationReport) -> some View {
        guard let check = report.check(.guidedCameraCapture) else { return AnyView(EmptyView()) }
        let tint = color(named: check.status.tintName)
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(tint)
                Text("Guided real-camera check")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(check.status.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(check.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if check.status != .passed && CameraCaptureView.isCameraAvailable {
                Button {
                    isCameraCapturePresented = true
                } label: {
                    Label("Take a Test Photo", systemImage: "camera.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .accessibilityIdentifier("offlineVerificationCameraCapture")
            } else if check.status != .passed {
                Button("Open Camera Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14)))
    }

    private func browserScopeCard(_ report: OfflineVerificationReport) -> some View {
        let check = report.check(.browserCompatibility)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.cyan)
                Text("What this cannot prove offline")
                    .font(.subheadline.weight(.semibold))
            }
            Text(check?.summary ?? "External browser and third-party-site behavior remain unverified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.cyan.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private func infoCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func startAutomaticChecks() {
        Task {
            report = await service.runAutomaticChecks(profile: profile)
        }
    }

    private func finish(_ report: OfflineVerificationReport) {
        onComplete(report)
        dismiss()
    }

    private func color(named name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }
}

/// A reusable row for a single offline-verification check.
struct OfflineVerificationCheckRow: View {
    let check: OfflineVerificationCheck

    var body: some View {
        let tint = color(named: check.status.tintName)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.iconName)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.id.title)
                    .font(.subheadline.weight(.semibold))
                Text(check.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(check.status.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func color(named name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }
}

/// A privacy-conscious history of verification runs for one saved profile.
struct OfflineVerificationReportView: View {
    let profile: DeviceProfile
    let store: OfflineVerificationStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.reports(for: profile.id).isEmpty {
                    ContentUnavailableView {
                        Label("No Verification History", systemImage: "checkmark.shield")
                    } description: {
                        Text("Run device verification from this profile to save the first report.")
                    }
                    .padding(.top, 72)
                } else {
                    ForEach(store.reports(for: profile.id)) { report in
                        reportCard(report)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 36)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Verification Report")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func reportCard(_ report: OfflineVerificationReport) -> some View {
        let tint = color(named: report.outcome.tintName)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.outcome.iconName)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.outcome.title)
                        .font(.headline)
                    Text(report.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("v\(report.appVersion)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            ForEach(report.checks) { check in
                OfflineVerificationCheckRow(check: check)
            }

            if let method = report.fixtureMethod {
                Divider()
                Label("Built-in fixture evidence: \(method.label)", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                if !report.fixtureSummary.isEmpty {
                    Text(report.fixtureSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 16))
    }

    private func color(named name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }
}
