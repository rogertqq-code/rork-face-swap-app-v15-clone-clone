import Foundation

// MARK: - Fingerprint Baseline Spec

nonisolated struct FingerprintBaselineSpec: Codable, Sendable {
    var audioFingerprint: Double?
    var canvasHash: String?
    var webglHash: String?
    var webglExtensionsHash: String?
    var screenWidth: Int
    var screenHeight: Int
    var screenFrameTop: Int
    var screenFrameBottom: Int
    var screenFrameLeft: Int
    var screenFrameRight: Int
    var hardwareConcurrency: Int
    var capturedAt: Date

    init(
        audioFingerprint: Double? = nil,
        canvasHash: String? = nil,
        webglHash: String? = nil,
        webglExtensionsHash: String? = nil,
        screenWidth: Int = 0,
        screenHeight: Int = 0,
        screenFrameTop: Int = 0,
        screenFrameBottom: Int = 0,
        screenFrameLeft: Int = 0,
        screenFrameRight: Int = 0,
        hardwareConcurrency: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.audioFingerprint = audioFingerprint
        self.canvasHash = canvasHash
        self.webglHash = webglHash
        self.webglExtensionsHash = webglExtensionsHash
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenFrameTop = screenFrameTop
        self.screenFrameBottom = screenFrameBottom
        self.screenFrameLeft = screenFrameLeft
        self.screenFrameRight = screenFrameRight
        self.hardwareConcurrency = hardwareConcurrency
        self.capturedAt = capturedAt
    }
}

// MARK: - Fingerprint Consistency Result

nonisolated struct FingerprintConsistencyResult: Codable, Sendable, Identifiable {
    var id: UUID
    var field: String
    var values: [String]
    var isConsistent: Bool
    var timestamp: Date

    init(
        id: UUID = UUID(),
        field: String = "",
        values: [String] = [],
        isConsistent: Bool = true,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.field = field
        self.values = values
        self.isConsistent = isConsistent
        self.timestamp = timestamp
    }
}
