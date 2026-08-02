#if QA_AUTOMATION
import Foundation
import UIKit

nonisolated enum QABuiltInFixtures {
    static let deviceProfileLocation = "builtin://qa-device-profile-v1"
    static let deviceProfileID = UUID(uuidString: "8A9B5F53-6F92-4D85-A571-0D2048D04401")!
    static let deviceProfileName = "QA Deterministic iPhone"
    static let mediaSequenceLocation = "builtin://qa-photo-sequence-v1"
    static let mediaSequenceName = "QA Deterministic Photo Sequence"

    nonisolated static func profile(from reference: QAFixtureReference) throws -> DeviceProfile {
        guard reference.kind == .profile else {
            throw QACommandError.invalidPayload("Fixture \(reference.id) is not a profile fixture")
        }

        if reference.location == deviceProfileLocation {
            return deterministicDeviceProfile(
                id: reference.metadata["profileID"].flatMap(UUID.init(uuidString:)) ?? deviceProfileID,
                name: reference.metadata["name"] ?? deviceProfileName,
                systemVersion: reference.metadata["systemVersion"] ?? "18.0"
            )
        }

        let url: URL
        if let parsed = URL(string: reference.location), parsed.isFileURL {
            url = parsed
        } else {
            url = URL(fileURLWithPath: reference.location)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(DeviceProfile.self, from: data)
        } catch {
            throw QACommandError.invalidPayload("Profile fixture \(reference.id) could not be decoded: \(error.localizedDescription)")
        }
    }

    @MainActor
    static func installMediaSequence(
        from reference: QAFixtureReference,
        into library: SequenceLibraryService
    ) throws -> SavedMediaSequence {
        guard reference.kind == .mediaSequence else {
            throw QACommandError.invalidPayload("Fixture \(reference.id) is not a media sequence fixture")
        }
        guard reference.location == mediaSequenceLocation else {
            throw QACommandError.invalidPayload("Unsupported media sequence fixture location \(reference.location)")
        }

        let name = reference.metadata["name"] ?? mediaSequenceName
        if let existing = library.saved.first(where: { $0.name == name }) {
            library.delete(existing)
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        let image = renderer.image { context in
            UIColor(red: 0.07, green: 0.16, blue: 0.34, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            UIColor(red: 0.20, green: 0.88, blue: 0.82, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 208, y: 128, width: 224, height: 224))
        }
        let step = SequenceStep(
            kind: .photo,
            liveCamera: .serveLive,
            requestSurface: .either,
            image: image,
            displayName: "QA 640×480 Fixture"
        )
        return library.save(
            name: name,
            steps: [step],
            advanceMode: .advanceEach,
            endBehavior: .holdLast,
            asTemplate: false
        )
    }

    nonisolated static func deterministicDeviceProfile(
        id: UUID = deviceProfileID,
        name: String = deviceProfileName,
        systemVersion: String = "18.0"
    ) -> DeviceProfile {
        let frontID = "qa.camera.front"
        let backID = "qa.camera.back"
        let microphoneID = "qa.microphone.builtin"
        let format = CameraFormatSpec(
            width: 1_280,
            height: 720,
            maxFrameRate: 30,
            minFrameRate: 15,
            mediaType: "vide",
            videoFieldOfView: 70,
            isMultiCamSupported: true
        )

        let front = CameraDeviceSpec(
            id: frontID,
            label: "QA Front Camera",
            position: "front",
            deviceType: "builtInTrueDepthCamera",
            uniqueID: frontID,
            modelID: "QA-FRONT-1",
            manufacturer: "Apple Inc.",
            maxWidth: 1_920,
            maxHeight: 1_080,
            activeWidth: 1_280,
            activeHeight: 720,
            maxFrameRate: 30,
            activeFrameRate: 30,
            minFrameRate: 15,
            hasFlash: false,
            hasTorch: false,
            isAutoFocusSupported: true,
            maxZoomFactor: 2,
            minISO: 22,
            maxISO: 1_600,
            supportedPresets: ["hd1280x720", "hd1920x1080"],
            supportedFormats: [format],
            testClipDuration: 1,
            testClipBitrate: 2_500_000,
            testClipCodec: "h264",
            testClipColorPrimaries: "ITU_R_709_2",
            testClipTransferFunction: "ITU_R_709_2",
            testClipColorMatrix: "ITU_R_709_2",
            testClipProfileLevel: "H264_Baseline_AutoLevel",
            activeColorSpace: "sRGB",
            exposureDurationSeconds: 1.0 / 60.0,
            focalLength: 2.7,
            lensAperture: 2.2,
            whiteBalanceGains: "2.0,1.0,1.8"
        )

        let back = CameraDeviceSpec(
            id: backID,
            label: "QA Back Camera",
            position: "back",
            deviceType: "builtInWideAngleCamera",
            uniqueID: backID,
            modelID: "QA-BACK-1",
            manufacturer: "Apple Inc.",
            maxWidth: 3_840,
            maxHeight: 2_160,
            activeWidth: 1_920,
            activeHeight: 1_080,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 15,
            hasFlash: true,
            hasTorch: true,
            isAutoFocusSupported: true,
            maxZoomFactor: 8,
            minISO: 25,
            maxISO: 2_000,
            supportedPresets: ["hd1280x720", "hd1920x1080", "hd4K3840x2160"],
            supportedFormats: [format],
            testClipDuration: 1,
            testClipBitrate: 5_000_000,
            testClipCodec: "h264",
            testClipColorPrimaries: "ITU_R_709_2",
            testClipTransferFunction: "ITU_R_709_2",
            testClipColorMatrix: "ITU_R_709_2",
            testClipProfileLevel: "H264_High_AutoLevel",
            activeColorSpace: "sRGB",
            exposureDurationSeconds: 1.0 / 60.0,
            focalLength: 5.7,
            lensAperture: 1.8,
            whiteBalanceGains: "2.0,1.0,1.8"
        )

        let microphone = MicrophoneDeviceSpec(
            id: microphoneID,
            label: "QA Built-In Microphone",
            uniqueID: microphoneID,
            modelID: "QA-MIC-1",
            manufacturer: "Apple Inc.",
            position: "bottom",
            deviceType: "builtInMicrophone",
            sampleRate: 48_000,
            channelCount: 1,
            preferredSampleRate: 48_000,
            preferredBufferDuration: 0.01,
            dataSources: [
                MicrophoneDataSource(
                    dataSourceID: 1,
                    dataSourceName: "Bottom",
                    orientation: "portrait",
                    location: "bottom",
                    selectedPolarPattern: "cardioid",
                    supportedPolarPatterns: ["cardioid"]
                )
            ],
            testSampleRate: 48_000,
            testBitDepth: 24,
            testChannelCount: 1
        )

        return DeviceProfile(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceHardware: DeviceHardwareSpec(
                modelName: "iPhone 15 Pro",
                modelIdentifier: "iPhone16,1",
                systemName: "iOS",
                systemVersion: systemVersion,
                processorCount: 6,
                physicalMemoryGB: 8,
                screenNativeBounds: "1179x2556",
                screenScale: 3,
                screenNativeScale: 3,
                identifierForVendor: "8A9B5F53-6F92-4D85-A571-0D2048D04402"
            ),
            cameras: [front, back],
            microphones: [microphone],
            webFingerprint: WebFingerprintSpec(
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
                platform: "iPhone",
                language: "en-US",
                languages: ["en-US", "en"],
                hardwareConcurrency: 6,
                deviceMemory: 8,
                maxTouchPoints: 5,
                screenWidth: 393,
                screenHeight: 852,
                screenColorDepth: 24,
                devicePixelRatio: 3,
                timezoneOffset: 0,
                timezone: "UTC",
                doNotTrack: nil,
                vendor: "Apple Computer, Inc.",
                rendererInfo: "Apple GPU",
                vendorInfo: "Apple Inc.",
                webglVersion: "WebGL 2.0"
            ),
            preferredFrontCameraID: frontID,
            preferredBackCameraID: backID,
            preferredMicrophoneID: microphoneID,
            recommendedMethod: .canvasPipeline,
            recommendedAdjustments: ["QA deterministic fixture"]
        )
    }
}
#endif
