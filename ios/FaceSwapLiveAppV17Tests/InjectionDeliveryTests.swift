import Foundation
import Testing
@testable import FaceSwapLiveAppV17

/// Guards the camera-injection delivery path. Every case here maps to a defect
/// that actually broke serving, so a regression is caught rather than rediscovered.
@MainActor
struct InjectionDeliveryTests {

    // MARK: - Frames are never gated

    @Test func theLiveFeedIsNeverPausedByAHandoff() {
        let script = StyleSheetProvider.patchScript
        // A pause switch in the render loop stopped every frame with no error and
        // no guaranteed way back: one interrupted hand-off blacked the feed out
        // for the whole session. The gate is gone from all three delivery loops.
        #expect(!script.contains("if(!s._feedHold){"))
        #expect(!script.contains("if(!s2._feedHold){"))
        // Interrupting the feed is now a no-op, so a hand-off cannot mute tracks.
        #expect(script.contains("function fslInterruptFeed(){\n            return false;\n        }"))
        // Recovery must remain available to heal a session stranded by an old build.
        #expect(script.contains("s._resumeFeed=fslResumeFeed;"))
    }

    @Test func aNewSequenceReleasesAnyStrandedHold() {
        let reset = SequenceScriptBuilder.pointerResetJS(seqVersion: 7)
        #expect(reset.contains("_resumeFeed"))
        #expect(reset.contains("s._feedHold"))
    }

    // MARK: - A live request is never starved

    @Test func reservedItemsCannotStarveALiveRequest() {
        let script = StyleSheetProvider.patchScript
        // Reserving an item for the phone camera is a preference, not a reason to
        // refuse a live request. Both live searches take a second, unfiltered pass.
        #expect(script.contains("for(var j=start;j<s.seq.length;j++){if(isMediaStep(s.seq[j]))return j;}"))
        #expect(script.contains("if(isMediaStep(st2)){s._liveFellOpen=true;return j;}"))
    }

    @Test func holdCurrentAlwaysYieldsAnItem() {
        let script = StyleSheetProvider.patchScript
        // Hold-current used to clamp to the last item; when it started returning
        // nothing it fell through to an outright refusal.
        #expect(script.contains("ci=Math.min(Math.max(0,s.pHead||0),s.seq.length-1);"))
    }

    @Test func theHoldFallbackReplaysRatherThanRefusing() {
        let script = StyleSheetProvider.patchScript
        // Narrowing the replay net to live-only served items turned a recoverable
        // request into a hard block. It now falls back to any held item, then to
        // the first servable item, before ever refusing.
        #expect(script.contains("if(s._heldLive)return{a:'serve',step:s._heldLive};"))
        #expect(script.contains("if(isMediaStep(s._held)){s._liveFellOpen=true;return{a:'serve',step:s._held};}"))
        #expect(script.contains("var fi=firstMediaFrom(0);"))
    }

