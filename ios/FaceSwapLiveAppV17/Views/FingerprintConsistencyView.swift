import SwiftUI

struct FingerprintConsistencyView: View {
    @Bindable var service: FingerprintService
    @State private var iterations: Int = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    overallStatusBanner
                    configurationCard
                    resultsCard
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fingerprint Test")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Overall Status

    @ViewBuilder
    private var overallStatusBanner: some View {
        if let passed = service.testPassed {
            HStack(spacing: 10) {
                Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(passed ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(passed ? "All Consistent" : "Inconsistencies Found")
                        .font(.headline)
                        .foregroundStyle(passed ? .green : .red)
                    Text("\(service.consistencyResults.count) fields tested across \(iterations) iterations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background((passed ? Color.green : Color.red).opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Configuration

    private var configurationCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.cyan)
                Text("Test Configuration")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Divider()

            Stepper(value: $iterations, in: 3...10) {
                HStack {
                    Text("Iterations")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(iterations)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.cyan.opacity(0.15), in: .rect(cornerRadius: 6))
                }
            }

            Button {
                Task {
                    await service.runConsistencyTest(iterations: iterations)
                }
            } label: {
                Group {
                    if service.isTesting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.black)
                            Text("Testing…")
                        }
                    } else {
                        Label("Run Test", systemImage: "play.fill")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.cyan, in: .rect(cornerRadius: 10))
                .foregroundStyle(.black)
            }
            .disabled(service.isTesting)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    // MARK: - Results

    private var resultsCard: some View {
        VStack(spacing: 12) {
            if service.consistencyResults.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "testtube.2")
                        .font(.subheadline)
                } description: {
                    Text("Run a consistency test to see results.")
                        .font(.caption)
                }
                .frame(height: 120)
            } else {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(.cyan)
                    Text("Results")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    let passCount = service.consistencyResults.filter(\.isConsistent).count
                    Text("\(passCount)/\(service.consistencyResults.count) passed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ForEach(service.consistencyResults) { result in
                    resultRow(result)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func resultRow(_ result: FingerprintConsistencyResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.isConsistent ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.isConsistent ? .green : .red)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.field)
                    .font(.caption.weight(.medium))

                let display = result.values.prefix(3).joined(separator: ", ")
                let suffix = result.values.count > 3 ? " +\(result.values.count - 3) more" : ""
                Text(display + suffix)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
