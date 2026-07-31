import Foundation
import UIKit

nonisolated struct CameraDeviceSpec: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var position: String
    var deviceType: String
    var uniqueID: String
    var modelID: String
    var manufacturer: String

    var maxWidth: Int
    var maxHeight: Int
    var activeWidth: Int
    var activeHeight: Int
    var maxFrameRate: Double
    var activeFrameRate: Double
    var minFrameRate: Double

    var hasFlash: Bool
    var hasTorch: Bool
    var isAutoFocusSupported: Bool
    var maxZoomFactor: Double
    var minISO: Float
    var maxISO: Float

    var supportedPresets: [String]
    var supportedFormats: [CameraFormatSpec]

    var testClipDuration: Double?
    var testClipBitrate: Int?
    var testClipCodec: String?
    var testClipColorPrimaries: String?
    var testClipTransferFunction: String?
    var testClipColorMatrix: String?
    var testClipProfileLevel: String?

    var activeColorSpace: String?
    var exposureDurationSeconds: Double?
    var focalLength: Float?
    var lensAperture: Float?
    var whiteBalanceGains: String?
}

nonisolated struct CameraFormatSpec: Codable, Sendable {
    var width: Int
    var height: Int
    var maxFrameRate: Double
    var minFrameRate: Double
    var mediaType: String
    var videoFieldOfView: Float
    var isMultiCamSupported: Bool
}

nonisolated struct MicrophoneDeviceSpec: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var uniqueID: String
    var modelID: String
    var manufacturer: String
    var position: String
    var deviceType: String

    var sampleRate: Double
    var channelCount: Int
    var preferredSampleRate: Double
    var preferredBufferDuration: Double

    var dataSources: [MicrophoneDataSource]

    var testSampleRate: Double?
    var testBitDepth: Int?
    var testChannelCount: Int?
}

nonisolated struct MicrophoneDataSource: Codable, Sendable {
    var dataSourceID: Int
    var dataSourceName: String
    var orientation: String?
    var location: String?
    var selectedPolarPattern: String?
    var supportedPolarPatterns: [String]
}

nonisolated struct WebFingerprintSpec: Codable, Sendable {
    var userAgent: String
    var platform: String
    var language: String
    var languages: [String]
    var hardwareConcurrency: Int
    var deviceMemory: Int
    var maxTouchPoints: Int
    var screenWidth: Int
    var screenHeight: Int
    var screenColorDepth: Int
    var devicePixelRatio: Double
    var timezoneOffset: Int
    var timezone: String
    var doNotTrack: String?
    var vendor: String
    var rendererInfo: String
    var vendorInfo: String
    var webglVersion: String
}

nonisolated struct DeviceHardwareSpec: Codable, Sendable {
    var modelName: String
    var modelIdentifier: String
    var systemName: String
    var systemVersion: String
    var processorCount: Int
    var physicalMemoryGB: Double
    var screenNativeBounds: String
    var screenScale: Double
    var screenNativeScale: Double
    var identifierForVendor: String?
}

nonisolated struct MediaConversionSpec: Codable, Sendable {
    var targetWidth: Int
    var targetHeight: Int
    var targetFrameRate: Int
    var targetBitrate: Int
    var targetCodec: String
    var targetColorPrimaries: String?
    var targetTransferFunction: String?
    var targetColorMatrix: String?
    var targetProfileLevel: String?

    static let allowedFrameRates: [Int] = [15, 24, 25, 30, 60]
    static let allowedResolutions: [(Int, Int)] = [
        (640, 480), (1280, 720), (1920, 1080), (3840, 2160)
    ]

    static func clampFrameRate(_ requested: Int) -> Int {
        return allowedFrameRates.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? 30
    }

    static func clampResolution(width: Int, height: Int) -> (Int, Int) {
        let requested = width * height
        return allowedResolutions.min(by: {
            abs($0.0 * $0.1 - requested) < abs($1.0 * $1.1 - requested)
        }) ?? (1280, 720)
    }
}

