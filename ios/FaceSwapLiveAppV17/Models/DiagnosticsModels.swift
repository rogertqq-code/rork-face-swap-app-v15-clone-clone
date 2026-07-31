import Foundation

// MARK: - Live Session Diagnostics

nonisolated struct LiveSessionDiagnostics: Codable, Sendable {
    var activeWidth: Int
    var activeHeight: Int
    var aspectRatio: String
    var fps: Double
    var colorSpace: String
    var orientation: String
    var isMirrored: Bool
    var isHDR: Bool
    var stabilizationMode: String
    var timestamp: Date

    init(
        activeWidth: Int = 0,
        activeHeight: Int = 0,
        aspectRatio: String = "",
        fps: Double = 0,
        colorSpace: String = "",
        orientation: String = "",
        isMirrored: Bool = false,
        isHDR: Bool = false,
        stabilizationMode: String = "off",
        timestamp: Date = Date()
    ) {
        self.activeWidth = activeWidth
        self.activeHeight = activeHeight
        self.aspectRatio = aspectRatio
        self.fps = fps
        self.colorSpace = colorSpace
        self.orientation = orientation
        self.isMirrored = isMirrored
        self.isHDR = isHDR
        self.stabilizationMode = stabilizationMode
        self.timestamp = timestamp
    }
}

// MARK: - Requested vs Actual Capture

nonisolated struct CaptureComparisonReport: Codable, Sendable {
    var requestedWidth: Int
    var requestedHeight: Int
    var requestedFrameRate: Double
    var requestedFacingMode: String
    var requestedDeviceId: String

    var actualWidth: Int
    var actualHeight: Int
    var actualFrameRate: Double
    var actualFacingMode: String
    var actualDeviceId: String

    var timestamp: Date

    init(
        requestedWidth: Int = 0, requestedHeight: Int = 0,
        requestedFrameRate: Double = 0, requestedFacingMode: String = "",
        requestedDeviceId: String = "",
        actualWidth: Int = 0, actualHeight: Int = 0,
        actualFrameRate: Double = 0, actualFacingMode: String = "",
        actualDeviceId: String = "",
        timestamp: Date = Date()
    ) {
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedFrameRate = requestedFrameRate
        self.requestedFacingMode = requestedFacingMode
        self.requestedDeviceId = requestedDeviceId
        self.actualWidth = actualWidth
        self.actualHeight = actualHeight
        self.actualFrameRate = actualFrameRate
        self.actualFacingMode = actualFacingMode
        self.actualDeviceId = actualDeviceId
        self.timestamp = timestamp
    }
}

// MARK: - Constraint Log

nonisolated struct ConstraintLogEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var siteURL: String
    var requestedConstraints: String
    var negotiatedResult: String
    var fallbackReason: String?
    var wasSuccessful: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        siteURL: String = "",
        requestedConstraints: String = "",
        negotiatedResult: String = "",
        fallbackReason: String? = nil,
        wasSuccessful: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.siteURL = siteURL
        self.requestedConstraints = requestedConstraints
        self.negotiatedResult = negotiatedResult
        self.fallbackReason = fallbackReason
        self.wasSuccessful = wasSuccessful
    }
}

// MARK: - Media Metadata Inspector

nonisolated struct MediaMetadataReport: Codable, Sendable {
    var container: String
    var videoCodec: String
    var videoBitrate: Int
    var videoFrameRate: Double
    var keyframeInterval: Int
    var pixelFormat: String
    var rotationDegrees: Int
    var videoWidth: Int
    var videoHeight: Int

    var hasAudio: Bool
    var audioCodec: String
    var audioBitrate: Int
    var audioSampleRate: Double
    var audioChannels: Int

    var colorPrimaries: String
    var transferFunction: String
    var colorMatrix: String
    var isFullRange: Bool
    var isHDR: Bool

    init(
        container: String = "", videoCodec: String = "", videoBitrate: Int = 0,
        videoFrameRate: Double = 0, keyframeInterval: Int = 0, pixelFormat: String = "",
        rotationDegrees: Int = 0, videoWidth: Int = 0, videoHeight: Int = 0,
        hasAudio: Bool = false, audioCodec: String = "", audioBitrate: Int = 0,
        audioSampleRate: Double = 0, audioChannels: Int = 0,
        colorPrimaries: String = "", transferFunction: String = "", colorMatrix: String = "",
        isFullRange: Bool = false, isHDR: Bool = false
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.videoBitrate = videoBitrate
        self.videoFrameRate = videoFrameRate
        self.keyframeInterval = keyframeInterval
        self.pixelFormat = pixelFormat
        self.rotationDegrees = rotationDegrees
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.hasAudio = hasAudio
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.colorMatrix = colorMatrix
        self.isFullRange = isFullRange
        self.isHDR = isHDR
    }
}

