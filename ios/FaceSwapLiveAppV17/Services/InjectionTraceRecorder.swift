import Foundation
import Observation

/// Records the exact stage at which a camera request failed to deliver media.
///
/// Off by default: while disabled nothing is captured, nothing is stored, and
/// the page-side reporter stays silent. It exists so an injection regression is
/// pinpointed from evidence instead of guessed at from behaviour.
@MainActor
@Observable
final class InjectionTraceRecorder {
    static let shared = InjectionTraceRecorder()

    static let maximumRecords = 60

    private let enabledKey = "injection_failure_recorder_enabled_v1"
    private let recordsKey = "injection_failure_records_v1"
    private let defaults: UserDefaults

    /// Master switch. Turning it off clears nothing, but stops all capture.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: enabledKey)
        }
    }

    private(set) var records: [InjectionTraceRecord] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: enabledKey)
        if let data = defaults.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([InjectionTraceRecord].self, from: data) {
            records = decoded
        }
    }

    /// Records one failure. Ignored entirely while the switch is off.
    func record(
        stage: InjectionTraceStage,
        surface: InjectionTraceSurface = .unknown,
        reason: String = "",
        detail: String = "",
        host: String = "",
        method: String = "",
        requestID: String? = nil,
        navigationSessionID: String? = nil,
        sequenceVersion: Int? = nil,
        frameTimestampOffsetMs: Double? = nil
    ) {
        guard isEnabled else { return }
        let entry = InjectionTraceRecord(
            stage: stage,
            surface: surface,
            reason: reason,
            detail: detail,
            host: host,
            method: method,
            requestID: requestID,
            navigationSessionID: navigationSessionID,
            sequenceVersion: sequenceVersion,
            frameTimestampOffsetMs: frameTimestampOffsetMs
        )
        records.insert(entry, at: 0)
        if records.count > Self.maximumRecords {
            records = Array(records.prefix(Self.maximumRecords))
        }
        persist()
    }

    /// Accepts a raw page-side report. Unknown stages are dropped rather than
    /// guessed at, so the log never contains an invented failure. When supplied,
    /// WebKit-derived context replaces untrusted page-reported origin fields.
    func recordFromPage(_ body: [String: Any], context: MediaBridgeContext? = nil) {
        guard isEnabled else { return }
        guard let stageRaw = body["stage"] as? String,
              let stage = InjectionTraceStage(rawValue: stageRaw) else { return }
        let surface = InjectionTraceSurface(rawValue: body["surface"] as? String ?? "") ?? .unknown
        let trustedHost: String
        if let context,
           let host = URL(string: context.origin)?.host {
            trustedHost = host
        } else {
            trustedHost = body["host"] as? String ?? ""
        }
        let frameOffset = (body["frameOffsetMs"] as? NSNumber)?.doubleValue
        let sequenceVersion = (body["sequenceVersion"] as? NSNumber)?.intValue ?? (body["sequenceVersion"] as? Int)
        record(
            stage: stage,
            surface: surface,
            reason: body["reason"] as? String ?? "",
            detail: body["detail"] as? String ?? "",
            host: trustedHost,
            method: body["method"] as? String ?? "",
            requestID: body["requestId"] as? String,
            navigationSessionID: context?.navigationSessionID ?? (body["session"] as? String),
            sequenceVersion: sequenceVersion,
            frameTimestampOffsetMs: frameOffset
        )
    }

    func clear() {
        records.removeAll()
        defaults.removeObject(forKey: recordsKey)
    }

    /// The most recent failure, used for the at-a-glance line in Site Check.
    var latest: InjectionTraceRecord? { records.first }

    /// Groups recent failures by stage so a repeating root cause stands out.
    var stageTally: [(stage: InjectionTraceStage, count: Int)] {
        let counts = Dictionary(grouping: records, by: \.stage).mapValues(\.count)
        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.order < rhs.key.order : lhs.value > rhs.value
            }
            .map { (stage: $0.key, count: $0.value) }
    }

    var exportText: String {
        guard !records.isEmpty else { return "No injection failures recorded." }
        var lines = ["Injection failure log (\(records.count) most recent)", ""]
        lines.append(contentsOf: records.map(\.exportLine))
        return lines.joined(separator: "\n")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }
}
