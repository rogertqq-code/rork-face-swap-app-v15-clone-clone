import Foundation

nonisolated struct MediaDeviceEntry: Codable, Sendable, Identifiable {
    var id: String { deviceId + kind }
    var deviceId: String
    var groupId: String
    var kind: String
    var label: String
}

nonisolated struct MediaTrackSettings: Codable, Sendable {
    var deviceId: String
    var groupId: String
    var width: Int
    var height: Int
    var frameRate: Double
    var facingMode: String
    var aspectRatio: Double
    var resizeMode: String
}

nonisolated struct MediaTrackCapabilities: Codable, Sendable {
    var deviceId: String
    var groupId: String
    var widthMin: Int
    var widthMax: Int
    var heightMin: Int
    var heightMax: Int
    var frameRateMin: Double
    var frameRateMax: Double
    var facingModes: [String]
    var resizeModes: [String]
}

nonisolated struct MediaSnapshot: Codable, Sendable {
    var devices: [MediaDeviceEntry]
    var trackSettings: MediaTrackSettings?
    var trackCapabilities: MediaTrackCapabilities?
    var trackLabel: String
    var trackReadyState: String
    var trackContentHint: String
    var trackMuted: Bool
    var trackEnabled: Bool
    var supportedConstraints: [String]
    var mediaStreamId: String
    var mediaStreamActive: Bool
}

nonisolated struct MediaComparisonResult: Codable, Sendable {
    var field: String
    var realValue: String
    var processedValue: String
    var matches: Bool
}

nonisolated struct MediaTestResult: Codable, Sendable {
    var realSnapshot: MediaSnapshot
    var processedSnapshot: MediaSnapshot?
    var comparisons: [MediaComparisonResult]
    var matchPercentage: Double
}
