import Foundation

nonisolated enum CameraRequestSurface: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case webRTC
    case nativeCamera
    case liveSite

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .webRTC: "WebRTC"
        case .nativeCamera: "Native Camera"
        case .liveSite: "Live Site"
        }
    }
}

nonisolated enum CameraResponseMatchType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case exactNaturalMatch
    case closestDeviceMatch
    case browserLearned
    case nativeCameraMatch
    case profileDefault
    case custom

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .exactNaturalMatch: "Exact Natural Match"
        case .closestDeviceMatch: "Closest Device Match"
        case .browserLearned: "Browser Learned"
        case .nativeCameraMatch: "Native Camera Match"
        case .profileDefault: "Profile Default"
        case .custom: "Custom"
        }
    }
}

nonisolated struct CameraResponseRequest: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var target: RequestTarget
    var surface: CameraRequestSurface
    var requestedWidth: Int
    var requestedHeight: Int
    var requestedFrameRate: Int
    var sourceLabel: String

    init(
        target: RequestTarget,
        surface: CameraRequestSurface,
        requestedWidth: Int,
        requestedHeight: Int,
        requestedFrameRate: Int,
        sourceLabel: String
    ) {
        self.target = target
        self.surface = surface
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedFrameRate = requestedFrameRate
        self.sourceLabel = sourceLabel
        self.id = "\(target.rawValue)-\(surface.rawValue)-\(requestedWidth)x\(requestedHeight)-\(requestedFrameRate)-\(sourceLabel)"
    }

    nonisolated var requestedLabel: String {
        "\(requestedWidth)×\(requestedHeight) @ \(requestedFrameRate)fps"
    }
}

nonisolated struct CameraResponseResult: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var request: CameraResponseRequest
    var actualWidth: Int
    var actualHeight: Int
    var actualFrameRate: Int
    var matchType: CameraResponseMatchType
    var confidence: Double
    var cameraID: String?
    var cameraLabel: String?
    var notes: String
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        request: CameraResponseRequest,
        actualWidth: Int,
        actualHeight: Int,
        actualFrameRate: Int,
        matchType: CameraResponseMatchType,
        confidence: Double,
        cameraID: String? = nil,
        cameraLabel: String? = nil,
        notes: String = "",
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.actualWidth = actualWidth
        self.actualHeight = actualHeight
        self.actualFrameRate = actualFrameRate
        self.matchType = matchType
        self.confidence = confidence
        self.cameraID = cameraID
        self.cameraLabel = cameraLabel
        self.notes = notes
        self.capturedAt = capturedAt
    }

    nonisolated var actualLabel: String {
        "\(actualWidth)×\(actualHeight) @ \(actualFrameRate)fps"
    }

    nonisolated var isExact: Bool {
        actualWidth == request.requestedWidth && actualHeight == request.requestedHeight && abs(actualFrameRate - request.requestedFrameRate) <= 1
    }
}

nonisolated struct CameraResponseMap: Codable, Sendable, Hashable {
    var generatedAt: Date
    var results: [CameraResponseResult]

    init(generatedAt: Date = Date(), results: [CameraResponseResult] = []) {
        self.generatedAt = generatedAt
        self.results = results
    }

    nonisolated var frontResults: [CameraResponseResult] {
        results.filter { $0.request.target == .front }
    }

    nonisolated var backResults: [CameraResponseResult] {
        results.filter { $0.request.target == .back }
    }

    nonisolated var browserResults: [CameraResponseResult] {
        results.filter { $0.request.surface == .webRTC || $0.request.surface == .liveSite }
    }

    nonisolated var nativeResults: [CameraResponseResult] {
        results.filter { $0.request.surface == .nativeCamera }
    }

    nonisolated func bestMatch(target: RequestTarget, surface: CameraRequestSurface, requestedWidth: Int, requestedHeight: Int, frameRate: Int) -> CameraResponseResult? {
        let candidates = results.filter { result in
            (result.request.target == target || result.request.target == .any || target == .any) && result.request.surface == surface
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            responseDistance(lhs, requestedWidth: requestedWidth, requestedHeight: requestedHeight, frameRate: frameRate) < responseDistance(rhs, requestedWidth: requestedWidth, requestedHeight: requestedHeight, frameRate: frameRate)
        }
    }

    private nonisolated func responseDistance(_ result: CameraResponseResult, requestedWidth: Int, requestedHeight: Int, frameRate: Int) -> Int {
        let sizeDelta = abs((result.request.requestedWidth * result.request.requestedHeight) - (requestedWidth * requestedHeight))
        let aspectA = Double(result.request.requestedWidth) / Double(max(result.request.requestedHeight, 1))
        let aspectB = Double(requestedWidth) / Double(max(requestedHeight, 1))
        let aspectDelta = Int(abs(aspectA - aspectB) * 10_000)
        let fpsDelta = abs(result.request.requestedFrameRate - frameRate) * 2_000
        return sizeDelta + aspectDelta + fpsDelta
    }
}

