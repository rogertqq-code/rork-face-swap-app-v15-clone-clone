import SwiftUI

/// The full breakdown of one automatic full-test run — every method/media
/// combination with all recorded values, the detector-trick results, and the
/// passthrough + block-step outcomes.
struct DiagnosticsFullTestReportView: View {
    let report: DiagnosticsFullTestReport

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                environmentCard
                summaryCard
                ForEach(report.results) { result in
                    methodCard(result)
                }
                passthroughCard
                blockCard
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Full Test Report")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    // MARK: - Environment

    private var environmentCard: some View {
        DSCard {
            DSSectionHeader("Environment", icon: "globe")
            let env = report.environment
            DSInfoRow(label: "Secure context", value: env.secureContext ? "Yes (trusted)" : "No", labelWidth: 130, valueTint: env.secureContext ? .green : .orange)
            DSInfoRow(label: "Camera APIs", value: env.hasMediaDevices ? "Present" : "Missing", labelWidth: 130, valueTint: env.hasMediaDevices ? .green : .red)
            DSInfoRow(label: "iOS", value: env.iosVersion.isEmpty ? "Unknown" : env.iosVersion, labelWidth: 130)
            DSInfoRow(label: "WebCodecs", value: capabilitiesLine(env), labelWidth: 130)
            DSInfoRow(label: "Device profile", value: "\(env.deviceProfileName) · \(env.profileResolution)", labelWidth: 130)
            if !env.userAgent.isEmpty {
                Text(env.userAgent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capabilitiesLine(_ env: DiagTestEnvironment) -> String {
        "Worker \(env.hasWorker ? "✓" : "✗") · VideoFrame \(env.hasVideoFrame ? "✓" : "✗") · VTG \(env.hasVideoTrackGenerator ? "✓" : "✗")"
    }

    // MARK: - Summary

    private var summaryCard: some View {
        DSCard {
            DSSectionHeader("Summary", icon: "list.bullet.rectangle")
            Text(report.summaryLine)
                .font(.subheadline.weight(.semibold))
            if !report.recommendedMethodRaw.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    Text("Fixture-backed method: \(report.recommendedMethodLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.accent)
                }
            }
            ForEach(report.results) { r in
                HStack(spacing: 8) {
                    Image(systemName: r.overall.icon).foregroundStyle(tint(r.overall.tintName)).font(.caption)
                    Text("\(r.methodLabel) · \(r.mediaLabel)").font(.caption)
                    Spacer()
                    Text(r.overall.label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(tint(r.overall.tintName))
                }
            }
        }
    }

    // MARK: - Method card

    private func methodCard(_ r: DiagMethodResult) -> some View {
        DSCard {
            HStack(spacing: 8) {
                Image(systemName: r.overall.icon).foregroundStyle(tint(r.overall.tintName))
                Text("\(r.methodLabel) · \(r.mediaLabel)")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(r.overall.label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint(r.overall.tintName))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint(r.overall.tintName).opacity(0.14), in: .capsule)
            }
            DSInfoRow(label: "Takeover armed", value: r.armed ? "Yes" : "No", labelWidth: 130, valueTint: r.armed ? .green : .red)
            DSInfoRow(label: "getUserMedia", value: r.gumSucceeded ? "Served" : "Failed", labelWidth: 130, valueTint: r.gumSucceeded ? .green : .red)
            DSInfoRow(label: "Site received", value: "\(r.resolutionLabel) @ \(fmt(r.claimedFps)) fps", labelWidth: 130)
            DSInfoRow(label: "Delivery engine", value: r.feedLabel, labelWidth: 130, valueTint: r.feed == "vtg" ? .green : (r.feed == "canvas" ? .cyan : .secondary))
            DSInfoRow(label: "Sensor realism", value: r.sensorRealismShort, labelWidth: 130, valueTint: r.sensorGrainEngaged ? .green : (r.sensorTimingEngaged ? .cyan : .secondary))
            DSInfoRow(label: "Frames flowing", value: r.framesFlowing ? "Yes (\(r.frameCount), ~\(fmt(r.measuredFps)) fps)" : "No", labelWidth: 130, valueTint: r.framesFlowing ? .green : .red)
            DSInfoRow(label: "File picker", value: r.pickerReturnedMedia ? "Returned media" : "Nothing", labelWidth: 130, valueTint: r.pickerReturnedMedia ? .green : .orange)
            DSInfoRow(label: "Camera capture", value: r.captureReturnedMedia ? "Returned media" : "Nothing", labelWidth: 130, valueTint: r.captureReturnedMedia ? .green : .orange)
            DSInfoRow(label: "Detector score", value: "\(r.detectorScore)%", labelWidth: 130)

            if !r.notes.isEmpty {
                Text(r.notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !r.detectorChecks.isEmpty {
                Divider()
                ForEach(r.detectorChecks) { check in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: check.status.icon).foregroundStyle(tint(check.status.tintName)).font(.caption2).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).font(.caption2.weight(.medium))
                            if !check.detail.isEmpty {
                                Text(check.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(check.status.label).font(.system(size: 9, weight: .bold)).foregroundStyle(tint(check.status.tintName))
                    }
                }
            }
        }
    }

    // MARK: - Passthrough + block

    private var passthroughCard: some View {
        DSCard {
            HStack(spacing: 8) {
                Image(systemName: report.passthrough.status.icon).foregroundStyle(tint(report.passthrough.status.tintName))
                Text("Passthrough").font(.subheadline.weight(.bold))
                Spacer()
                Text(report.passthrough.status.label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(tint(report.passthrough.status.tintName))
            }
            Text(report.passthrough.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blockCard: some View {
        DSCard {
            HStack(spacing: 8) {
                Image(systemName: report.block.status.icon).foregroundStyle(tint(report.block.status.tintName))
                Text("Block Step").font(.subheadline.weight(.bold))
                Spacer()
                Text(report.block.status.label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(tint(report.block.status.tintName))
            }
            Text(report.block.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    private func tint(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "cyan": return .cyan
        case "yellow": return .yellow
        default: return .gray
        }
    }
}
