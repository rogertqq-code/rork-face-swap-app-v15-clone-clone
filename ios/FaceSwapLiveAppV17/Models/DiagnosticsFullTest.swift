import Foundation

// MARK: - Overall status for a full-test row

/// The rolled-up result of a single method/media combination or sub-check.
nonisolated enum DiagTestStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
    case info
    case skip

    nonisolated var label: String {
        switch self {
        case .pass: "Pass"
        case .warn: "Downgraded"
        case .fail: "Fail"
        case .info: "Info"
        case .skip: "Skipped"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .skip: "minus.circle"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .pass: "green"
        case .warn: "orange"
        case .fail: "red"
        case .info: "cyan"
        case .skip: "gray"
        }
    }
}

// MARK: - Environment snapshot

/// The browser/device environment the full test actually ran against, captured
/// from the hidden built-in test page (not guessed).
nonisolated struct DiagTestEnvironment: Codable, Sendable {
    var userAgent: String
    var iosVersion: String
    var secureContext: Bool
    var hasMediaDevices: Bool
    var hasWorker: Bool
    var hasVideoFrame: Bool
    var hasVideoTrackGenerator: Bool
    var deviceProfileName: String
    var profileResolution: String

    init(
        userAgent: String = "",
        iosVersion: String = "",
        secureContext: Bool = false,
        hasMediaDevices: Bool = false,
        hasWorker: Bool = false,
        hasVideoFrame: Bool = false,
        hasVideoTrackGenerator: Bool = false,
        deviceProfileName: String = "None",
        profileResolution: String = "—"
    ) {
        self.userAgent = userAgent
        self.iosVersion = iosVersion
        self.secureContext = secureContext
        self.hasMediaDevices = hasMediaDevices
        self.hasWorker = hasWorker
        self.hasVideoFrame = hasVideoFrame
        self.hasVideoTrackGenerator = hasVideoTrackGenerator
        self.deviceProfileName = deviceProfileName
        self.profileResolution = profileResolution
    }
}

// MARK: - Per method/media result

/// Everything recorded for one injection method exercised with one media kind
/// (a still photo or a video) against the built-in camera page.
nonisolated struct DiagMethodResult: Codable, Sendable, Identifiable {
    var id: UUID
    var methodRaw: String
    /// "photo" or "video".
    var mediaKind: String

    // Takeover
    var armed: Bool
    var armError: String

    // What the site received via getUserMedia
    var gumSucceeded: Bool
    var gumError: String
    var width: Int
    var height: Int
    var claimedFps: Double

    // Which delivery engine actually ran
    var feed: String        // "vtg" | "canvas" | ""
    var lane: String        // "private" | ""
    var downgraded: Bool
    var reason: String

    // Frame delivery
    var framesFlowing: Bool
    var measuredFps: Double
    var frameCount: Int

    // Sensor realism (Round 2) — only meaningful on a clean (vtg) feed
    /// Whether the sensor-realism layer (capture-clock timing + grain) was on
    /// during this run.
    var srRealism: Bool
    /// Whether the clean feed had a drawing surface so grain could blend. False
    /// for the raw video-element fallback, which skips grain.
    var srCanvas: Bool

    // File-picker path
    var pickerReturnedMedia: Bool
    var pickerFileType: String
    var pickerFileSize: Int

    // Camera-style capture path (an input carrying the `capture` attribute)
    var captureReturnedMedia: Bool
    var captureFileType: String
    var captureFileSize: Int
    var captureFileName: String

    // Detector tricks
    var detectorScore: Int
    var detectorChecks: [DetectorSelfTestCheck]

    var overall: DiagTestStatus
    var notes: String

    init(
        id: UUID = UUID(),
        methodRaw: String = "",
        mediaKind: String = "",
        armed: Bool = false,
        armError: String = "",
        gumSucceeded: Bool = false,
        gumError: String = "",
        width: Int = 0,
        height: Int = 0,
        claimedFps: Double = 0,
        feed: String = "",
        lane: String = "",
        downgraded: Bool = false,
        reason: String = "",
        framesFlowing: Bool = false,
        measuredFps: Double = 0,
        frameCount: Int = 0,
        srRealism: Bool = false,
        srCanvas: Bool = false,
        pickerReturnedMedia: Bool = false,
        pickerFileType: String = "",
        pickerFileSize: Int = 0,
        captureReturnedMedia: Bool = false,
        captureFileType: String = "",
        captureFileSize: Int = 0,
        captureFileName: String = "",
        detectorScore: Int = 0,
        detectorChecks: [DetectorSelfTestCheck] = [],
        overall: DiagTestStatus = .skip,
        notes: String = ""
    ) {
        self.id = id
        self.methodRaw = methodRaw
        self.mediaKind = mediaKind
        self.armed = armed
        self.armError = armError
        self.gumSucceeded = gumSucceeded
        self.gumError = gumError
        self.width = width
        self.height = height
        self.claimedFps = claimedFps
        self.feed = feed
        self.lane = lane
        self.downgraded = downgraded
        self.reason = reason
        self.framesFlowing = framesFlowing
        self.measuredFps = measuredFps
        self.frameCount = frameCount
        self.srRealism = srRealism
        self.srCanvas = srCanvas
        self.pickerReturnedMedia = pickerReturnedMedia
        self.pickerFileType = pickerFileType
        self.pickerFileSize = pickerFileSize
        self.captureReturnedMedia = captureReturnedMedia
        self.captureFileType = captureFileType
        self.captureFileSize = captureFileSize
        self.captureFileName = captureFileName
        self.detectorScore = detectorScore
        self.detectorChecks = detectorChecks
        self.overall = overall
        self.notes = notes
    }

    nonisolated var methodLabel: String {
        InjectionMethodKind(rawValue: methodRaw)?.migratedCameraMethod.label ?? methodRaw
    }

    nonisolated var mediaLabel: String {
        mediaKind == "video" ? "Video" : (mediaKind == "photo" ? "Photo" : mediaKind)
    }

    nonisolated var resolutionLabel: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : "—"
    }

    /// Which feed engine ran, in plain language.
    nonisolated var feedLabel: String {
        if feed == "vtg" { return lane == "private" ? "Clean track · private lane" : "Clean background track" }
        if feed == "canvas" { return "Canvas feed" }
        return "None"
    }

    // MARK: - Sensor realism (Round 2)

    /// Sensor realism only runs on a clean (vtg) feed.
    nonisolated var isCleanFeed: Bool { feed == "vtg" }
    /// Capture-clock timing engages on any live clean feed when the toggle is on.
    nonisolated var sensorTimingEngaged: Bool { isCleanFeed && srRealism }
    /// Grain / PRNU also needs a drawing-surface clean feed.
    nonisolated var sensorGrainEngaged: Bool { isCleanFeed && srRealism && srCanvas }
    /// One-line sensor-realism summary for the export log and report view.
    nonisolated var sensorRealismLog: String {
        if !isCleanFeed { return "n/a — Canvas feed (realism runs on the clean feed only)" }
        if !srRealism { return "off (toggle disabled) — plain decoded frames" }
        if srCanvas { return "capture-clock timing + per-frame grain engaged" }
        return "capture-clock timing engaged · grain skipped (raw feed)"
    }
    /// Compact sensor-realism value for tight UI rows.
    nonisolated var sensorRealismShort: String {
        if !isCleanFeed { return "n/a (Canvas)" }
        if !srRealism { return "Off" }
        if srCanvas { return "Timing + grain" }
        return "Timing only (raw)"
    }
}

