import Foundation
import Testing
@testable import FaceSwapLiveAppV17

@MainActor
struct OfflineVerificationTests {
    @Test func reportPersistsAndReloadsForOnlyItsProfile() {
        let suiteName = "OfflineVerificationTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = makeProfile()
        let report = verifiedReport(for: profile)
        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        store.append(report)

        #expect(store.status(for: profile) == .verified)
        #expect(store.reports(for: profile.id).count == 1)

        let reloaded = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        #expect(reloaded.status(for: profile) == .verified)
        #expect(reloaded.latestReport(for: profile.id)?.id == report.id)
        #expect(reloaded.reports(for: UUID()).isEmpty)
    }

    @Test func historyIsBoundedAndNewestFirst() {
        let suiteName = "OfflineVerificationTests.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = makeProfile()
        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0...5 {
            var report = verifiedReport(for: profile)
            report.timestamp = base.addingTimeInterval(Double(index))
            store.append(report)
        }

        let reports = store.reports(for: profile.id)
        #expect(reports.count == OfflineVerificationStore.maximumReportsPerProfile)
        #expect(reports.first?.timestamp == base.addingTimeInterval(5))
        #expect(reports.last?.timestamp == base.addingTimeInterval(1))
    }

    @Test func deletingProfileEvidenceDoesNotRemoveAnotherProfile() {
        let suiteName = "OfflineVerificationTests.delete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = makeProfile()
        let second = makeProfile()
        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        store.append(verifiedReport(for: first))
        store.append(verifiedReport(for: second))

        store.removeAll(for: first.id)

        #expect(store.reports(for: first.id).isEmpty)
        #expect(store.reports(for: second.id).count == 1)
    }

    @Test func staleHardwareSignatureRequiresARerun() {
        let suiteName = "OfflineVerificationTests.stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = makeProfile(systemVersion: "18.0")
        var changed = original
        changed.deviceHardware.systemVersion = "18.1"

        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        store.append(verifiedReport(for: original))

        #expect(store.status(for: original) == .verified)
        #expect(store.status(for: changed) == .outdated)
    }

    @Test func recommendationRequiresVerifiedCoreAndFixtureEvidence() {
        let suiteName = "OfflineVerificationTests.recommendation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = makeProfile()
        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")
        store.append(verifiedReport(for: profile))

        #expect(store.allowsRecommendation(for: profile) == false)

        store.recordFixtureEvidence(
            for: profile,
            method: .canvasPipeline,
            passed: true,
            summary: "Mounted fixture completed."
        )

        #expect(store.allowsRecommendation(for: profile) == true)
        #expect(store.latestReport(for: profile.id)?.fixtureMethod == .canvasPipeline)

        store.recordFixtureEvidence(
            for: profile,
            method: .canvasPipeline,
            passed: false,
            summary: "Native FileList was unavailable."
        )
        #expect(store.allowsRecommendation(for: profile) == false)
    }

    @Test func outcomeDistinguishesAttentionInconclusiveAndSkipped() {
        let required = OfflineVerificationCheck(
            id: .profileShape,
            status: .passed,
            summary: "ok",
            isRequired: true
        )
        let pending = OfflineVerificationCheck(
            id: .guidedCameraCapture,
            status: .needsUserConfirmation,
            summary: "pending",
            isRequired: true
        )
        let failed = OfflineVerificationCheck(
            id: .microphoneReadiness,
            status: .needsAttention,
            summary: "failed",
            isRequired: true
        )
        let skipped = OfflineVerificationCheck(
            id: .profileShape,
            status: .skipped,
            summary: "skipped",
            isRequired: true
        )

        #expect(OfflineVerificationService.outcome(for: [required]) == .verified)
        #expect(OfflineVerificationService.outcome(for: [required, pending]) == .inconclusive)
        #expect(OfflineVerificationService.outcome(for: [required, failed]) == .needsAttention)
        #expect(OfflineVerificationService.outcome(for: [skipped]) == .skipped)
    }