// MARK: - Conformance Score

nonisolated struct MediaConformanceScore: Codable, Sendable {
    var overallScore: Double
    var resolutionMatch: Bool
    var fpsMatch: Bool
    var codecMatch: Bool
    var bitrateMatch: Bool
    var orientationMatch: Bool
    var audioMatch: Bool
    var details: [String]

    init(
        overallScore: Double = 0, resolutionMatch: Bool = false,
        fpsMatch: Bool = false, codecMatch: Bool = false,
        bitrateMatch: Bool = false, orientationMatch: Bool = false,
        audioMatch: Bool = false, details: [String] = []
    ) {
        self.overallScore = overallScore
        self.resolutionMatch = resolutionMatch
        self.fpsMatch = fpsMatch
        self.codecMatch = codecMatch
        self.bitrateMatch = bitrateMatch
        self.orientationMatch = orientationMatch
        self.audioMatch = audioMatch
        self.details = details
    }
}

// MARK: - Frame Timing / Drift

nonisolated struct FrameTimingSample: Codable, Sendable {
    var timestamp: Double
    var delta: Double
    var isDuplicate: Bool
    var isJitter: Bool
}

nonisolated struct DriftReport: Codable, Sendable {
    var averageFPS: Double
    var minDelta: Double
    var maxDelta: Double
    var jitterCount: Int
    var duplicateCount: Int
    var totalFrames: Int
    var samples: [FrameTimingSample]

    init(
        averageFPS: Double = 0, minDelta: Double = 0, maxDelta: Double = 0,
        jitterCount: Int = 0, duplicateCount: Int = 0, totalFrames: Int = 0,
        samples: [FrameTimingSample] = []
    ) {
        self.averageFPS = averageFPS
        self.minDelta = minDelta
        self.maxDelta = maxDelta
        self.jitterCount = jitterCount
        self.duplicateCount = duplicateCount
        self.totalFrames = totalFrames
        self.samples = samples
    }
}

// MARK: - Injection feed engine status

/// Plain-language descriptions for which feed engine actually engaged and why a
/// clean-feed method ever downgraded. Shared by Diagnostics, the self-test, and
/// the live method readout so the wording stays consistent everywhere.
nonisolated enum InjectionFeed {
    /// Which underlying feed engine actually engaged.
    static func feedLabel(_ raw: String) -> String {
        switch raw {
        case "vtg": return "Clean background track"
        case "canvas": return "Canvas feed"
        default: return "Not engaged yet"
        }
    }

    /// Plain-language reason for a downgrade or an intentional Canvas draw.
    static func reasonText(_ code: String) -> String {
        switch code {
        case "device-unsupported": return "This browser doesn't support the clean background feed (needs iOS 18 or later)."
        case "site-blocked-worker": return "This site's security rules blocked the clean background feed from starting."
        case "media-load": return "Your selected media couldn't be loaded into the clean feed."
        case "no-frames": return "The clean feed started but didn't deliver real frames in time."
        case "photo-step": return "This step is a still photo — the clean feed streams video, so the Canvas draw is used for photos."
        case "private-lane-fallback": return "The private lane refused this page, so the clean in-page track is live instead."
        case "unknown": return "The clean feed couldn't start, so the Canvas feed is used."
        default: return ""
        }
    }
}

