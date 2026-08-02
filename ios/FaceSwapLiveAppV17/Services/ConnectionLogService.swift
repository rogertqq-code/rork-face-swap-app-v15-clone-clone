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
        // E-05: Redact page-originated diagnostic strings before export.
        // Messages are capped at 200 chars and URL-like patterns are masked.
        return entries.map { redactedLine($0) }.joined(separator: "\n")
    }

    /// Redacts a single entry for export: caps message length and masks URLs.
    private func redactedLine(_ entry: Entry) -> String {
        var msg = entry.message
        if msg.count > 200 {
            msg = String(msg.prefix(197)) + "..."
        }
        if let regex = try? NSRegularExpression(pattern: "https?://\\S+|fsl\\w+://\\S+", options: []) {
            let range = NSRange(msg.startIndex..., in: msg)
            msg = regex.stringByReplacingMatches(in: msg, options: [], range: range, withTemplate: "[url]")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "[\(formatter.string(from: entry.timestamp))] [\(entry.category.rawValue.uppercased())] \(msg)"
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

    // E-03: The flush timer fires on a background queue but all state it
    // touches (entries, lastFlushedCount) is MainActor-isolated. The
    // @Sendable event handler explicitly hops to MainActor via Task before
    // reading or writing any isolated state, so no actor boundary is crossed
    // without an explicit hop. The timer source itself is stored on the main
    // actor and configured from the main actor; only its firing happens off-actor.
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

    private var lastFlushedCount: Int = 0

    private func flushToFile(logURL: URL, maxFileSize: Int) {
        // Only write entries that haven't been flushed yet (delta flush).
        let newEntries = entries.suffix(from: lastFlushedCount)
        guard !newEntries.isEmpty else { return }
        let delta = newEntries.map(\.formattedLine).joined(separator: "\n")
        lastFlushedCount = entries.count

        // E-02: Rotate if the existing file is too large BEFORE appending,
        // and cap the delta size so a single flush cannot exceed the limit.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            try? FileManager.default.removeItem(at: logURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? delta.data(using: .utf8)?.write(to: logURL)
        } else {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                try? handle.seekToEnd()
                let newline = "\n\(delta)"
                if let data = newline.data(using: .utf8) {
                    try? handle.write(data)
                }
                try? handle.close()
            }
        }

        // E-02: Post-write rotation check — if the file exceeded the limit
        // after this append, rotate now so the next cycle starts clean.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private func loadExistingEntries() {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return }
        // Parse previously persisted lines back into in-memory entries so the
        // session history survives an app restart. Cap at maxEntries so a
        // large persisted log cannot exceed the in-memory bound on startup.
        let lines = text.split(separator: "\n")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed: [Entry] = []
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
            parsed.append(Entry(timestamp: date, category: category, message: message))
        }
        // E-02: Enforce the in-memory cap on loaded entries.
        if parsed.count > maxEntries {
            parsed = Array(parsed.suffix(maxEntries))
        }
        entries = parsed
        lastFlushedCount = entries.count
    }
}
