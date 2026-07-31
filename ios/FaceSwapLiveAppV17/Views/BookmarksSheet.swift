import SwiftUI

struct BookmarksSheet: View {
    let viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Pages you bookmark will appear here.")
                    )
                } else {
                    List {
                        ForEach(viewModel.bookmarks) { bookmark in
                            Button {
                                viewModel.urlText = bookmark.urlString
                                viewModel.navigateTo(bookmark.urlString)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.tertiarySystemFill))
                                            .frame(width: 36, height: 36)
                                        Text(String(bookmark.title.prefix(1)).uppercased())
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(bookmark.displayHost)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                viewModel.removeBookmark(viewModel.bookmarks[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