nonisolated enum CameraRequestDimensionSource: String, Codable, Sendable, Hashable {
    case explicit
    case inferredFromWidth
    case inferredFromHeight
    case profileDefault

    nonisolated var label: String {
        switch self {
        case .explicit: "Requested by site"
        case .inferredFromWidth: "Inferred from requested width"
        case .inferredFromHeight: "Inferred from requested height"
        case .profileDefault: "Profile default"
        }
    }
}

nonisolated enum CameraRequestWarningKind: String, Codable, Sendable, Hashable, Identifiable {
    case partialDimensions
    case impossibleResolution
    case portraitLandscapeMismatch
    case frontMirror
    case audioRequested
    case failedRequest
    case noProfile

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .partialDimensions: "Partial dimensions"
        case .impossibleResolution: "Closest format used"
        case .portraitLandscapeMismatch: "Portrait / landscape mismatch"
        case .frontMirror: "Front camera mirror"
        case .audioRequested: "Audio requested"
        case .failedRequest: "Request failed"
        case .noProfile: "No active profile"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .partialDimensions: "yellow"
        case .impossibleResolution: "orange"
        case .portraitLandscapeMismatch: "orange"
        case .frontMirror: "cyan"
        case .audioRequested: "blue"
        case .failedRequest: "red"
        case .noProfile: "gray"
        }
    }
}

nonisolated struct CameraRequestWarning: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var kind: CameraRequestWarningKind
    var message: String

    init(id: UUID = UUID(), kind: CameraRequestWarningKind, message: String) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

nonisolated struct CameraRequestInsight: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var siteURL: String
    var host: String
    var timestamp: Date
    var target: RequestTarget
    var audioRequested: Bool
    var requestedWidth: Int?
    var requestedHeight: Int?
    var requestedFrameRate: Int?
    var predictedWidth: Int
    var predictedHeight: Int
    var predictedFrameRate: Int
    var dimensionSource: CameraRequestDimensionSource
    var predictedResponse: CameraResponseResult?
    var observedSettings: String
    var wasSuccessful: Bool
    var warnings: [CameraRequestWarning]
    var notes: String

    init(
        id: UUID = UUID(),
        siteURL: String,
        host: String,
        timestamp: Date,
        target: RequestTarget,
        audioRequested: Bool,
        requestedWidth: Int?,
        requestedHeight: Int?,
        requestedFrameRate: Int?,
        predictedWidth: Int,
        predictedHeight: Int,
        predictedFrameRate: Int,
        dimensionSource: CameraRequestDimensionSource,
        predictedResponse: CameraResponseResult? = nil,
        observedSettings: String,
        wasSuccessful: Bool,
        warnings: [CameraRequestWarning] = [],
        notes: String = ""
    ) {
        self.id = id
        self.siteURL = siteURL
        self.host = host
        self.timestamp = timestamp
        self.target = target
        self.audioRequested = audioRequested
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedFrameRate = requestedFrameRate
        self.predictedWidth = predictedWidth
        self.predictedHeight = predictedHeight
        self.predictedFrameRate = predictedFrameRate
        self.dimensionSource = dimensionSource
        self.predictedResponse = predictedResponse
        self.observedSettings = observedSettings
        self.wasSuccessful = wasSuccessful
        self.warnings = warnings
        self.notes = notes
    }

    nonisolated var requestedLabel: String {
        let size: String
        switch (requestedWidth, requestedHeight) {
        case let (.some(width), .some(height)): size = "\(width)×\(height)"
        case let (.some(width), .none): size = "width \(width), height automatic"
        case let (.none, .some(height)): size = "height \(height), width automatic"
        case (.none, .none): size = "default size"
        }
        let fps = requestedFrameRate.map { " @ \($0)fps" } ?? ""
        return size + fps
    }

    nonisolated var predictedLabel: String {
        "\(predictedWidth)×\(predictedHeight) @ \(predictedFrameRate)fps"
    }

    nonisolated var aspectLabel: String {
        let ratio = Double(predictedWidth) / Double(max(predictedHeight, 1))
        return String(format: "%.2f:1", ratio)
    }
}

nonisolated struct MediaImageAnalysisReport: Codable, Sendable, Hashable {
    var suggestedCrop: NormalizedCropRect
    var confidence: Double
    var faceCount: Int
    var textRegionCount: Int
    var humanRegionCount: Int
    var summary: String

    init(
        suggestedCrop: NormalizedCropRect = .full,
        confidence: Double = 0,
        faceCount: Int = 0,
        textRegionCount: Int = 0,
        humanRegionCount: Int = 0,
        summary: String = "Center-safe framing"
    ) {
        self.suggestedCrop = suggestedCrop
        self.confidence = confidence
        self.faceCount = faceCount
        self.textRegionCount = textRegionCount
        self.humanRegionCount = humanRegionCount
        self.summary = summary
    }
}
