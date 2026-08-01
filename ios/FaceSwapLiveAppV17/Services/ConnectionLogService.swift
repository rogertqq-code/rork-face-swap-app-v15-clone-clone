import Foundation

/// Records initialization steps and errors from the camera-injection pipeline
/// to a rotating file log so connection issues can be diagnosed after the fact.
///
/// The log is always on (no opt-in needed) and writes to the app's Caches
/// directory so it is never backed up or synced. Entries are capped at a
/// generous limit and the file is rotated once it exceeds 256 KB so it never
/// grows unbounded.
@MainActor
final class ConnectionLogService {
    static let shared = ConnectionLogService()

    private let queue = DispatchQueue(label: "com.app.connection-log")
    private let logURL: URL
    private let maxFileSize: Int = 256 * 1024
    private let maxEntries: Int = 800

    private(set) var entries: [Entry] = []
    private var flushTimer: DispatchSourceTimer?

    /// Entry categories so the log is skimmable.
    enum Category: String, Sendable {
        case navigation
        case mediaActivation
        case engineArm
        case runtimeState
        case lifecycle
        case request
        case error
        case info
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String
        var formattedLine: String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return "[\(formatter.string(from: timestamp))] [\(category.rawValue.uppercased())] \(message)"
        }
    }

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        logURL = cachesDir.appendingPathComponent("fsl_connection_log.txt")
        loadExistingEntries()
        startFlushTimer()
    }

    // MARK: - Public logging API

    func log(_ category: Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func info(_ message: String) { log(.info, message) }
    func error(_ message: String) { log(.error, message) }

    func clear() {
        entries.removeAll()
        queue.async { [logURL] in
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    /// Returns the full log as plain text, one entry per line.
    var exportText: String {
        guard !entries.isEmpty else { return "No connection log entries recorded." }
        return entries.map(\.formattedLine).joined(separator: "\n")
    }

    /// Writes the current log to a temporary file and returns its URL for
    /// sharing via the iOS share sheet.
    func exportToFile() -> URL? {
        let text = exportText
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "fsl_connection_log_\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// The most recent error entry, if any.
    var latestError: Entry? {
        entries.last(where: { $0.category == .error })
    }

    /// Entries filtered to a specific category.
    func entries(for category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }

    // MARK: - File persistence

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3))
        timer.setEventHandler { [weak self, logURL, maxFileSize] in
            Task { @MainActor in
                self?.flushToFile(logURL: logURL, maxFileSize: maxFileSize)
            }
        }
        timer.resume()
        flushTimer = timer
    }

    private func flushToFile(logURL: URL, maxFileSize: Int) {
        let snapshot = entries.map(\.formattedLine).joined(separator: "\n")
        guard !snapshot.isEmpty else { return }

        // Rotate if the existing file is too large.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            try? FileManager.default.removeItem(at: logURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? snapshot.data(using: .utf8)?.write(to: logURL)
        } else {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                try? handle.seekToEnd()
                let newline = "\n\(snapshot)\n"
                if let data = newline.data(using: .utf8) {
                    try? handle.write(data)
                }
                try? handle.close()
            }
        }
    }

    private func loadExistingEntries() {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return }
        // Parse previously persisted lines back into in-memory entries so the
        // session history survives an app restart.
        let lines = text.split(separator: "\n")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            // Expected format: [timestamp] [CATEGORY] message
            guard line.hasPrefix("[") else { continue }
            let afterFirstBracket = line.dropFirst()
            guard let closeIdx = afterFirstBracket.firstIndex(of: "]") else { continue }
            let timestampStr = String(afterFirstBracket[..<closeIdx])
            let rest = afterFirstBracket[afterFirstBracket.index(after: closeIdx)...]
            // Category
            guard rest.hasPrefix(" [") else { continue }
            let afterCatBracket = rest.dropFirst(2)
            guard let catClose = afterCatBracket.firstIndex(of: "]") else { continue }
            let catStr = String(afterCatBracket[..<catClose]).lowercased()
            let message = String(afterCatBracket[afterCatBracket.index(after: catClose)...]).trimmingCharacters(in: .whitespaces)
            let category = Category(rawValue: catStr) ?? .info
            let date = formatter.date(from: timestampStr) ?? Date()
            entries.append(Entry(timestamp: date, category: category, message: message))
        }
    }
}
