import AVFoundation
import Foundation

nonisolated struct MediaAudioDecision: Sendable, Hashable {
    var includeRealMicrophoneTrack: Bool
    var pageAddsSilentCompatibilityTrack: Bool
    var outcome: MediaAudioOutcome
}

nonisolated enum MediaAudioPolicyResolver {
    static func resolve(
        wantsAudio: Bool,
        policy: MediaAudioPolicy
    ) async throws -> MediaAudioDecision {
        guard wantsAudio else {
            return MediaAudioDecision(
                includeRealMicrophoneTrack: false,
                pageAddsSilentCompatibilityTrack: false,
                outcome: MediaAudioOutcome(kind: .notRequested)
            )
        }

        if policy == .mockFixture {
            return MediaAudioDecision(
                includeRealMicrophoneTrack: false,
                pageAddsSilentCompatibilityTrack: false,
                outcome: MediaAudioOutcome(kind: .mockFixture)
            )
        }

        let granted = await microphoneAccessGranted()
        if granted {
            return MediaAudioDecision(
                includeRealMicrophoneTrack: true,
                pageAddsSilentCompatibilityTrack: false,
                outcome: MediaAudioOutcome(kind: .realMicrophone)
            )
        }

        if policy == .compatibilitySilentFallback {
            return MediaAudioDecision(
                includeRealMicrophoneTrack: false,
                pageAddsSilentCompatibilityTrack: true,
                outcome: MediaAudioOutcome(
                    kind: .silentFallback,
                    reason: "Microphone access was unavailable; video continues with an explicitly reported silent compatibility track."
                )
            )
        }

        throw MediaDeliveryContractError.sourceUnavailable(
            "Real microphone audio was required, but microphone access was denied or restricted."
        )
    }

    private static func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
