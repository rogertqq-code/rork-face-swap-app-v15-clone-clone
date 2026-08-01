import Foundation

nonisolated enum MediaDeliveryRequestKind: String, Codable, Sendable, Hashable, CaseIterable {
    case webRTC
    case cordovaCamera
    case cordovaMediaCapture
    case capacitorCamera
    case htmlFileInput
    case customScheme
    case registeredSDK
}

nonisolated enum MediaDeliverySourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case webKitRealCapture
    case nativeCamera
    case nativeAudio
    case mockStill
    case mockVideo
    case mockAudio
}

nonisolated enum MediaFacingMode: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case environment
    case unspecified
}

nonisolated enum MediaAudioPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case notRequested
    case requiredReal
    case compatibilitySilentFallback
    case mockFixture
}

nonisolated enum MediaAudioOutcomeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case notRequested
    case realMicrophone
    case silentFallback
    case mockFixture
    case unavailable
}

nonisolated enum MediaRawSampleModeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case firstFrame
    case everyNthFrame
    case allFrames
}

nonisolated struct MediaRawSampleMode: Codable, Sendable, Hashable {
    var kind: MediaRawSampleModeKind
    var interval: Int?

    init(kind: MediaRawSampleModeKind = .off, interval: Int? = nil) {
        self.kind = kind
        self.interval = kind == .everyNthFrame ? max(1, interval ?? 1) : nil
    }
}

nonisolated struct MediaAudioOutcome: Codable, Sendable, Hashable {
    var kind: MediaAudioOutcomeKind
    var reason: String?

    init(kind: MediaAudioOutcomeKind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }
}

nonisolated struct MediaDimensions: Codable, Sendable, Hashable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

nonisolated struct MediaDeliveryConstraints: Codable, Sendable, Hashable {
    var wantsVideo: Bool
    var wantsAudio: Bool
    var facingMode: MediaFacingMode
    var dimensions: MediaDimensions?
    var frameRate: Double?
    var deviceID: String?
    var audioPolicy: MediaAudioPolicy

    init(
        wantsVideo: Bool,
        wantsAudio: Bool,
        facingMode: MediaFacingMode = .unspecified,
        dimensions: MediaDimensions? = nil,
        frameRate: Double? = nil,
        deviceID: String? = nil,
        audioPolicy: MediaAudioPolicy = .notRequested
    ) {
        self.wantsVideo = wantsVideo
        self.wantsAudio = wantsAudio
        self.facingMode = facingMode
        self.dimensions = dimensions
        self.frameRate = frameRate.map { max(1, $0) }
        self.deviceID = deviceID
        if !wantsAudio {
            self.audioPolicy = .notRequested
        } else if audioPolicy == .notRequested {
            self.audioPolicy = .compatibilitySilentFallback
        } else {
            self.audioPolicy = audioPolicy
        }
    }
}

nonisolated struct MediaDeliveryRequest: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var navigationSessionID: String
    var origin: String
    var kind: MediaDeliveryRequestKind
    var constraints: MediaDeliveryConstraints
    var createdAt: Date
    var deadline: Date
    var adapterVersion: String?
    var rawSampleMode: MediaRawSampleMode

    init(
        id: UUID = UUID(),
        navigationSessionID: String,
        origin: String,
        kind: MediaDeliveryRequestKind,
        constraints: MediaDeliveryConstraints,
        createdAt: Date = Date(),
        timeout: TimeInterval = 20,
        adapterVersion: String? = nil,
        rawSampleMode: MediaRawSampleMode = MediaRawSampleMode()
    ) {
        self.id = id
        self.navigationSessionID = navigationSessionID
        self.origin = origin
        self.kind = kind
        self.constraints = constraints
        self.createdAt = createdAt
        self.deadline = createdAt.addingTimeInterval(max(1, timeout))
        self.adapterVersion = adapterVersion
        self.rawSampleMode = rawSampleMode
    }
}

nonisolated struct MediaSourceDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var kind: MediaDeliverySourceKind
    var contentType: String
    var resourceURL: URL
    var filename: String?
    var dimensions: MediaDimensions?
    var duration: TimeInterval?
    var isMock: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaDeliverySourceKind,
        contentType: String,
        resourceURL: URL,
        filename: String? = nil,
        dimensions: MediaDimensions? = nil,
        duration: TimeInterval? = nil,
        isMock: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.contentType = contentType
        self.resourceURL = resourceURL
        self.filename = filename
        self.dimensions = dimensions
        self.duration = duration
        self.isMock = isMock
        self.createdAt = createdAt
    }
}

