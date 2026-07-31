import Foundation

nonisolated enum MediaItemKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case image
    case video

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        }
    }

    nonisolated var sequenceKind: SequenceStepKind {
        switch self {
        case .image: .photo
        case .video: .video
        }
    }
}

nonisolated enum MediaResizeMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fillCrop
    case fitWithBars
    case stretch
    case squareSafe

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .fillCrop: "Fill Crop"
        case .fitWithBars: "Fit + Bars"
        case .stretch: "Exact Stretch"
        case .squareSafe: "Square Safe"
        }
    }

    nonisolated var shortLabel: String {
        switch self {
        case .fillCrop: "Crop"
        case .fitWithBars: "Fit"
        case .stretch: "Stretch"
        case .squareSafe: "Safe"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .fillCrop: "crop"
        case .fitWithBars: "rectangle.inset.filled"
        case .stretch: "arrow.up.left.and.arrow.down.right"
        case .squareSafe: "square.dashed"
        }
    }

    nonisolated var help: String {
        switch self {
        case .fillCrop: "Fills the requested frame and trims the overflow. Best for camera realism."
        case .fitWithBars: "Keeps the whole image/video visible and adds bars if needed."
        case .stretch: "Forces the exact requested size, even if the shape changes."
        case .squareSafe: "Keeps the subject centered in a square-safe region before fitting."
        }
    }
}

nonisolated enum MediaVariantSourceGroup: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case frontCamera
    case backCamera
    case browserRequest
    case iPhoneDefault
    case commonBrowser
    case responseMap
    case nativeResponse
    case liveResponse
    case custom

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .frontCamera: "Front Camera"
        case .backCamera: "Back Camera"
        case .browserRequest: "Live URL"
        case .iPhoneDefault: "iPhone Defaults"
        case .commonBrowser: "Browser Defaults"
        case .responseMap: "Device Response"
        case .nativeResponse: "Native Response"
        case .liveResponse: "Live Response"
        case .custom: "Custom"
        }
    }
}

nonisolated struct NormalizedCropRect: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let full = NormalizedCropRect()
}

nonisolated struct SavedMediaVariant: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var mediaID: UUID
    var kind: MediaItemKind
    var target: RequestTarget
    var fileName: String
    var thumbnailFileName: String?
    var displayName: String
    var width: Int
    var height: Int
    var frameRate: Int
    var resizeMode: MediaResizeMode
    var sourceGroup: MediaVariantSourceGroup
    var sourceLabel: String
    var cropRect: NormalizedCropRect
    var fileSizeBytes: Int64
    var createdAt: Date
    var requestedWidth: Int?
    var requestedHeight: Int?
    var requestedFrameRate: Int?
    var responseSurface: CameraRequestSurface?
    var responseMatchType: CameraResponseMatchType?
    var responseConfidence: Double?
    var responseNotes: String?

    init(
        id: UUID = UUID(),
        mediaID: UUID,
        kind: MediaItemKind,
        target: RequestTarget,
        fileName: String,
        thumbnailFileName: String? = nil,
        displayName: String,
        width: Int,
        height: Int,
        frameRate: Int = 30,
        resizeMode: MediaResizeMode,
        sourceGroup: MediaVariantSourceGroup,
        sourceLabel: String,
        cropRect: NormalizedCropRect = .full,
        fileSizeBytes: Int64 = 0,
        createdAt: Date = Date(),
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        requestedFrameRate: Int? = nil,
        responseSurface: CameraRequestSurface? = nil,
        responseMatchType: CameraResponseMatchType? = nil,
        responseConfidence: Double? = nil,
        responseNotes: String? = nil
    ) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.target = target
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.displayName = displayName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.resizeMode = resizeMode
        self.sourceGroup = sourceGroup
        self.sourceLabel = sourceLabel
        self.cropRect = cropRect
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedFrameRate = requestedFrameRate
        self.responseSurface = responseSurface
        self.responseMatchType = responseMatchType
        self.responseConfidence = responseConfidence
        self.responseNotes = responseNotes
    }

    nonisolated var specLabel: String {
        if kind == .video {
            return "\(width)×\(height) @ \(frameRate)fps"
        }
        return "\(width)×\(height)"
    }
}