    @Test func handoffScriptOnlyCommitsAfterNativeFileProof() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslCommitPickerResult"))
        #expect(script.contains("fslRollbackPickerResult"))
        #expect(script.contains("fslNativeFiles"))
        #expect(script.contains("nativePickerRetry"))
        #expect(!script.contains("Object.defineProperty(input,'files'"))
        #expect(!script.contains("fslOpenRealPicker(input);"))
    }

    @Test func allowRealCameraIsReportedSeparatelyFromDeliveryFailure() {
        let script = StyleSheetProvider.patchScript
        // A deliberate real-camera choice must not be announced to the app as a
        // failed hand-off on either the saved-rule or the ask-me path.
        #expect(script.contains("fslCam('realCamera','','')"))
        #expect(script.contains("reportSeq('realCamera','', 'native')"))
        #expect(!script.contains("fslCam('retry','','')"))
    }

    @Test func savedBlockRuleReportsItsOwnNativeAction() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("reportSeq('blockNative','', 'native')"))
    }

    @Test func probeModeIsTimeBoxedAndCannotSilenceTheLivePage() {
        let script = StyleSheetProvider.patchScript
        // Probe mode suppresses progress reporting and the real capture behavior.
        // An interrupted probe must never leave it latched on the live page, so it
        // is only honored while its own deadline is still in the future.
        #expect(script.contains("function fslProbing()"))
        #expect(script.contains("_probeUntil"))
        #expect(script.contains("if(!s._probeUntil||Date.now()>s._probeUntil){s._probeMode=false;s._probeUntil=0;return false;}"))
        // Every consumer must go through the self-healing check, never the raw flag.
        #expect(script.contains("if(fslProbing())return;"))
        #expect(script.contains("var probing=fslProbing();"))
        #expect(!script.contains("var probing=!!s._probeMode;"))
        #expect(!script.contains("if(!s||s._probeMode)return;"))
        // Every place that latches probe mode must also set its deadline.
        #expect(script.contains("st._probeMode=true;st._probeUntil=Date.now()+15000;"))
        #expect(DiagnosticsHarnessScripts.fullTestProbeBody.contains("s._probeMode=true;s._probeUntil=Date.now()+15000;"))
    }

    @Test func deliveryAlwaysResumesTheLiveFeedEvenIfTheCommitThrows() {
        let script = StyleSheetProvider.patchScript
        // The queue commit sits between clearing the watchdog and resuming the
        // held canvas feed, so it must not be able to throw past the resume.
        #expect(script.contains("try{fslCommitPickerResult(delivery);}catch(e){}"))
    }

    @Test func verificationGatesWritingARecommendationNotReadingOne() {
        // Verification decides whether a NEW recommendation may be saved. Reading a
        // method the profile already holds must stay ungated, otherwise a live
        // session is stranded on the default instead of the known-good method.
        let suiteName = "OfflineVerificationTests.gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var profile = makeProfile()
        profile.recommendedMethod = .canvasPipeline
        let store = OfflineVerificationStore(defaults: defaults, storageKey: "reports")

        // No verification evidence yet: the store must refuse to bless a new
        // recommendation, while the profile keeps the method it already has.
        #expect(store.allowsRecommendation(for: profile) == false)
        #expect(profile.recommendedMethod == .canvasPipeline)
    }

    @Test func fixtureProbeWaitsForTheRealHandoffWindow() {
        let probe = DiagnosticsHarnessScripts.fullTestProbeBody
        // Probe mode shortens the engine's believable capture hold; the timeout
        // must still outlast it so a healthy device is never scored as a failure.
        #expect(probe.contains("s._probeMode=true"))
        #expect(probe.contains("},2500);"))
        #expect(!probe.contains("},700);"))
        // The camera-style capture path is a separate check from a normal pick.
        #expect(probe.contains("pickerTest(true)"))
        #expect(probe.contains("pickerTest(false)"))
        // Proof must come from WebKit's own getter, never a shadowed property.
        #expect(probe.contains("HTMLInputElement.prototype,'files'"))
    }

    @Test func methodPassRequiresBothPickAndCaptureDelivery() {
        var result = DiagMethodResult(
            methodRaw: InjectionMethodKind.canvasPipeline.rawValue,
            mediaKind: "photo",
            armed: true,
            gumSucceeded: true,
            feed: "canvas",
            reason: "photo-step",
            framesFlowing: true,
            frameCount: 12,
            pickerReturnedMedia: true,
            pickerFileType: "image/jpeg",
            pickerFileSize: 2048,
            captureReturnedMedia: true,
            captureFileType: "image/jpeg",
            captureFileSize: 2048,
            captureFileName: "image.jpg"
        )
        #expect(DiagnosticsTestHarness.overall(for: result) == .pass)

        result.captureReturnedMedia = false
        result.captureFileSize = 0
        #expect(DiagnosticsTestHarness.overall(for: result) == .fail)

        result.captureReturnedMedia = true
        result.captureFileSize = 2048
        result.pickerReturnedMedia = false
        result.pickerFileSize = 0
        #expect(DiagnosticsTestHarness.overall(for: result) == .fail)
    }

    private func verifiedReport(for profile: DeviceProfile) -> OfflineVerificationReport {
        let requiredIDs: [OfflineVerificationCheckID] = [
            .profileShape,
            .cameraPermission,
            .microphoneReadiness,
            .mediaPreparation,
            .guidedCameraCapture
        ]
        let checks = requiredIDs.map {
            OfflineVerificationCheck(id: $0, status: .passed, summary: "passed", isRequired: true)
        } + [
            OfflineVerificationCheck(
                id: .browserCompatibility,
                status: .needsUserConfirmation,
                summary: "offline only",
                isRequired: false
            )
        ]
        return OfflineVerificationReport(
            profileID: profile.id,
            hardwareSignature: OfflineVerificationReport.hardwareSignature(for: profile),
            capabilities: OfflineVerificationCapabilitySummary(
                modelIdentifier: profile.deviceHardware.modelIdentifier,
                systemVersion: profile.deviceHardware.systemVersion,
                cameraCount: profile.cameras.count,
                microphoneCount: profile.microphones.count,
                cameraAuthorized: true,
                microphoneAuthorized: true
            ),
            checks: checks,
            outcome: .verified
        )
    }

    private func makeProfile(systemVersion: String = "18.0") -> DeviceProfile {
        let camera = CameraDeviceSpec(
            id: "front-camera",
            label: "Front Camera",
            position: "front",
            deviceType: "TrueDepth",
            uniqueID: "front-camera",
            modelID: "front-model",
            manufacturer: "Apple",
            maxWidth: 1920,
            maxHeight: 1080,
            activeWidth: 1280,
            activeHeight: 720,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 15,
            hasFlash: false,
            hasTorch: false,
            isAutoFocusSupported: true,
            maxZoomFactor: 1,
            minISO: 32,
            maxISO: 800,
            supportedPresets: ["AVCaptureSessionPreset1280x720"],
            supportedFormats: [],
            testClipDuration: 1.0,
            testClipBitrate: 1_000_000,
            testClipCodec: "h264",
            testClipColorPrimaries: nil,
            testClipTransferFunction: nil,
            testClipColorMatrix: nil,
            testClipProfileLevel: nil,
            activeColorSpace: "sRGB",
            exposureDurationSeconds: 0.01,
            focalLength: 2.6,
            lensAperture: 2.2,
            whiteBalanceGains: "R:1 G:1 B:1"
        )
        let microphone = MicrophoneDeviceSpec(
            id: "microphone",
            label: "Microphone",
            uniqueID: "microphone",
            modelID: "microphone-model",
            manufacturer: "Apple",
            position: "front",
            deviceType: "Built-in Microphone",
            sampleRate: 44_100,
            channelCount: 1,
            preferredSampleRate: 44_100,
            preferredBufferDuration: 0.01,
            dataSources: [],
            testSampleRate: 44_100,
            testBitDepth: 16,
            testChannelCount: 1
        )
        let hardware = DeviceHardwareSpec(
            modelName: "iPhone",
            modelIdentifier: "iPhone17,1",
            systemName: "iOS",
            systemVersion: systemVersion,
            processorCount: 6,
            physicalMemoryGB: 8,
            screenNativeBounds: "1179x2556",
            screenScale: 3,
            screenNativeScale: 3,
            identifierForVendor: nil
        )
        let fingerprint = WebFingerprintSpec(
            userAgent: "Mozilla/5.0",
            platform: "iPhone",
            language: "en-US",
            languages: ["en-US"],
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
            rendererInfo: "",
            vendorInfo: "",
            webglVersion: ""
        )
        return DeviceProfile(
            name: "Test iPhone",
            deviceHardware: hardware,
            cameras: [camera],
            microphones: [microphone],
            webFingerprint: fingerprint,
            preferredFrontCameraID: camera.id,
            preferredMicrophoneID: microphone.id
        )
    }
}
