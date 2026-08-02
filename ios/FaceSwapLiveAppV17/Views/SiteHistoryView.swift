import SwiftUI

struct SiteHistoryView: View {
    let siteHistory: SiteHistoryService
    @State private var showClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                let sites = siteHistory.uniqueSites()
                if sites.isEmpty {
                    ContentUnavailableView {
                        Label("No History", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                    } description: {
                        Text("Site history entries will appear as you visit sites that request camera access.")
                            .font(.caption)
                    }
                } else {
                    List {
                        ForEach(sites, id: \.self) { site in
                            siteSection(site)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Site History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .disabled(siteHistory.entries.isEmpty)
                    .accessibilityIdentifier("diagnostics.siteHistory.clear")
                }
            }
            .confirmationDialog(
                "Clear all site history?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    siteHistory.clearHistory()
                }
                .accessibilityIdentifier("diagnostics.siteHistory.clear.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("diagnostics.siteHistory.clear.cancel")
            } message: {
                Text("This permanently removes every recorded site visit. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("diagnostics.siteHistory.screen")
        .accessibilityValue("entries=\(siteHistory.entries.count);sites=\(siteHistory.uniqueSites().count)")
    }

    private func siteSection(_ site: String) -> some View {
        Section {
            if let lastProfile = siteHistory.lastSuccessfulProfile(for: site) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Successful Profile")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(lastProfile)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            ForEach(siteHistory.entriesForSite(site)) { entry in
                entryRow(entry)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                Text(site)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.none)
            }
        }
    }

    private func entryRow(_ entry: SiteHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.wasSuccessful ? .green : .red)
                    .font(.caption)

                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if !entry.profileUsed.isEmpty {
                    Text(entry.profileUsed)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.cyan.opacity(0.15), in: Capsule())
                }
            }

            if !entry.requestedConstraints.isEmpty {
                Text(entry.requestedConstraints)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !entry.actualSettings.isEmpty {
                Text(entry.actualSettings)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.green.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("diagnostics.siteHistory.entry.\(entry.id.uuidString)")
        .accessibilityValue("site=\(entry.siteURL);success=\(entry.wasSuccessful);profile=\(entry.profileUsed)")
    }
}
