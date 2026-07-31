import Foundation

nonisolated struct Bookmark: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var title: String
    var urlString: String
    var dateAdded: Date

    init(id: UUID = UUID(), title: String, urlString: String, dateAdded: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.dateAdded = dateAdded
    }

    var url: URL? { URL(string: urlString) }
    var displayHost: String { url?.host() ?? urlString }
}