nonisolated enum MediaAdapterKind: String, Codable, Sendable, Hashable, CaseIterable {
    case cordovaCamera
    case cordovaMediaCapture
    case capacitorCamera
    case htmlFileInput
    case customScheme
    case registeredSDK
}

nonisolated enum MediaAdapterResultKind: String, Codable, Sendable, Hashable, CaseIterable {
    case fileURL
    case webPath
    case dataURL
    case mediaFiles
    case unsupported
}

nonisolated struct MediaAdapterResource: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var url: URL
    var filename: String
    var mimeType: String
    var byteCount: Int?
    var duration: TimeInterval?

    init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        mimeType: String,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.duration = duration
    }
}

nonisolated struct MediaAdapterResult: Codable, Sendable, Hashable {
    var requestID: UUID
    var adapter: MediaAdapterKind
    var kind: MediaAdapterResultKind
    var resources: [MediaAdapterResource]
    var validatedResultShape: Bool
    var degradedReason: String?

    init(
        requestID: UUID,
        adapter: MediaAdapterKind,
        kind: MediaAdapterResultKind,
        resources: [MediaAdapterResource] = [],
        validatedResultShape: Bool,
        degradedReason: String? = nil
    ) {
        self.requestID = requestID
        self.adapter = adapter
        self.kind = kind
        self.resources = resources
        self.validatedResultShape = validatedResultShape
        self.degradedReason = degradedReason
    }
}

nonisolated enum MediaDeliveryStage: String, Codable, Sendable, Hashable, CaseIterable {
    case created
    case sourceResolving
    case sourceReady
    case signaling
    case delivering
    case active
    case degraded
    case cancelling
    case cancelled
    case stopped
    case failed
}

nonisolated enum MediaDeliveryTerminalReason: String, Codable, Sendable, Hashable, CaseIterable {
    case completed
    case callerStopped
    case navigationReplaced
    case backgrounded
    case interrupted
    case timedOut
    case cancelled
    case unsupported
    case failed
}

nonisolated struct MediaDeliveryTraceEvent: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var requestID: UUID
    var navigationSessionID: String
    var origin: String
    var stage: MediaDeliveryStage
    var timestamp: Date
    var sourceKind: MediaDeliverySourceKind?
    var adapter: MediaAdapterKind?
    var audioOutcome: MediaAudioOutcome?
    var terminalReason: MediaDeliveryTerminalReason?
    var detail: String?
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        requestID: UUID,
        navigationSessionID: String,
        origin: String,
        stage: MediaDeliveryStage,
        timestamp: Date = Date(),
        sourceKind: MediaDeliverySourceKind? = nil,
        adapter: MediaAdapterKind? = nil,
        audioOutcome: MediaAudioOutcome? = nil,
        terminalReason: MediaDeliveryTerminalReason? = nil,
        detail: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.requestID = requestID
        self.navigationSessionID = navigationSessionID
        self.origin = origin
        self.stage = stage
        self.timestamp = timestamp
        self.sourceKind = sourceKind
        self.adapter = adapter
        self.audioOutcome = audioOutcome
        self.terminalReason = terminalReason
        self.detail = detail
        self.metadata = metadata
    }
}

nonisolated enum MediaDeliveryContractError: Error, LocalizedError, Codable, Sendable, Hashable {
    case invalidRequest(String)
    case sourceUnavailable(String)
    case adapterUnsupported(String)
    case adapterResultInvalid(String)
    case timedOut
    case cancelled(String)
    case signalingFailed(String)
    case deliveryFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid media request: \(detail)"
        case .sourceUnavailable(let detail): "Media source unavailable: \(detail)"
        case .adapterUnsupported(let detail): "Media adapter unsupported: \(detail)"
        case .adapterResultInvalid(let detail): "Media adapter returned an invalid result: \(detail)"
        case .timedOut: "The media request timed out."
        case .cancelled(let detail): "The media request was cancelled: \(detail)"
        case .signalingFailed(let detail): "WebRTC signaling failed: \(detail)"
        case .deliveryFailed(let detail): "Media delivery failed: \(detail)"
        }
    }
}

protocol MediaSourceResolving: Sendable {
    func resolveSource(for request: MediaDeliveryRequest) async throws -> MediaSourceDescriptor
}

protocol MediaAdapterServing: Sendable {
    func serve(
        adapter: MediaAdapterKind,
        request: MediaDeliveryRequest,
        source: MediaSourceDescriptor
    ) async throws -> MediaAdapterResult
}

protocol MediaDeliveryEventRecording: Sendable {
    func record(_ event: MediaDeliveryTraceEvent) async
}

protocol MediaDeliveryCancelling: Sendable {
    func cancel(requestID: UUID, reason: MediaDeliveryTerminalReason) async
}
