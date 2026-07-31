import SwiftUI

/// Shown when "ask me every request" is on and a camera request pauses. Presents
/// exactly what the site asked for and lets the user choose what to serve.
struct CameraRequestPromptSheet: View {
    let request: PendingCameraRequest
    let queuedStepCount: Int
    let rememberAvailable: Bool
    /// Servable queue items the user can hand over specifically, in order.
    let pickableSteps: [SequenceStep]
    let onDecision: (CameraRequestAction, Bool, UUID?) -> Void

    @State private var rememberForSite: Bool = false

    var body: some View {
        NavigationStack {
            List {
                headerSection
                detailSection
                if rememberAvailable {
                    Section {
                        Toggle("Always do this for this site", isOn: $rememberForSite)
                            .font(.subheadline)
                    }
                }
                actionSection
                pickSection
            }
            .navigationTitle("Camera Request")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled()
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DS.accent.opacity(0.16))
                            .frame(width: 38, height: 38)
                        Image(systemName: request.kind.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DS.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.kind.label)
                            .font(.headline)
                        Text(hostLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("This site is asking for the camera. Choose what to hand it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var detailSection: some View {
        Section("What was asked") {
            detailRow("Camera side", request.facingLabel, "camera.rotate")
            detailRow("Requested size", request.sizeLabel, "aspectratio")
            detailRow("Frame rate", request.frameRateLabel, "speedometer")
            detailRow("Asked by", request.sourceLabel, request.isFrame ? "rectangle.on.rectangle" : "doc.text")
        }
    }

    private func detailRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var actionSection: some View {
        Section {
            ForEach(CameraRequestAction.allCases) { action in
                Button {
                    onDecision(action, rememberForSite, nil)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint(for: action))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(subtitle(for: action))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .disabled(action == .serveNext && queuedStepCount == 0)
            }
        } header: {
            Text("Serve")
        } footer: {
            if queuedStepCount == 0 {
                Text("Nothing is queued right now, so there is no item to serve.")
            }
        }
    }

    /// Hand over one exact queued item for this single request.
    @ViewBuilder
    private var pickSection: some View {
        if !pickableSteps.isEmpty {
            Section {
                ForEach(Array(pickableSteps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        onDecision(.serveNext, false, step.id)
                    } label: {
                        HStack(spacing: 12) {
                            thumbnail(step)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stepLabel(step, index: index))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(step.kind == .video ? "Video" : "Photo")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            } header: {
                Text("Or pick a specific item")
            } footer: {
                Text("Serves that exact item for this one request without changing your queue order.")
            }
        }
    }

    private func thumbnail(_ step: SequenceStep) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 38, height: 38)
            if let image = step.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: step.kind == .video ? "video.fill" : "photo.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepLabel(_ step: SequenceStep, index: Int) -> String {
        let name = step.displayName.isEmpty
            ? (step.kind == .video ? "Video" : "Photo")
            : step.displayName
        return "\(index + 1). \(name)"
    }

    private var hostLabel: String {
        guard let url = URL(string: request.origin), let host = url.host else {
            return request.origin.isEmpty ? "Unknown page" : request.origin
        }
        return host
    }

    private func tint(for action: CameraRequestAction) -> Color {
        switch action {
        case .serveNext: DS.good
        case .block: .red
        case .realCamera: DS.caution
        }
    }

    private func subtitle(for action: CameraRequestAction) -> String {
        switch action {
        case .serveNext:
            queuedStepCount == 1
                ? "Hand over your 1 queued item"
                : "Hand over the next of your \(queuedStepCount) queued items"
        case .block:
            "The site is told permission was denied"
        case .realCamera:
            "Your real device camera answers this one"
        }
    }
}
