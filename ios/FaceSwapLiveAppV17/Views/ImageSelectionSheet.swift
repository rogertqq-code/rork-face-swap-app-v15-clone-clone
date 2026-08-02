import SwiftUI
import PhotosUI

struct ImageSelectionSheet: View {
    let onImageSelected: (UIImage) -> Void
    @State private var friendPickerItem: PhotosPickerItem?
    @State private var celebrityPickerItem: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text("Choose an Image")
                    .font(.title2.bold())
                    .padding(.top, 4)

                HStack(spacing: 16) {
                    PhotosPicker(selection: $friendPickerItem, matching: .images) {
                        OptionCard(
                            icon: "person.2.fill",
                            title: "Friend",
                            subtitle: "Pick from your photos",
                            colors: [Color(red: 0.2, green: 0.5, blue: 1.0), Color(red: 0.3, green: 0.8, blue: 0.9)]
                        )
                    }
                    .accessibilityIdentifier("preview.source.friend")

                    PhotosPicker(selection: $celebrityPickerItem, matching: .images) {
                        OptionCard(
                            icon: "star.fill",
                            title: "Celebrity",
                            subtitle: "Upload a photo",
                            colors: [Color(red: 0.7, green: 0.3, blue: 0.9), Color(red: 1.0, green: 0.4, blue: 0.6)]
                        )
                    }
                    .accessibilityIdentifier("preview.source.celebrity")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Tips")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        TipRow(icon: "face.smiling", text: "Use a clear, front-facing photo")
                        TipRow(icon: "sun.max", text: "Good lighting gives better results")
                        TipRow(icon: "person.crop.rectangle", text: "One face per photo works best")
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("preview.source.cancel")
                }
            }
        }
        .accessibilityIdentifier("preview.source.sheet")
        .onChange(of: friendPickerItem) { _, item in
            loadImage(from: item)
        }
        .onChange(of: celebrityPickerItem) { _, item in
            loadImage(from: item)
        }
    }

    private func loadImage(from item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                onImageSelected(image)
            }
        }
    }
}

private struct OptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let colors: [Color]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.white)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(.rect(cornerRadius: 16))
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