nonisolated struct MediaVariantPreset: Identifiable, Sendable {
    var id: String
    var target: RequestTarget
    var width: Int
    var height: Int
    var frameRate: Int
    var sourceGroup: MediaVariantSourceGroup
    var sourceLabel: String
    var isLiveRequest: Bool
    var responseResult: CameraResponseResult?

    init(
        target: RequestTarget,
        width: Int,
        height: Int,
        frameRate: Int,
        sourceGroup: MediaVariantSourceGroup,
        sourceLabel: String,
        isLiveRequest: Bool = false,
        responseResult: CameraResponseResult? = nil
    ) {
        self.target = target
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sourceGroup = sourceGroup
        self.sourceLabel = sourceLabel
        self.isLiveRequest = isLiveRequest
        self.responseResult = responseResult
        self.id = "\(target.rawValue)-\(width)x\(height)-\(frameRate)-\(sourceGroup.rawValue)-\(sourceLabel)-\(responseResult?.id.uuidString ?? "none")"
    }

    nonisolated var specLabel: String { "\(width)×\(height) @ \(frameRate)fps" }

    nonisolated var requestedLabel: String {
        guard let responseResult else { return specLabel }
        return responseResult.request.requestedLabel
    }

    nonisolated var matchLabel: String {
        responseResult?.matchType.label ?? (isLiveRequest ? CameraResponseMatchType.browserLearned.label : CameraResponseMatchType.profileDefault.label)
    }

    nonisolated var confidence: Double {
        responseResult?.confidence ?? (isLiveRequest ? 0.78 : 0.65)
    }
}

/// Legacy name retained for existing saved data and call sites. It now represents
/// any imported media item — image or video — plus generated output variants.
nonisolated struct SavedVideo: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var name: String
    var originalFileName: String
    var importedAt: Date
    var frontCameraFileName: String?
    var backCameraFileName: String?
    var originalWidth: Int
    var originalHeight: Int
    var originalDuration: Double
    var frontSpec: String?
    var backSpec: String?
    var thumbnailFileName: String?
    var fileSizeBytes: Int64
    var mediaKind: MediaItemKind?
    var variants: [SavedMediaVariant]?
    var imageAnalysis: MediaImageAnalysisReport?

    init(
        id: UUID = UUID(),
        name: String,
        originalFileName: String,
        importedAt: Date = Date(),
        frontCameraFileName: String? = nil,
        backCameraFileName: String? = nil,
        originalWidth: Int = 0,
        originalHeight: Int = 0,
        originalDuration: Double = 0,
        frontSpec: String? = nil,
        backSpec: String? = nil,
        thumbnailFileName: String? = nil,
        fileSizeBytes: Int64 = 0,
        mediaKind: MediaItemKind? = nil,
        variants: [SavedMediaVariant]? = nil,
        imageAnalysis: MediaImageAnalysisReport? = nil
    ) {
        self.id = id
        self.name = name
        self.originalFileName = originalFileName
        self.importedAt = importedAt
        self.frontCameraFileName = frontCameraFileName
        self.backCameraFileName = backCameraFileName
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalDuration = originalDuration
        self.frontSpec = frontSpec
        self.backSpec = backSpec
        self.thumbnailFileName = thumbnailFileName
        self.fileSizeBytes = fileSizeBytes
        self.mediaKind = mediaKind
        self.variants = variants
        self.imageAnalysis = imageAnalysis
    }

    nonisolated var resolvedKind: MediaItemKind {
        mediaKind ?? .video
    }

    nonisolated var allVariants: [SavedMediaVariant] {
        variants ?? []
    }

    nonisolated var isImage: Bool { resolvedKind == .image }
    nonisolated var isVideo: Bool { resolvedKind == .video }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: SavedVideo, rhs: SavedVideo) -> Bool {
        lhs.id == rhs.id
    }
}