/// A snapshot of the live injection feed: which method was selected, which feed
/// engine actually engaged, and whether/why it downgraded to Canvas.
nonisolated struct FeedEngineStatus: Codable, Sendable {
    var active: Bool
    var method: String
    var feed: String
    /// Delivery lane for clean feeds: "private" only when Private Lane truly carried the track.
    var lane: String
    var intended: String
    var downgraded: Bool
    var reason: String
    /// Whether the in-page camera-takeover interception is genuinely installed.
    /// When false while `active` is true, the site is receiving the REAL camera.
    var armed: Bool = true
    /// Reason the takeover failed to arm, when `armed` is false.
    var armError: String = ""
    /// Round 2: whether the sensor-realism layer (capture-clock timing + grain)
    /// toggle is currently on.
    var sensorRealismEnabled: Bool = false
    /// Round 2: whether the active clean feed has a drawing surface (so grain can
    /// blend). False for the raw video-element fallback, which skips grain.
    var sensorCanvasFeed: Bool = false

    var isClean: Bool { feed == "vtg" }
    var isCanvas: Bool { feed == "canvas" }
    var isPrivateLane: Bool { isClean && lane == "private" }
    var feedLabel: String { isPrivateLane ? "Clean background track · private lane" : InjectionFeed.feedLabel(feed) }
    var methodLabel: String { InjectionMethodKind(rawValue: method)?.migratedCameraMethod.label ?? "Current method" }
    var intendedLabel: String { InjectionMethodKind(rawValue: intended.isEmpty ? method : intended)?.migratedCameraMethod.label ?? methodLabel }
    /// True when a clean-feed-capable method is the one the user selected.
    var intendedClean: Bool {
        let selected = intended.isEmpty ? method : intended
        return selected == "rawFramePipe" || selected == "privateLane"
    }
    /// Intentional Canvas draw for a photo under clean-feed methods (not a failure).
    var isIntentionalCanvas: Bool { reason == "photo-step" }
    /// Private Lane could not carry the stream, but the in-page clean track did.
    var isPrivateLaneFallback: Bool { method == "privateLane" && isClean && lane != "private" && reason == "private-lane-fallback" }
    var reasonText: String { InjectionFeed.reasonText(reason) }
    /// The engine is active but the camera takeover isn't installed — the exact
    /// failure that lets every method pass the real camera through.
    var isActiveButUnarmed: Bool { active && !armed }

    // MARK: - Sensor realism (Round 2)

    /// Capture-clock timing runs on any live clean feed when the toggle is on.
    var sensorTimingEngaged: Bool { isClean && sensorRealismEnabled }
    /// Grain / PRNU needs both the toggle on and a drawing-surface clean feed.
    var sensorGrainEngaged: Bool { isClean && sensorRealismEnabled && sensorCanvasFeed }
    /// Plain-language summary for the live status row.
    var sensorRealismSummary: String {
        guard isClean else { return "Not on a clean feed" }
        if !sensorRealismEnabled { return "Off — plain decoded frames" }
        if sensorCanvasFeed { return "Capture-clock timing + per-frame grain" }
        return "Capture-clock timing · grain skipped (raw feed)"
    }
}

// MARK: - Orientation / Transform

nonisolated struct OrientationDebugInfo: Codable, Sendable {
    var deviceOrientation: String
    var videoOrientation: String
    var isMirrored: Bool
    var rotationDegrees: Int
    var displayMatrixDescription: String
    var cropRect: String
    var cleanAperture: String

    init(
        deviceOrientation: String = "", videoOrientation: String = "",
        isMirrored: Bool = false, rotationDegrees: Int = 0,
        displayMatrixDescription: String = "", cropRect: String = "",
        cleanAperture: String = ""
    ) {
        self.deviceOrientation = deviceOrientation
        self.videoOrientation = videoOrientation
        self.isMirrored = isMirrored
        self.rotationDegrees = rotationDegrees
        self.displayMatrixDescription = displayMatrixDescription
        self.cropRect = cropRect
        self.cleanAperture = cleanAperture
    }
}

// MARK: - Preview vs Output Comparison

nonisolated struct PreviewVsOutputReport: Codable, Sendable {
    var previewWidth: Int
    var previewHeight: Int
    var encodedWidth: Int
    var encodedHeight: Int
    var isCropped: Bool
    var cropDescription: String

    init(
        previewWidth: Int = 0, previewHeight: Int = 0,
        encodedWidth: Int = 0, encodedHeight: Int = 0,
        isCropped: Bool = false, cropDescription: String = ""
    ) {
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.isCropped = isCropped
        self.cropDescription = cropDescription
    }
}

