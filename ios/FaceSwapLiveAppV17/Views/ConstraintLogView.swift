import SwiftUI

struct ConstraintLogView: View {
    let constraintLog: ConstraintLogService
    @State private var showClearConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if constraintLog.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Entries", systemImage: "list.clipboard")
                            .font(.subheadline)
                    } description: {
                        Text("Constraint negotiation entries will appear here as sites request media access.")
                            .font(.caption)
                    }
                } else {
                    List {
                        ForEach(constraintLog.entries) { entry in
                            entryRow(entry)
                                .listRowBackground(Color(.secondarySystemGroupedBackground))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Constraint Log")
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
                    .disabled(constraintLog.entries.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear the constraint log?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Log", role: .destructive) {
                    constraintLog.clearLog()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every recorded constraint negotiation. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func entryRow(_ entry: ConstraintLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.wasSuccessful ? .green : .red)

                Text(entry.siteURL)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer()

                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !entry.requestedConstraints.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Requested")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(entry.requestedConstraints)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.cyan.opacity(0.8))
                        .lineLimit(4)
                }
            }

            if !entry.negotiatedResult.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Negotiated")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(entry.negotiatedResult)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green.opacity(0.8))
                        .lineLimit(4)
                }
            }

            if let reason = entry.fallbackReason, !reason.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
