import SwiftUI

/// Compact, always-visible delivery health for the browser media pipeline.
struct MediaDeliveryStatusStrip: View {
    let viewModel: BrowserViewModel

    var body: some View {
        let tint = statusTint
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: viewModel.mediaDeliveryStatus.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.16), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.mediaDeliveryStatus.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text(viewModel.mediaDeliveryDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if viewModel.mediaDeliveryStatus == .needsAttention || viewModel.mediaDeliveryStatus == .blocked {
                Button {
                    viewModel.retryMediaDelivery()
                    Haptics.selection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(tint.opacity(0.12), in: .circle)
                }
                .accessibilityIdentifier("browser.media.retry")
                .accessibilityLabel("Retry media delivery")

                Menu {
                    Button(role: .destructive) {
                        viewModel.resetInjectionDefaults()
                    } label: {
                        Label("Reset Injection Defaults", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityIdentifier("browser.media.recoveryMenu")
                .accessibilityLabel("Media delivery recovery options")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.09), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.media.status")
        .accessibilityLabel("Media delivery")
        .accessibilityValue("status=\(viewModel.mediaDeliveryStatus.rawValue);active=\(viewModel.isMediaActive);request=\(viewModel.activeMediaRequestID);origin=\(viewModel.activeMediaRequestOrigin);detail=\(viewModel.mediaDeliveryDetail)")
        .animation(.spring(duration: 0.25), value: viewModel.mediaDeliveryStatus)
        .animation(.spring(duration: 0.25), value: viewModel.mediaDeliveryDetail)
    }

    private var statusTint: Color {
        switch viewModel.mediaDeliveryStatus {
        case .idle, .pageReady:
            .secondary
        case .preparing:
            .blue
        case .receivingFrames:
            DS.good
        case .completed:
            .green
        case .blocked:
            .orange
        case .needsAttention:
            .red
        }
    }
}
