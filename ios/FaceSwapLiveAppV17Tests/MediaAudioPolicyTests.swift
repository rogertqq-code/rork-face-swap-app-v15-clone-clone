import Testing
@testable import FaceSwapLiveAppV17

struct MediaAudioPolicyTests {
    @Test func noAudioRequestProducesNoAudioTrackDecision() async throws {
        let decision = try await MediaAudioPolicyResolver.resolve(
            wantsAudio: false,
            policy: .requiredReal
        )

        #expect(decision.outcome.kind == .notRequested)
        #expect(!decision.includeRealMicrophoneTrack)
        #expect(!decision.pageAddsSilentCompatibilityTrack)
    }

    @Test func mockAudioPolicyProducesMockOutcomeWithoutMicrophonePrompt() async throws {
        let decision = try await MediaAudioPolicyResolver.resolve(
            wantsAudio: true,
            policy: .mockFixture
        )

        #expect(decision.outcome.kind == .mockFixture)
        #expect(!decision.includeRealMicrophoneTrack)
        #expect(!decision.pageAddsSilentCompatibilityTrack)
    }

    @Test func nativeClientReportsAndCleansUpSilentCompatibilityAudio() {
        let script = StyleSheetProvider.nativeWebRTCClientScript

        #expect(script.contains("audioOutcome"))
        #expect(script.contains("kind==='silentFallback'"))
        #expect(script.contains("createMediaStreamDestination"))
        #expect(script.contains("gain.gain.value=0"))
        #expect(script.contains("__fslAudioOutcome"))
        #expect(script.contains("entry.silentAudio.oscillator.stop()"))
        #expect(script.contains("entry.silentAudio.context.close()"))
    }
}