// MARK: - Audio Route Profile

nonisolated struct AudioRouteProfile: Codable, Sendable {
    var inputRoute: String
    var sampleRate: Double
    var channelCount: Int
    var bitDepth: Int
    var echoCancellation: Bool
    var audioSessionMode: String
    var ioBufferDuration: Double

    init(
        inputRoute: String = "", sampleRate: Double = 0,
        channelCount: Int = 0, bitDepth: Int = 0,
        echoCancellation: Bool = false, audioSessionMode: String = "",
        ioBufferDuration: Double = 0
    ) {
        self.inputRoute = inputRoute
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.echoCancellation = echoCancellation
        self.audioSessionMode = audioSessionMode
        self.ioBufferDuration = ioBufferDuration
    }
}

// MARK: - Lighting / Exposure Telemetry

nonisolated struct ExposureTelemetry: Codable, Sendable {
    var iso: Float
    var shutterSpeed: String
    var whiteBalance: String
    var exposureBias: Float
    var torchState: String
    var focusMode: String
    var exposureMode: String

    init(
        iso: Float = 0, shutterSpeed: String = "",
        whiteBalance: String = "", exposureBias: Float = 0,
        torchState: String = "off", focusMode: String = "",
        exposureMode: String = ""
    ) {
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.whiteBalance = whiteBalance
        self.exposureBias = exposureBias
        self.torchState = torchState
        self.focusMode = focusMode
        self.exposureMode = exposureMode
    }
}

// MARK: - Site History

nonisolated struct SiteHistoryEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var siteURL: String
    var timestamp: Date
    var requestedConstraints: String
    var actualSettings: String
    var profileUsed: String
    var wasSuccessful: Bool

    init(
        id: UUID = UUID(),
        siteURL: String = "",
        timestamp: Date = Date(),
        requestedConstraints: String = "",
        actualSettings: String = "",
        profileUsed: String = "",
        wasSuccessful: Bool = true
    ) {
        self.id = id
        self.siteURL = siteURL
        self.timestamp = timestamp
        self.requestedConstraints = requestedConstraints
        self.actualSettings = actualSettings
        self.profileUsed = profileUsed
        self.wasSuccessful = wasSuccessful
    }
}

// MARK: - Transcode Progress Phase

nonisolated enum TranscodePhase: String, Codable, Sendable, CaseIterable {
    case analysis = "Analysis"
    case audioPrep = "Audio Prep"
    case videoEncode = "Video Encode"
    case muxing = "Muxing"
    case verification = "Verification"
    case librarySave = "Library Save"
}

nonisolated struct TranscodeProgress: Codable, Sendable {
    var currentPhase: TranscodePhase
    var phaseProgress: Double
    var overallProgress: Double
    var phaseDetails: String

    init(
        currentPhase: TranscodePhase = .analysis,
        phaseProgress: Double = 0,
        overallProgress: Double = 0,
        phaseDetails: String = ""
    ) {
        self.currentPhase = currentPhase
        self.phaseProgress = phaseProgress
        self.overallProgress = overallProgress
        self.phaseDetails = phaseDetails
    }
}

// MARK: - Debug Bundle

nonisolated struct DebugBundle: Codable, Sendable {
    var exportDate: Date
    var deviceProfile: String
    var sessionDiagnostics: String
    var constraintLogs: [ConstraintLogEntry]
    var mediaMetadata: String
    var fingerprintResults: String
    var siteHistory: [SiteHistoryEntry]
    var injectionReports: [InjectionInspectionReport]

    init(
        exportDate: Date = Date(),
        deviceProfile: String = "",
        sessionDiagnostics: String = "",
        constraintLogs: [ConstraintLogEntry] = [],
        mediaMetadata: String = "",
        fingerprintResults: String = "",
        siteHistory: [SiteHistoryEntry] = [],
        injectionReports: [InjectionInspectionReport] = []
    ) {
        self.exportDate = exportDate
        self.deviceProfile = deviceProfile
        self.sessionDiagnostics = sessionDiagnostics
        self.constraintLogs = constraintLogs
        self.mediaMetadata = mediaMetadata
        self.fingerprintResults = fingerprintResults
        self.siteHistory = siteHistory
        self.injectionReports = injectionReports
    }
}
