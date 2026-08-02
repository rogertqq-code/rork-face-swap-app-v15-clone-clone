#if QA_AUTOMATION
import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct QABuiltInFixturesTests {
    @Test func deterministicProfileHasStableIdentityAndUsableMediaTopology() {
        let profile = QABuiltInFixtures.deterministicDeviceProfile()

        #expect(profile.id == QABuiltInFixtures.deviceProfileID)
        #expect(profile.name == QABuiltInFixtures.deviceProfileName)
        #expect(profile.deviceHardware.modelIdentifier == "iPhone16,1")
        #expect(profile.frontCamera?.activeWidth == 1_280)
        #expect(profile.frontCamera?.activeHeight == 720)
        #expect(profile.backCamera?.activeWidth == 1_920)
        #expect(profile.backCamera?.activeHeight == 1_080)
        #expect(profile.primaryMicrophone?.sampleRate == 48_000)
        #expect(profile.preferredFrontCameraID == "qa.camera.front")
        #expect(profile.preferredBackCameraID == "qa.camera.back")
        #expect(profile.recommendedMethod == .canvasPipeline)
    }

    @Test func builtInProfileReferenceAppliesMetadataOverrides() throws {
        let customID = UUID(uuidString: "8A9B5F53-6F92-4D85-A571-0D2048D04499")!
        let reference = QAFixtureReference(
            id: "custom-profile",
            kind: .profile,
            location: QABuiltInFixtures.deviceProfileLocation,
            metadata: [
                "profileID": customID.uuidString,
                "name": "Cable Device Fixture",
                "systemVersion": "18.5"
            ]
        )

        let profile = try QABuiltInFixtures.profile(from: reference)
        #expect(profile.id == customID)
        #expect(profile.name == "Cable Device Fixture")
        #expect(profile.deviceHardware.systemVersion == "18.5")
    }

    @Test func profileLoaderRejectsNonProfileFixture() {
        let reference = QAFixtureReference(
            id: "wrong-kind",
            kind: .mediaSequence,
            location: QABuiltInFixtures.mediaSequenceLocation,
            metadata: [:]
        )

        do {
            _ = try QABuiltInFixtures.profile(from: reference)
            Issue.record("Expected a non-profile fixture to be rejected")
        } catch let error as QACommandError {
            guard case .invalidPayload = error else {
                Issue.record("Expected invalidPayload, received \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
#endif