// MARK: - Passthrough + block sub-results

/// Confirms Passthrough hands the request to the real camera (no virtual feed).
nonisolated struct DiagPassthroughResult: Codable, Sendable {
    var virtualFeedEngaged: Bool
    var gumSucceeded: Bool
    var status: DiagTestStatus
    var note: String

    init(virtualFeedEngaged: Bool = false, gumSucceeded: Bool = false, status: DiagTestStatus = .skip, note: String = "") {
        self.virtualFeedEngaged = virtualFeedEngaged
        self.gumSucceeded = gumSucceeded
        self.status = status
        self.note = note
    }
}

/// Confirms a block step actually refuses the live camera request.
nonisolated struct DiagBlockResult: Codable, Sendable {
    var refused: Bool
    var gumError: String
    var status: DiagTestStatus
    var note: String

    init(refused: Bool = false, gumError: String = "", status: DiagTestStatus = .skip, note: String = "") {
        self.refused = refused
        self.gumError = gumError
        self.status = status
        self.note = note
    }
}

// MARK: - Full report

/// The complete result of one automatic full test — the single artifact the
/// export log is built from.
nonisolated struct DiagnosticsFullTestReport: Codable, Sendable, Identifiable {
    var id: UUID
    var timestamp: Date
    var environment: DiagTestEnvironment
    var results: [DiagMethodResult]
    var passthrough: DiagPassthroughResult
    var block: DiagBlockResult
    var recommendedMethodRaw: String
    var summaryLine: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        environment: DiagTestEnvironment = DiagTestEnvironment(),
        results: [DiagMethodResult] = [],
        passthrough: DiagPassthroughResult = DiagPassthroughResult(),
        block: DiagBlockResult = DiagBlockResult(),
        recommendedMethodRaw: String = "",
        summaryLine: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.environment = environment
        self.results = results
        self.passthrough = passthrough
        self.block = block
        self.recommendedMethodRaw = recommendedMethodRaw
        self.summaryLine = summaryLine
    }

    nonisolated var passCount: Int { results.filter { $0.overall == .pass }.count }
    nonisolated var warnCount: Int { results.filter { $0.overall == .warn }.count }
    nonisolated var failCount: Int { results.filter { $0.overall == .fail }.count }

    nonisolated var recommendedMethodLabel: String {
        InjectionMethodKind(rawValue: recommendedMethodRaw)?.migratedCameraMethod.label ?? "—"
    }

    /// Overall tint for the summary header.
    nonisolated var summaryTintName: String {
        if failCount > 0 { return "orange" }
        if warnCount > 0 { return "cyan" }
        return results.isEmpty ? "gray" : "green"
    }
}
