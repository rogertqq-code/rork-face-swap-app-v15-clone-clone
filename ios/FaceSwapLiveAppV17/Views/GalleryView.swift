import SwiftUI

struct GalleryView: View {
    let images: [CapturedImage]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: CapturedImage?

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    ContentUnavailableView(
                        "No Captures Yet",
                        systemImage: "camera.fill",
                        description: Text("Your captures will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 2),
                            GridItem(.flexible(), spacing: 2),
                            GridItem(.flexible(), spacing: 2)
                        ], spacing: 2) {
                            ForEach(images) { item in
                                Button {
                                    selectedItem = item
                                } label: {
                                    Color(.secondarySystemBackground)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            Image(uiImage: item.image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .allowsHitTesting(false)
                                        }
                                        .clipShape(.rect)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedItem) { item in
                ImageDetailView(image: item.image)
            }
        }
    }
}

private struct ImageDetailView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Capture", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
