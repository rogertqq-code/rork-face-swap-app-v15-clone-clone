import SwiftUI

/// Per-site memory: which profile was used on each host and whether it worked,
/// with a quick way to flip the verdict or clear records.
struct SiteMemoryView: View {
    @Bindable var siteMemory: SiteProfileMemoryService
    @State private var showClearConfirm: Bool = false

    var body: some View {
        Group {
            if siteMemory.records.isEmpty {
                ContentUnavailableView {
                    Label("No Site Memory", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Confirm a recommended profile on a site, then mark whether it worked. Your verdicts show up here.")
                }
            } else {
                List {
                    ForEach(siteMemory.sortedRecords) { record in
                        recordRow(record)
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    siteMemory.delete(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } 
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Site Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .disabled(siteMemory.records.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all site memory?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Memory", role: .destructive) {
                siteMemory.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every per-site profile verdict. This can't be undone.")
        }
        .preferredColorScheme(.dark)
    }

    private func recordRow(_ record: SiteProfileRecord) -> some View {
        let profileTint = Color(themeName: record.profile.tintName)
        let outcomeTint = Color(themeName: record.outcome.tintName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.cyan)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.host)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let system = record.detectedSystemName {
                        Text(system)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Label(record.profile.label, systemImage: record.profile.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(profileTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(profileTint.opacity(0.14), in: .capsule)
            }

            HStack(spacing: 8) {
                Label(record.outcome.label, systemImage: record.outcome.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(outcomeTint)
                if record.autoGuessed && record.outcome != .untested {
                    Text("auto")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.gray.opacity(0.15), in: .capsule)
                }
                Spacer()
                Button {
                    Haptics.impact(.light)
                    siteMemory.setOutcome(.worked, forRecordID: record.id)
                } label: {
                    Image(systemName: record.outcome == .worked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle(record.outcome == .worked ? .green : .secondary)
                }
                .buttonStyle(.plain)
                Button {
                    Haptics.impact(.light)
                    siteMemory.setOutcome(.failed, forRecordID: record.id)
                } label: {
                    Image(systemName: record.outcome == .failed ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(record.outcome == .failed ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }
}