nonisolated struct DeviceProfile: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var deviceHardware: DeviceHardwareSpec
    var cameras: [CameraDeviceSpec]
    var microphones: [MicrophoneDeviceSpec]
    var webFingerprint: WebFingerprintSpec
    var preferredFrontCameraID: String?
    var preferredBackCameraID: String?
    var preferredMicrophoneID: String?
    var mediaTestResult: MediaTestResult?
    var fingerprintBaseline: FingerprintBaselineSpec?
    var cameraResponseMap: CameraResponseMap?

    var recommendedMethod: InjectionMethodKind?
    var recommendedAdjustments: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        deviceHardware: DeviceHardwareSpec,
        cameras: [CameraDeviceSpec],
        microphones: [MicrophoneDeviceSpec] = [],
        webFingerprint: WebFingerprintSpec,
        preferredFrontCameraID: String? = nil,
        preferredBackCameraID: String? = nil,
        preferredMicrophoneID: String? = nil,
        mediaTestResult: MediaTestResult? = nil,
        fingerprintBaseline: FingerprintBaselineSpec? = nil,
        cameraResponseMap: CameraResponseMap? = nil,
        recommendedMethod: InjectionMethodKind? = nil,
        recommendedAdjustments: [String] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.deviceHardware = deviceHardware
        self.cameras = cameras
        self.microphones = microphones
        self.webFingerprint = webFingerprint
        self.preferredFrontCameraID = preferredFrontCameraID
        self.preferredBackCameraID = preferredBackCameraID
        self.preferredMicrophoneID = preferredMicrophoneID
        self.mediaTestResult = mediaTestResult
        self.fingerprintBaseline = fingerprintBaseline
        self.cameraResponseMap = cameraResponseMap
        self.recommendedMethod = recommendedMethod
        self.recommendedAdjustments = recommendedAdjustments
    }

    var frontCamera: CameraDeviceSpec? {
        if let preferred = preferredFrontCameraID {
            return cameras.first { $0.id == preferred }
        }
        return cameras.first { $0.position == "front" }
    }

    var backCamera: CameraDeviceSpec? {
        if let preferred = preferredBackCameraID {
            return cameras.first { $0.id == preferred }
        }
        return cameras.first { $0.position == "back" }
    }

    var primaryMicrophone: MicrophoneDeviceSpec? {
        if let preferred = preferredMicrophoneID {
            return microphones.first { $0.id == preferred }
        }
        return microphones.first
    }

    func conversionSpec(for camera: CameraDeviceSpec) -> MediaConversionSpec {
        let (w, h) = MediaConversionSpec.clampResolution(
            width: camera.activeWidth,
            height: camera.activeHeight
        )
        let fps = MediaConversionSpec.clampFrameRate(Int(camera.activeFrameRate))
        let bitrate = camera.testClipBitrate ?? defaultBitrate(width: w, height: h, fps: fps)

        return MediaConversionSpec(
            targetWidth: w,
            targetHeight: h,
            targetFrameRate: fps,
            targetBitrate: bitrate,
            targetCodec: camera.testClipCodec ?? "h264",
            targetColorPrimaries: camera.testClipColorPrimaries,
            targetTransferFunction: camera.testClipTransferFunction,
            targetColorMatrix: camera.testClipColorMatrix,
            targetProfileLevel: camera.testClipProfileLevel
        )
    }

    private func defaultBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = width * height
        if pixels >= 3840 * 2160 {
            return fps >= 60 ? 50_000_000 : 25_000_000
        } else if pixels >= 1920 * 1080 {
            return fps >= 60 ? 17_000_000 : 10_000_000
        } else if pixels >= 1280 * 720 {
            return fps >= 60 ? 10_000_000 : 5_000_000
        }
        return 2_500_000
    }
}
