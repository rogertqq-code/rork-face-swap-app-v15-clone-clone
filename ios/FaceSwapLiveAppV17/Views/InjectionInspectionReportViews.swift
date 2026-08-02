import SwiftUI

struct InjectionInspectionReportDetailView: View {
    let report: InjectionInspectionReport

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: reportIcon)
                                .font(.title2)
                                .foregroundStyle(reportColor)
                                .frame(width: 34, height: 34)
                                .background(reportColor.opacity(0.14), in: .rect(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.verdictTitle)
                                    .font(.headline)
                                Text(report.verdictDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 8) {
                            labelChip("Risk \(report.riskScore)%", color: reportColor)
                            labelChip(report.mostLikelyBlocker.label, color: .cyan)
                            if report.mediaWasActive {
                                labelChip("Active", color: .green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Site") {
                    detailRow("Host", report.host)
                    detailRow("URL", report.siteURL)
                    if !report.pageTitle.isEmpty {
                        detailRow("Title", report.pageTitle)
                    }
                    detailRow("Tested", report.timestamp.formatted(date: .abbreviated, time: .shortened))
                    detailRow("Sequence", "\(report.sequenceLength) step\(report.sequenceLength == 1 ? "" : "s")")
                }

                if !report.cspPolicyText.isEmpty {
                    Section("Security Policy") {
                        Text(report.cspPolicyText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Findings") {
                    ForEach(report.findings) { finding in
                        findingRow(finding)
                    }
                }

                if !report.userAgent.isEmpty {
                    Section("Browser Identity") {
                        Text(report.userAgent)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Injection Inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("diagnostics.injectionReport.detail")
        .accessibilityValue("id=\(report.id.uuidString);host=\(report.host);risk=\(report.riskScore);blocked=\(report.blockedCount);warnings=\(report.warningCount)")
    }

    private var reportColor: Color {
        if report.hasBlockingEvidence { return .red }
        if report.warningCount > 0 { return .orange }
        return .green
    }

    private var reportIcon: String {
        if report.hasBlockingEvidence { return "xmark.shield.fill" }
        if report.warningCount > 0 { return "exclamationmark.shield.fill" }
        return "checkmark.shield.fill"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func labelChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: .capsule)
    }

    private func findingRow(_ finding: InjectionProbeFinding) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: finding.severity))
                    .foregroundStyle(color(for: finding.severity))
                    .font(.caption)
                    .frame(width: 18)
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(finding.severity.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color(for: finding.severity))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color(for: finding.severity).opacity(0.12), in: .capsule)
            }

            Text(finding.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !finding.evidence.isEmpty {
                Text(finding.evidence)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("diagnostics.injectionReport.finding.\(finding.id.uuidString)")
        .accessibilityValue("severity=\(finding.severity.rawValue);blocker=\(finding.blocker.rawValue);title=\(finding.title)")
    }

    private func icon(for severity: InjectionFindingSeverity) -> String {
        switch severity {
        case .pass: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: InjectionFindingSeverity) -> Color {
        switch severity {
        case .pass: return .green
        case .info: return .cyan
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}

struct InjectionInspectionHistoryView: View {
    let inspector: InjectionInspectionService
    @State private var showClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if inspector.reports.isEmpty {
                    ContentUnavailableView {
                        Label("No Reports", systemImage: "shield.lefthalf.filled")
                    } description: {
                        Text("Run Test this site from the browser to capture a per-site injection report.")
                    }
                } else {
                    List {
                        ForEach(inspector.reports) { report in
                            NavigationLink {
                                InjectionInspectionReportDetailView(report: report)
                            } label: {
                                reportRow(report)
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                            .accessibilityIdentifier("diagnostics.injectionReports.item.\(report.id.uuidString)")
                            .accessibilityValue("host=\(report.host);risk=\(report.riskScore);blocked=\(report.blockedCount);warnings=\(report.warningCount)")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Inspector Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(inspector.reports.isEmpty)
                    .accessibilityIdentifier("diagnostics.injectionReports.clear")
                }
            }
            .confirmationDialog(
                "Clear all inspector reports?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Reports", role: .destructive) {
                    inspector.clearReports()
                }
                .accessibilityIdentifier("diagnostics.injectionReports.clear.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("diagnostics.injectionReports.clear.cancel")
            } message: {
                Text("This permanently removes every saved per-site injection report. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("diagnostics.injectionReports.screen")
        .accessibilityValue("count=\(inspector.reports.count)")
    }

    private func reportRow(_ report: InjectionInspectionReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: report))
                .foregroundStyle(color(for: report))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(report.verdictTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(report.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(report.riskScore)%")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color(for: report))
        }
        .padding(.vertical, 3)
    }

    private func icon(for report: InjectionInspectionReport) -> String {
        if report.hasBlockingEvidence { return "xmark.shield.fill" }
        if report.warningCount > 0 { return "exclamationmark.shield.fill" }
        return "checkmark.shield.fill"
    }

    private func color(for report: InjectionInspectionReport) -> Color {
        if report.hasBlockingEvidence { return .red }
        if report.warningCount > 0 { return .orange }
        return .green
    }
}