    @Test func aParkedPointerWrapsBeforeGivingUp() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("if(hi<0)hi=firstLiveIndexFrom(0);"))
    }

    // MARK: - Saved answers cannot act on their own

    @Test func aSavedAnswerOnlyAppliesWhileAskMeIsOn() {
        let suite = "InjectionDeliveryTests.rule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CameraPromptStore(defaults: defaults)
        store.remember(.realCamera, for: "example.com")

        // Ask Me is off by default: a saved answer must NOT divert the request.
        // This is the gate that silently handed sites the real camera.
        #expect(store.settings.isEnabled == false)
        #expect(store.rule(for: "example.com") == nil)

        store.setEnabled(true)
        #expect(store.rule(for: "example.com") == .realCamera)
    }

    @Test func legacySavedAnswersArePurgedOnce() {
        let suite = "InjectionDeliveryTests.purge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed a rule the way an older build persisted it, then let a fresh store
        // load: answers saved before the guard existed cannot be trusted.
        let seeding = CameraPromptStore(defaults: defaults)
        seeding.remember(.block, for: "stuck.example")
        #expect(seeding.siteRules.isEmpty == false)

        let reloaded = CameraPromptStore(defaults: defaults)
        #expect(reloaded.siteRules.isEmpty)

        // A rule saved AFTER the purge survives a later launch.
        reloaded.remember(.block, for: "kept.example")
        let again = CameraPromptStore(defaults: defaults)
        #expect(again.siteRules["kept.example"] == .block)
    }

    @Test func resetClearsSavedAnswersAndTurnsAskMeOff() {
        let suite = "InjectionDeliveryTests.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CameraPromptStore(defaults: defaults)
        store.setEnabled(true)
        store.remember(.realCamera, for: "example.com")
        #expect(store.rule(for: "example.com") == .realCamera)

        store.resetToWorkingDefaults()
        #expect(store.siteRules.isEmpty)
        #expect(store.settings.isEnabled == false)
        #expect(store.rule(for: "example.com") == nil)
    }

    @Test func savedAnswerDecisionsAreRecordedForTheReport() {
        let script = StyleSheetProvider.patchScript
        // A diverted request must be explainable after the fact, not silent.
        #expect(script.contains("saved-answer-block"))
        #expect(script.contains("saved-answer-real-camera"))
    }

    // MARK: - Self-test isolation

    @Test func probeModeCannotEngageOnAPageTheUserIsBrowsing() {
        let script = StyleSheetProvider.patchScript
        // Probe mode suppresses the real capture behaviour and progress
        // reporting. It is confined to the app's own test page AND time-boxed,
        // so an interrupted diagnostic can never degrade live browsing.
        #expect(script.contains("if(!s._isHarness){s._probeMode=false;s._probeUntil=0;return false;}"))
        #expect(script.contains("_probeUntil"))
        #expect(StyleSheetProvider.harnessMarkScript.contains("_isHarness=true"))
        // Every consumer must route through the guarded check, never the raw flag.
        #expect(script.contains("var probing=fslProbing();"))
        #expect(!script.contains("var probing=!!s._probeMode;"))
    }

    // MARK: - Still photos must not look frozen

    @Test func stillPhotosAreServedWithHandheldMotion() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslDrawWithMotion"))
        #expect(script.contains("fslMotionState"))
        // Motion off must keep the exact cover-fit draw the engine always used.
        #expect(script.contains("if(!s||!s._photoMotion){"))
        // The fast putImageData path cannot be transformed, so motion has to go
        // through the source canvas instead of silently staying frozen.
        #expect(script.contains("!(st&&st._photoMotion)"))
    }

    @Test func autoAndMotionStateReachThePage() {
        let on = SequenceScriptBuilder.stateFieldsJS(
            mode: "advance",
            end: "hold",
            method: InjectionMethodKind.canvasPipeline.jsValue,
            active: true,
            autoOn: true,
            photoMotion: true
        )
        #expect(on.contains("s._autoOn=true;"))
        #expect(on.contains("s._photoMotion=true;"))
        #expect(on.contains("s._method='canvasPipeline';"))

        let off = SequenceScriptBuilder.stateFieldsJS(
            mode: "advance",
            end: "hold",
            method: InjectionMethodKind.canvasPipeline.jsValue,
            active: true
        )
        #expect(off.contains("s._autoOn=false;"))
        #expect(off.contains("s._photoMotion=false;"))
    }

    @Test func autoIsNeverHandedToThePageAsARoute() {
        // Auto is a user-facing choice, not something the engine can deliver
        // through. Only concrete routes may be pushed.
        #expect(!InjectionMethodKind.deliveryMethods.contains(.auto))
        for method in InjectionMethodKind.deliveryMethods {
            #expect(method.servesMedia)
            #expect(method.migratedCameraMethod != .auto)
        }
    }

    // MARK: - Last-resort media path

    @Test func aMissingPreparedPhotoRetriesBeforeGivingUp() {
        let script = StyleSheetProvider.patchScript
        // The fetch path is the most likely to fail, so it gets one deliberate
        // second chance and records why instead of ending in a dead camera.
        #expect(script.contains("if(isRetry){give('decode');return;}"))
        #expect(script.contains("image-"))
        #expect(script.contains("mediaPrepared"))
    }

    // MARK: - Failure recorder

    @Test func recorderIsOffByDefaultAndCapturesNothing() {
        let suite = "InjectionDeliveryTests.off.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = InjectionTraceRecorder(defaults: defaults)
        #expect(recorder.isEnabled == false)

        recorder.record(stage: .feedBuilt, reason: "ignored")
        recorder.recordFromPage(["stage": "feedBuilt", "reason": "ignored"])
        #expect(recorder.records.isEmpty)
    }

    @Test func recorderCapturesTheExactFailingStageWhenOn() {
        let suite = "InjectionDeliveryTests.on.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = InjectionTraceRecorder(defaults: defaults)
        recorder.isEnabled = true
        recorder.recordFromPage([
            "stage": "mediaPrepared",
            "surface": "native",
            "reason": "no-file-built",
            "host": "example.com",
            "method": "canvasPipeline"
        ])

        let entry = recorder.latest
        #expect(entry?.stage == .mediaPrepared)
        #expect(entry?.surface == .native)
        #expect(entry?.host == "example.com")
        #expect(entry?.summary.contains("Media prepared") == true)
        #expect(recorder.exportText.contains("mediaPrepared"))
    }

    @Test func recorderRejectsAnUnknownStageRatherThanInventingOne() {
        let suite = "InjectionDeliveryTests.unknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = InjectionTraceRecorder(defaults: defaults)
        recorder.isEnabled = true
        recorder.recordFromPage(["stage": "notARealStage"])
        #expect(recorder.records.isEmpty)
    }

    @Test func recorderKeepsHistoryBoundedAndNewestFirst() {
        let suite = "InjectionDeliveryTests.bounded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = InjectionTraceRecorder(defaults: defaults)
        recorder.isEnabled = true
        for _ in 0..<(InjectionTraceRecorder.maximumRecords + 12) {
            recorder.record(stage: .framesFlowing, reason: "r")
        }
        #expect(recorder.records.count == InjectionTraceRecorder.maximumRecords)

        recorder.record(stage: .deliveryConfirmed, reason: "newest")
        #expect(recorder.latest?.stage == .deliveryConfirmed)
    }

    @Test func recorderSurvivesRelaunchAndGroupsARepeatingCause() {
        let suite = "InjectionDeliveryTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let recorder = InjectionTraceRecorder(defaults: defaults)
        recorder.isEnabled = true
        recorder.record(stage: .feedBuilt, reason: "lane-timeout")
        recorder.record(stage: .feedBuilt, reason: "lane-timeout")
        recorder.record(stage: .queueResolved, reason: "no-servable-step")

        let reloaded = InjectionTraceRecorder(defaults: defaults)
        #expect(reloaded.isEnabled == true)
        #expect(reloaded.records.count == 3)
        // The repeating root cause has to stand out first.
        #expect(reloaded.stageTally.first?.stage == .feedBuilt)
        #expect(reloaded.stageTally.first?.count == 2)
    }

    @Test func everyStageExplainsItselfInPlainLanguage() {
        for stage in InjectionTraceStage.allCases {
            #expect(!stage.title.isEmpty)
            #expect(!stage.failureMeaning.isEmpty)
            #expect(!stage.iconName.isEmpty)
        }
        // Ordering must follow the real request lifecycle.
        #expect(InjectionTraceStage.takeoverInstalled.order < InjectionTraceStage.requestSeen.order)
        #expect(InjectionTraceStage.queueResolved.order < InjectionTraceStage.mediaPrepared.order)
        #expect(InjectionTraceStage.feedBuilt.order < InjectionTraceStage.framesFlowing.order)
        #expect(InjectionTraceStage.framesFlowing.order < InjectionTraceStage.deliveryConfirmed.order)
    }

    // MARK: - Page reporting stays silent unless asked

    @Test func pageReporterIsSilentUntilSwitchedOn() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("if(!s||!s._traceOn||s._isHarness)return;"))
        #expect(StyleSheetProvider.failureRecorderApplyScript(enabled: false).contains("_traceOn=false"))
        #expect(StyleSheetProvider.failureRecorderApplyScript(enabled: true).contains("_traceOn=true"))
    }
}
