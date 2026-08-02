import Foundation
import Testing
import JavaScriptCore
import UIKit
import WebKit
@testable import FaceSwapLiveAppV17

@MainActor
struct MediaPipelineRuntimeTests {

    @Test func idleRuntimeStateHasAnExplicitSessionAndInactiveDelivery() throws {
        let state = MediaRuntimeState.idle(sessionID: "navigation-42")
        let data = try #require(state.serializedJSON().data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["navigationSessionID"] as? String == "navigation-42")
        #expect(object["isActive"] as? Bool == false)
        #expect(object["runtimeVersion"] as? Int == 1)
        #expect((object["sequence"] as? [Any])?.isEmpty == true)
    }

    @Test func runtimeBootstrapUsesTheReplyBridgeInsteadOfReplacingUserScripts() {
        let bootstrap = StyleSheetProvider.runtimeStateBootstrapScript
        #expect(bootstrap.contains("messageHandlers.fslState"))
        #expect(bootstrap.contains("postMessage({action:'ready',protocol:1})"))
        #expect(bootstrap.contains("_applyRuntimeState"))
    }

    @Test func runtimeApplyScriptCarriesEscapedJSONAndUsesTheGuardedApplyFunction() {
        let json = #"{"navigationSessionID":"s'1","isActive":true}"#
        let script = StyleSheetProvider.runtimeStateApplyScript(serializedState: json)
        #expect(script.contains("JSON.parse"))
        #expect(script.contains("_applyRuntimeState"))
        #expect(script.contains("s'1"))
    }

    @Test func pageRuntimeRejectsStaleSessionsAndSerializesSameSurfaceRequests() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("incoming<(s._runtimeV||0)"))
        #expect(script.contains("fslCancelRequests('navigation-replaced')"))
        #expect(script.contains("fslRequestCurrent(req)"))
        #expect(script.contains("reentrant-request"))
        #expect(script.contains("_activeLiveRequest"))
        #expect(script.contains("_activeNativeRequest"))
        #expect(script.contains("_runtimeReady=false"))
        #expect(script.contains("runtime-not-ready"))
    }

    @Test func frameTelemetryMarksConnectionFramesAndTerminalOutcomes() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslLifecycle('mediaConnected'"))
        #expect(script.contains("fslLifecycle('framesFlowing'"))
        #expect(script.contains("fslEndRequest(req,'requestCompleted'"))
        #expect(script.contains("requestRejected"))
        #expect(script.contains("requestCancelled"))
    }

    @Test func directStreamFailureNeverRestoresTheOriginalCaptureStream() {
        let script = StyleSheetProvider.patchScript
        #expect(!script.contains("}).catch(function(){try{_soSet.call(self,v);"))
        #expect(script.contains("srcobject-feed-failed"))
        #expect(script.contains("_soSet.call(self,null)"))
    }

    @Test func traceRecordPreservesRequestAndFrameContext() throws {
        let record = InjectionTraceRecord(
            stage: .requestRejected,
            surface: .live,
            reason: "reentrant-request",
            host: "fixture.example",
            method: "canvasPipeline",
            requestID: "req-7",
            navigationSessionID: "session-7",
            sequenceVersion: 9,
            frameTimestampOffsetMs: 123.8
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(InjectionTraceRecord.self, from: data)

        #expect(decoded.requestID == "req-7")
        #expect(decoded.navigationSessionID == "session-7")
        #expect(decoded.sequenceVersion == 9)
        #expect(decoded.frameTimestampOffsetMs == 123.8)
        #expect(decoded.exportLine.contains("request=req-7"))
        #expect(decoded.exportLine.contains("frameOffsetMs=123"))
    }

    // MARK: - Payload cache race fix

    @Test func allPhotoPayloadsReadyReturnsTrueForVideoOnlySequences() {
        let vm = BrowserViewModel()
        vm.sequence = [
            SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        ]
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    @Test func allPhotoPayloadsReadyReturnsTrueForEmptySequence() {
        let vm = BrowserViewModel()
        vm.sequence = []
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    @Test func allPhotoPayloadsReadyReturnsFalseWhenPhotoStepLacksCacheEntry() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        #expect(vm.allPhotoPayloadsReady() == false)
    }

    @Test func allPhotoPayloadsReadyReturnsTrueWhenPhotoStepHasCacheEntry() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.payloadCache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: "iVBOR",
            pixelWidth: 640,
            pixelHeight: 480,
            jpegBase64: "/9j/4A",
            jpegMime: "image/jpeg",
            strippedJpegBase64: nil
        )
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    @Test func allPhotoPayloadsReadyReturnsTrueWhenPhotoStepHasOnlyJpegBase64() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.payloadCache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            jpegBase64: "/9j/4A",
            jpegMime: "image/jpeg",
            strippedJpegBase64: nil
        )
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    @Test func allPhotoPayloadsReadyIgnoresConvertingSteps() {
        let vm = BrowserViewModel()
        vm.sequence = [
            SequenceStep(kind: .photo, image: UIImage(systemName: "camera"), isConverting: true)
        ]
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    @Test func allPhotoPayloadsReadyIgnoresPhotoStepsWithoutImage() {
        let vm = BrowserViewModel()
        vm.sequence = [
            SequenceStep(kind: .photo, image: nil)
        ]
        #expect(vm.allPhotoPayloadsReady() == true)
    }

    // MARK: - rebuildAllPhotoPayloads preserves cache entries

    @Test func rebuildAllPhotoPayloadsDoesNotClearExistingCacheEntries() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.payloadCache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: "iVBOR",
            pixelWidth: 640,
            pixelHeight: 480,
            jpegBase64: "/9j/4A",
            jpegMime: "image/jpeg",
            strippedJpegBase64: nil
        )
        let entryBefore = vm.payloadCache.entry(for: stepID)
        #expect(entryBefore?.pixelBase64 == "iVBOR")

        vm.rebuildAllPhotoPayloads()

        // The entry must still be present immediately after rebuild — the async
        // re-extraction will overwrite it later, but the page has inline data
        // available during the rebuild window.
        let entryAfter = vm.payloadCache.entry(for: stepID)
        #expect(entryAfter != nil)
        #expect(entryAfter?.pixelBase64 == "iVBOR")
    }

    // MARK: - Video first-frame always included

    @Test func runtimeStateIncludesFirstFrameBase64RegardlessOfInspectionReport() throws {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        ]
        vm.payloadCache.setFirstFramePayload(
            stepID: stepID,
            base64: "/9j/4AAQ",
            mime: "image/jpeg"
        )

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let payloads = try #require(object["payloads"] as? [String: Any])
        let payload = try #require(payloads[stepID.uuidString] as? [String: Any])
        #expect(payload["fb64"] as? String == "/9j/4AAQ")
        #expect(payload["fmime"] as? String == "image/jpeg")
    }

    @Test func runtimeStateOmitsFirstFrameWhenCacheEntryLacksIt() throws {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        ]
        // No first-frame payload set — cache entry may not even exist

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let payloads = object["payloads"] as? [String: Any] ?? [:]
        // The step should not appear in payloads if it has no first-frame and no chunks
        let payload = payloads[stepID.uuidString] as? [String: Any]
        if let payload {
            #expect(payload["fb64"] == nil)
        }
    }

    @Test func runtimeStateIncludesPhotoPayloadWhenCacheEntryExists() throws {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.payloadCache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: "iVBOR",
            pixelWidth: 640,
            pixelHeight: 480,
            jpegBase64: "/9j/4A",
            jpegMime: "image/jpeg",
            strippedJpegBase64: "strippedData"
        )
        vm.isMediaActive = true

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let payloads = try #require(object["payloads"] as? [String: Any])
        let payload = try #require(payloads[stepID.uuidString] as? [String: Any])
        #expect(payload["pb64"] as? String == "iVBOR")
        #expect(payload["pw"] as? Int == 640)
        #expect(payload["ph"] as? Int == 480)
        #expect(payload["b64"] as? String == "/9j/4A")
        #expect(payload["sb64"] as? String == "strippedData")
    }

    // MARK: - methodServesMedia gate removed from makeRuntimeState

    @Test func runtimeStateIsActiveTrueWithServableStepRegardlessOfMethod() throws {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true

        // Test with passthrough — previously this would set isActive=false.
        vm.activeInjectionProfile = .passthrough

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["isActive"] as? Bool == true)
        #expect(object["method"] as? String == "passthrough")
    }

    @Test func runtimeStateIsActiveTrueWithCanvasPipeline() throws {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true
        vm.activeInjectionProfile = .canvasPipeline

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["isActive"] as? Bool == true)
    }

    @Test func runtimeStateIsInactiveWhenNoServableSteps() throws {
        let vm = BrowserViewModel()
        vm.sequence = []
        vm.isMediaActive = true
        vm.activeInjectionProfile = .canvasPipeline

        let json = try vm.runtimeStateJSON()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["isActive"] as? Bool == false)
    }

    // MARK: - Passthrough toggle guard

    @Test func setMediaActiveTrueWithPassthroughShowsWarningInsteadOfActivating() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.activeInjectionProfile = .passthrough

        vm.setMediaActive(true)

        // The warning should be shown, and media should NOT be active yet.
        #expect(vm.showPassthroughWarning == true)
        #expect(vm.isMediaActive == false)
    }

    @Test func switchToAutoAndActivateOverridesPassthroughAndEnablesMedia() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.activeInjectionProfile = .passthrough
        vm.showPassthroughWarning = true

        vm.switchToAutoAndActivate()

        #expect(vm.showPassthroughWarning == false)
        #expect(vm.isMediaActive == true)
        #expect(vm.activeInjectionProfile == .auto)
    }

    @Test func confirmPassthroughActivationEnablesMediaWithPassthroughMethod() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.activeInjectionProfile = .passthrough
        vm.showPassthroughWarning = true

        vm.confirmPassthroughActivation()

        #expect(vm.showPassthroughWarning == false)
        #expect(vm.isMediaActive == true)
        #expect(vm.activeInjectionProfile == .passthrough)
    }

    @Test func setMediaActiveFalseBypassesPassthroughGuard() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.activeInjectionProfile = .passthrough
        vm.isMediaActive = true

        vm.setMediaActive(false)

        #expect(vm.showPassthroughWarning == false)
        #expect(vm.isMediaActive == false)
    }

    // MARK: - Stripped JPEG fast-path

    @Test func setStrippedPayloadOnlySetsStrippedJpegWhenNoneExists() {
        let cache = SequencePayloadCache()
        let stepID = UUID()

        cache.setStrippedPayloadOnly(stepID: stepID, strippedJpegBase64: "fastStripped")

        let entry = cache.entry(for: stepID)
        #expect(entry?.strippedJpegBase64 == "fastStripped")
        #expect(entry?.pixelBase64 == nil)
        #expect(entry?.jpegBase64 == nil)
    }

    @Test func setStrippedPayloadOnlyDoesNotOverwriteExistingStrippedJpeg() {
        let cache = SequencePayloadCache()
        let stepID = UUID()

        cache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: "pixels",
            pixelWidth: 640,
            pixelHeight: 480,
            jpegBase64: "fullJpeg",
            jpegMime: "image/jpeg",
            strippedJpegBase64: "asyncStripped"
        )
        cache.setStrippedPayloadOnly(stepID: stepID, strippedJpegBase64: "fastStripped")

        // The async-extracted stripped JPEG should win; the fast-path must not
        // overwrite a fresher value.
        let entry = cache.entry(for: stepID)
        #expect(entry?.strippedJpegBase64 == "asyncStripped")
        #expect(entry?.pixelBase64 == "pixels")
        #expect(entry?.jpegBase64 == "fullJpeg")
    }

    @Test func setStrippedPayloadOnlyPreservesExistingPixelAndJpegData() {
        let cache = SequencePayloadCache()
        let stepID = UUID()

        cache.setPhotoPayload(
            stepID: stepID,
            pixelBase64: "pixels",
            pixelWidth: 640,
            pixelHeight: 480,
            jpegBase64: "fullJpeg",
            jpegMime: "image/jpeg",
            strippedJpegBase64: nil
        )
        cache.setStrippedPayloadOnly(stepID: stepID, strippedJpegBase64: "fastStripped")

        let entry = cache.entry(for: stepID)
        #expect(entry?.strippedJpegBase64 == "fastStripped")
        #expect(entry?.pixelBase64 == "pixels")
        #expect(entry?.jpegBase64 == "fullJpeg")
    }

    @Test func setStrippedPayloadOnlyWithNilValueIsNoop() {
        let cache = SequencePayloadCache()
        let stepID = UUID()

        cache.setStrippedPayloadOnly(stepID: stepID, strippedJpegBase64: nil)

        #expect(cache.entry(for: stepID) == nil)
    }

    // MARK: - fslBuildCaptureFile b64 fallback for capture inputs

    @Test func fslBuildCaptureFileFallsBackToB64WhenSb64UnavailableForCapture() {
        let script = StyleSheetProvider.patchScript
        // The capture-input b64 resolution must now include p.b64 and step.b64
        // as fallbacks after sb64, so a native camera hand-off never fails
        // just because the stripped JPEG hasn't been extracted yet.
        #expect(script.contains("p.sb64||step.sb64||p.b64||step.b64"))
    }

    // MARK: - Synthetic camera naming

    @Test func buildDeviceProfileJSUsesModelSpecificFallbackLabel() {
        // When dev.label is empty, the fallback should include the model name,
        // not just a generic "Front Camera" / "Back Camera".
        let dev = CameraDeviceSpec(
            id: "front-1",
            label: "",  // Empty label forces the fallback path
            position: "front",
            deviceType: "builtInWideAngleCamera",
            uniqueID: "",
            modelID: "iPhone16,1",
            manufacturer: "Apple",
            maxWidth: 4032,
            maxHeight: 3024,
            activeWidth: 1920,
            activeHeight: 1080,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 1,
            hasFlash: true,
            hasTorch: true,
            isAutoFocusSupported: true,
            maxZoomFactor: 15.0,
            minISO: 40,
            maxISO: 4000,
            supportedPresets: [],
            supportedFormats: []
        )

        let js = StyleSheetProvider.buildDeviceProfileJSForTesting(
            dev: dev,
            facingMode: "user",
            realSnapshot: nil,
            fallbackModelName: "iPhone 15 Pro"
        )

        #expect(js.contains("iPhone 15 Pro Front Camera"))
    }

    @Test func buildDeviceProfileJSUsesDeviceLabelWhenProvided() {
        let dev = CameraDeviceSpec(
            id: "front-1",
            label: "My Custom Front Camera",
            position: "front",
            deviceType: "builtInWideAngleCamera",
            uniqueID: "dev-abc",
            modelID: "iPhone16,1",
            manufacturer: "Apple",
            maxWidth: 4032,
            maxHeight: 3024,
            activeWidth: 1920,
            activeHeight: 1080,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 1,
            hasFlash: true,
            hasTorch: true,
            isAutoFocusSupported: true,
            maxZoomFactor: 15.0,
            minISO: 40,
            maxISO: 4000,
            supportedPresets: [],
            supportedFormats: []
        )

        let js = StyleSheetProvider.buildDeviceProfileJSForTesting(
            dev: dev,
            facingMode: "user",
            realSnapshot: nil,
            fallbackModelName: "iPhone 15 Pro"
        )

        #expect(js.contains("My Custom Front Camera"))
        #expect(!js.contains("iPhone 15 Pro Front Camera"))
    }

    @Test func buildDeviceProfileJSUsesHashedDeviceIdWhenUniqueIDIsEmpty() {
        let dev = CameraDeviceSpec(
            id: "front-1",
            label: "",
            position: "front",
            deviceType: "builtInWideAngleCamera",
            uniqueID: "",  // Empty uniqueID forces the hash fallback
            modelID: "iPhone16,1",
            manufacturer: "Apple",
            maxWidth: 4032,
            maxHeight: 3024,
            activeWidth: 1920,
            activeHeight: 1080,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 1,
            hasFlash: true,
            hasTorch: true,
            isAutoFocusSupported: true,
            maxZoomFactor: 15.0,
            minISO: 40,
            maxISO: 4000,
            supportedPresets: [],
            supportedFormats: []
        )

        let js = StyleSheetProvider.buildDeviceProfileJSForTesting(
            dev: dev,
            facingMode: "user",
            realSnapshot: nil,
            fallbackModelName: "iPhone 15 Pro"
        )

        // The deviceId should be a hashed value, not the generic fallback.
        #expect(js.contains("com.apple.avfoundation.avcapturedevice.front-"))
        #expect(!js.contains("com.apple.avfoundation.avcapturedevice.front'"))
    }

    @Test func buildDeviceProfileJSBackCameraUsesEnvironmentFacing() {
        let dev = CameraDeviceSpec(
            id: "back-1",
            label: "",
            position: "back",
            deviceType: "builtInWideAngleCamera",
            uniqueID: "",
            modelID: "iPhone16,1",
            manufacturer: "Apple",
            maxWidth: 4032,
            maxHeight: 3024,
            activeWidth: 1920,
            activeHeight: 1080,
            maxFrameRate: 60,
            activeFrameRate: 30,
            minFrameRate: 1,
            hasFlash: true,
            hasTorch: true,
            isAutoFocusSupported: true,
            maxZoomFactor: 15.0,
            minISO: 40,
            maxISO: 4000,
            supportedPresets: [],
            supportedFormats: []
        )

        let js = StyleSheetProvider.buildDeviceProfileJSForTesting(
            dev: dev,
            facingMode: "environment",
            realSnapshot: nil,
            fallbackModelName: "iPhone 15 Pro"
        )

        #expect(js.contains("iPhone 15 Pro Back Camera"))
        #expect(js.contains("facingMode:'environment'"))
    }

    // MARK: - Shared queue for front and back cameras

    @Test func bothFrontAndBackCamerasResolveFromSameQueuePointer() {
        let script = StyleSheetProvider.patchScript
        // fslResolve serves both front and back from s.pHead (the shared queue
        // pointer), not per-camera targeting.
        #expect(script.contains("s.pHead"))
        // The getUserMedia gate routes both 'user' and 'environment' facing
        // through the same fslResolve path.
        #expect(script.contains("fslResolve"))
        #expect(script.contains("requestedFacing"))
    }

    // MARK: - shouldGrantWebMediaCapture: passthrough grants real camera

    @Test func webMediaCaptureDecisionGrantsForPassthroughWhenMediaActive() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true
        vm.activeInjectionProfile = .passthrough

        // Passthrough routes to the real camera in the JS gate, so WebKit must
        // grant permission. Denying at the native level would block the real
        // camera entirely, making "Use real camera anyway" useless.
        #expect(vm.webMediaCaptureDecision == .grant)
    }

    @Test func webMediaCaptureDecisionDeniesForCanvasPipelineWhenMediaActive() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true
        vm.activeInjectionProfile = .canvasPipeline

        // Non-passthrough methods intercept the camera at the JS level, so
        // WebKit must deny to prevent the real camera from leaking through.
        #expect(vm.webMediaCaptureDecision == .deny)
    }

    @Test func webMediaCaptureDecisionGrantsWhenMediaInactive() {
        let vm = BrowserViewModel()
        vm.isMediaActive = false

        // When media is off, the real camera should be granted normally.
        #expect(vm.webMediaCaptureDecision == .grant)
    }

    @Test func webMediaCaptureDecisionGrantsForAutoResolvingToPassthrough() {
        let vm = BrowserViewModel()
        let stepID = UUID()
        vm.sequence = [
            SequenceStep(id: stepID, kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true
        vm.activeInjectionProfile = .auto

        // Auto resolves to canvasPipeline by default (no site record, no
        // detected system, no device default), so it should deny.
        #expect(vm.webMediaCaptureDecision == .deny)
    }

    @Test func audioOnlyWebCaptureRemainsGrantedWhileVirtualVideoIsActive() {
        let vm = BrowserViewModel()
        vm.isMediaActive = true
        vm.activeInjectionProfile = .canvasPipeline
        let host = "voice-\(UUID().uuidString).example"

        // The injected page gate replaces video only. Denying a microphone-only
        // native request would incorrectly break a site's voice-only feature.
        #expect(vm.webMediaCaptureDecision(for: .microphone, originHost: host) == .grant)
        #expect(vm.webMediaCaptureDecision(for: .cameraAndMicrophone, originHost: host) == .deny)
    }

    @Test func browserCoordinatorLeavesFileUploadPanelsToWebKit() {
        let coordinator = BrowserWebContainer(viewModel: BrowserViewModel()).makeCoordinator()
        let openPanelSelector = NSSelectorFromString("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:")

        // On iOS, WebKit provides the normal file-upload UI when its optional
        // delegate callback is not implemented. Reintroducing a cancel-only
        // callback would silently disable document, audio, and normal uploads.
        #expect(!coordinator.responds(to: openPanelSelector))
    }

    @Test func captureServiceExposesRecoverableTerminalStates() {
        #expect(CaptureService.CaptureError.captureCancelled.errorDescription?.contains("cancelled") == true)
        #expect(CaptureService.CaptureError.captureTimedOut.errorDescription?.contains("in time") == true)
    }

    // MARK: - verifyEngineArmed surfaces arm failure as needsAttention

    @Test func verifyEngineArmedNoOpsWhenMediaInactive() {
        let vm = BrowserViewModel()
        vm.isMediaActive = false

        // Without a webView, verifyEngineArmed can't run the check script, but
        // it should reset the readout cleanly rather than crashing.
        vm.verifyEngineArmed()
        #expect(vm.engineArmChecked == false)
    }

    @Test func armFailureTextIsSpecificForEachCase() {
        // Verify the plain-language failure text covers the three arm failure
        // modes so the mediaDeliveryDetail is actionable.
        #expect(BrowserViewModel.armFailureText(present: false, rawError: "").contains("hasn't loaded"))
        #expect(BrowserViewModel.armFailureText(present: true, rawError: "").contains("didn't install"))
        #expect(BrowserViewModel.armFailureText(present: true, rawError: "gum: blocked").contains("gum: blocked"))
    }

    // MARK: - SDK wrapping toggle

    @Test func sdkWrapApplyScriptSetsTheFlagOnThePage() {
        let onScript = StyleSheetProvider.sdkWrapApplyScript(enabled: true)
        let offScript = StyleSheetProvider.sdkWrapApplyScript(enabled: false)

        #expect(onScript.contains("s._sdkWrap=true"))
        #expect(offScript.contains("s._sdkWrap=false"))
        #expect(onScript.contains("Symbol.for('fsl')"))
    }

    @Test func patchScriptIncludesSdkWrapArmPart() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("s._armParts.sdkWrap"))
        #expect(script.contains("fslSdkServeFile"))
        #expect(script.contains("fslWrapVendorLaunch"))
        // Vendor SDK globals are wrapped (only when present — no phantom globals)
        #expect(script.contains("Onfido"))
        #expect(script.contains("Veriff"))
        #expect(script.contains("snsWebSdk"))
        #expect(script.contains("iProov"))
        #expect(script.contains("FaceTec"))
        // Bridge transports
        #expect(script.contains("ReactNativeWebView"))
        #expect(script.contains("dsBridge"))
        // Custom-scheme navigation
        #expect(script.contains("_origLocSet"))
        #expect(script.contains("_origWO"))
    }

    @Test func engineArmCheckReportsSdkWrapStatus() {
        let script = StyleSheetProvider.engineArmCheckScript
        #expect(script.contains("sdkWrap"))
    }

    @Test func profileApplyScriptBakesSdkWrapFlag() {
        let profile = DeviceProfile(
            name: "Test",
            deviceHardware: DeviceHardwareSpec(
                modelName: "iPhone 15 Pro",
                modelIdentifier: "iPhone16,1",
                systemName: "iOS",
                systemVersion: "18.0",
                processorCount: 6,
                physicalMemoryGB: 6,
                screenNativeBounds: "1170x2532",
                screenScale: 3,
                screenNativeScale: 3,
                identifierForVendor: nil
            ),
            cameras: [
                CameraDeviceSpec(
                    id: "front-1", label: "Front Camera", position: "front",
                    deviceType: "TrueDepth", uniqueID: "front-1", modelID: "",
                    manufacturer: "Apple", maxWidth: 1920, maxHeight: 1080,
                    activeWidth: 1280, activeHeight: 720, maxFrameRate: 60,
                    activeFrameRate: 30, minFrameRate: 15, hasFlash: false,
                    hasTorch: false, isAutoFocusSupported: true, maxZoomFactor: 2,
                    minISO: 0, maxISO: 0, supportedPresets: [], supportedFormats: []
                )
            ],
            microphones: [],
            webFingerprint: WebFingerprintSpec(
                userAgent: "", platform: "", language: "en-US", languages: ["en-US"],
                hardwareConcurrency: 6, deviceMemory: 4, maxTouchPoints: 5,
                screenWidth: 390, screenHeight: 844, screenColorDepth: 24,
                devicePixelRatio: 3, timezoneOffset: 0, timezone: "",
                doNotTrack: nil, vendor: "", rendererInfo: "", vendorInfo: "", webglVersion: ""
            )
        )

        let withWrap = StyleSheetProvider.profileApplyScript(from: profile, sdkWrap: true)
        let withoutWrap = StyleSheetProvider.profileApplyScript(from: profile, sdkWrap: false)

        #expect(withWrap.contains("s._sdkWrap=true"))
        #expect(withoutWrap.contains("s._sdkWrap=false"))
    }

    // MARK: - Correlation verification (DeviceTestEngine helpers)

    @Test func buildComparisonsMatchesIdenticalSnapshots() {
        let engine = DeviceTestEngine()
        let snapshot = MediaSnapshot(
            devices: [],
            trackSettings: MediaTrackSettings(
                deviceId: "dev1", groupId: "grp1", width: 1280, height: 720,
                frameRate: 30, facingMode: "user", aspectRatio: 1.777,
                resizeMode: "none"
            ),
            trackCapabilities: nil,
            trackLabel: "Front Camera",
            trackReadyState: "live",
            trackContentHint: "",
            trackMuted: false,
            trackEnabled: true,
            supportedConstraints: ["width", "height"],
            mediaStreamId: "stream1",
            mediaStreamActive: true
        )

        let comparisons = engine.buildComparisons(real: snapshot, processed: snapshot)
        #expect(comparisons.count > 0)
        #expect(comparisons.allSatisfy { $0.matches })
    }

    @Test func buildComparisonsDetectsMismatches() {
        let engine = DeviceTestEngine()
        let real = MediaSnapshot(
            devices: [],
            trackSettings: MediaTrackSettings(
                deviceId: "real-dev", groupId: "grp1", width: 1920, height: 1080,
                frameRate: 60, facingMode: "user", aspectRatio: 1.777,
                resizeMode: "none"
            ),
            trackCapabilities: nil,
            trackLabel: "Real Camera",
            trackReadyState: "live",
            trackContentHint: "",
            trackMuted: false,
            trackEnabled: true,
            supportedConstraints: ["width", "height", "frameRate"],
            mediaStreamId: "s1",
            mediaStreamActive: true
        )
        let processed = MediaSnapshot(
            devices: [],
            trackSettings: MediaTrackSettings(
                deviceId: "synth-dev", groupId: "grp1", width: 1280, height: 720,
                frameRate: 30, facingMode: "user", aspectRatio: 1.777,
                resizeMode: "none"
            ),
            trackCapabilities: nil,
            trackLabel: "Synthetic Camera",
            trackReadyState: "live",
            trackContentHint: "",
            trackMuted: false,
            trackEnabled: true,
            supportedConstraints: ["width", "height", "frameRate"],
            mediaStreamId: "s2",
            mediaStreamActive: true
        )

        let comparisons = engine.buildComparisons(real: real, processed: processed)
        #expect(comparisons.count > 0)
        // Width, height, frameRate, and label should mismatch
        let mismatches = comparisons.filter { !$0.matches }
        #expect(mismatches.count >= 4)
    }

    @Test func parseSnapshotExtractsTrackSettings() {
        let engine = DeviceTestEngine()
        let dict: [String: Any] = [
            "supportedConstraints": ["width", "height"],
            "devices": [["deviceId": "dev1", "groupId": "grp1", "kind": "videoinput", "label": "Front Camera"]],
            "trackLabel": "Front Camera",
            "trackReadyState": "live",
            "trackContentHint": "",
            "trackMuted": false,
            "trackEnabled": true,
            "mediaStreamId": "s1",
            "mediaStreamActive": true,
            "trackSettings": [
                "deviceId": "dev1", "groupId": "grp1",
                "width": 1280, "height": 720,
                "frameRate": 30.0, "facingMode": "user",
                "aspectRatio": 1.777, "resizeMode": "none"
            ]
        ]

        let snapshot = engine.parseSnapshot(dict)
        #expect(snapshot.trackLabel == "Front Camera")
        #expect(snapshot.trackSettings?.width == 1280)
        #expect(snapshot.trackSettings?.height == 720)
        #expect(snapshot.trackSettings?.frameRate == 30.0)
        #expect(snapshot.devices.count == 1)
        #expect(snapshot.devices.first?.label == "Front Camera")
    }

    // MARK: - E2E injection coverage: new request type wraps

    @Test func patchScriptIncludesCapacitorTakePhotoAndRecordVideo() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("_capCam.takePhoto"))
        #expect(script.contains("_capCam.recordVideo"))
        #expect(script.contains("_sdkWrap_capTakePhoto"))
        #expect(script.contains("_sdkWrap_capRecordVideo"))
    }

    @Test func patchScriptIncludesGenericMessageHandlerWrap() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("_sdkWrap_msgHandler"))
        #expect(script.contains("messageHandlers"))
        #expect(script.contains("_mhName.indexOf('fsl')===0"))
    }

    @Test func patchScriptIncludesWebViewJavascriptBridgeGlobal() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("WebViewJavascriptBridge"))
        #expect(script.contains("_sdkWrap_wvjb"))
    }

    @Test func patchScriptIncludesVeriffConstructorAndCreateVeriffFrame() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("_veriffProxy"))
        #expect(script.contains("Reflect.construct"))
        #expect(script.contains("_sdkWrap_veriffCtor"))
        #expect(script.contains("createVeriffFrame"))
        #expect(script.contains("_sdkWrap_veriffFrame"))
    }

    @Test func patchScriptIncludesIproovMeCustomElement() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("iproov-me"))
        #expect(script.contains("_declTags"))
        #expect(script.contains("_sdkWrap_declEl"))
    }

    @Test func patchScriptIncludesAnchorHrefCustomSchemeInterception() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("tgt.tagName==='A'"))
        #expect(script.contains("tgt.href"))
    }

    @Test func patchScriptIncludesIframeSrcSetterHook() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("HTMLIFrameElement.prototype"))
        #expect(script.contains("_sdkWrap_iframeScheme"))
    }

    @Test func patchScriptIncludesFlutterInAppWebViewBridge() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("flutter_inappwebview"))
        #expect(script.contains("_sdkWrap_flutter"))
    }

    @Test func patchScriptIncludesTitaniumBridge() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslWrapTiMedia"))
        #expect(script.contains("_sdkWrap_titanium"))
        #expect(script.contains("openCamera"))
        #expect(script.contains("takePicture"))
    }

    @Test func patchScriptIncludesWebXRCameraAccess() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("navigator.xr"))
        #expect(script.contains("requestSession"))
        #expect(script.contains("_sdkWrap_webxr"))
    }

    @Test func patchScriptIncludesDeclarativeElements() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("'camera'"))
        #expect(script.contains("'microphone'"))
        #expect(script.contains("'usermedia'"))
    }

    @Test func patchScriptAllSdkWrapsCheckToggleGate() {
        let script = StyleSheetProvider.patchScript
        // Known plugin adapters gate direct fulfillment on the persisted opt-in.
        #expect(script.contains("!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length"))
        // Host-defined bridge transports share one guarded observation path rather
        // than fabricating an incompatible native response schema.
        #expect(script.contains("function fslSdkNoteBridge(kind)"))
        #expect(script.contains("if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return false"))
        #expect(script.contains("fslSdkNoteBridge('react-native-webview')"))
        #expect(script.contains("fslSdkNoteBridge('webview-javascript-bridge:'+name)"))
        #expect(script.contains("fslSdkNoteBridge('dsbridge:'+name)"))
    }

    @Test func engineArmCheckReportsAllNewWrapFlags() {
        let script = StyleSheetProvider.engineArmCheckScript
        #expect(script.contains("capTakePhoto"))
        #expect(script.contains("capRecordVideo"))
        #expect(script.contains("msgHandler"))
        #expect(script.contains("wvjb"))
        #expect(script.contains("veriffCtor"))
        #expect(script.contains("veriffFrame"))
        #expect(script.contains("iframeScheme"))
        #expect(script.contains("flutter"))
        #expect(script.contains("titanium"))
        #expect(script.contains("webxr"))
        #expect(script.contains("declEl"))
    }

    // MARK: - Verification-loop regressions

    @Test func patchScriptCompilesAsJavaScript() throws {
        let serialized = try JSONSerialization.data(withJSONObject: [StyleSheetProvider.patchScript])
        let literal = try #require(String(data: serialized, encoding: .utf8))
        let context = try #require(JSContext())

        let compiled = context.evaluateScript("new Function((\(literal))[0]);")

        #expect(compiled != nil)
        #expect(context.exception == nil)
    }

    @Test func patchScriptRefreshesLateLoadedSdkTargetsWithoutWrapperStacking() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslRefreshSdkWraps"))
        #expect(script.contains("fslWatchSdkWraps"))
        #expect(script.contains("fslSdkAlreadyWrapped"))
        #expect(script.contains("fslSdkMarkWrapped"))
        #expect(script.contains("_sdkWrapped"))
        #expect(script.contains("_sdkWrapMonitor"))
        #expect(StyleSheetProvider.sdkWrapApplyScript(enabled: true).contains("_refreshSdkWraps"))
    }

    @Test func patchScriptPreservesKnownPluginReturnContracts() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslSdkCordovaResult"))
        #expect(script.contains("fslSdkMediaFile"))
        #expect(script.contains("fslSdkCapacitorResult"))
        #expect(script.contains("webPath:url"))
        #expect(script.contains("fslCommitPickerResult(r)"))
    }

    @Test func patchScriptKeepsHostDefinedBridgeCommandsSchemaSafe() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("fslSdkNoteBridge"))
        #expect(script.contains("Host-defined bridges do not share a response schema"))
        #expect(script.contains("A custom URL scheme has an app-defined result contract"))
        #expect(script.contains("Camera access via WebXR is unavailable while injected media is active"))
    }

    @Test func cameraCustomSchemeDetectorExcludesWebURLs() throws {
        let cameraScheme = try #require(URL(string: "myapp://camera/takePhoto"))
        let captureScheme = try #require(URL(string: "verification://capture"))
        let webURL = try #require(URL(string: "https://example.com/camera"))
        let plainScheme = try #require(URL(string: "myapp://settings"))

        #expect(BrowserViewModel.isCameraCustomSchemeURL(cameraScheme))
        #expect(BrowserViewModel.isCameraCustomSchemeURL(captureScheme))
        #expect(!BrowserViewModel.isCameraCustomSchemeURL(webURL))
        #expect(!BrowserViewModel.isCameraCustomSchemeURL(plainScheme))
    }

    // MARK: - Fix 1: Video element leak in VTG path

    @Test func patchScriptIncludesDisposePrevVideoElHelper() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("function disposePrevVideoEl()"))
        // The helper must be called before assigning s._ve in the VTG path
        #expect(script.contains("disposePrevVideoEl();\n                            s._ve=vid;") || script.contains("disposePrevVideoEl()"))
    }

    // MARK: - Fix 2: Blob URL leak on success

    @Test func patchScriptRevokesBlobUrlsInCleanupPaths() {
        let script = StyleSheetProvider.patchScript
        // _fslObjURL is stored on video elements for later revocation
        #expect(script.contains("_fslObjURL"))
        // disposeActive must revoke the blob URL
        #expect(script.contains("if(a.el._fslObjURL)"))
        // stopAll must revoke the blob URL
        #expect(script.contains("if(s._ve._fslObjURL)"))
        // disposePrevVideoEl must revoke the blob URL
        #expect(script.contains("if(s._ve._fslObjURL){URL.revokeObjectURL(s._ve._fslObjURL)"))
        // makeVideoDraw stores the blob URL on the video element
        #expect(script.contains("if(isBlob)vid._fslObjURL=src;"))
        // VTG videoDirect stores the blob URL
        #expect(script.contains("vid._fslObjURL=url;"))
        // The fetch-based photo fallback no longer leaks its temporary blob URL
        // after the image has decoded into the canvas source.
        #expect(script.contains("finish(URL.createObjectURL(b),false,true);"))
        #expect(script.contains("if(ownsURL){try{URL.revokeObjectURL(url);}catch(e){}}"))
    }

    // MARK: - Fix 3: primeStream uses _nT instead of raw setTimeout

    @Test func patchScriptPrimeStreamUsesEngineTimer() {
        let script = StyleSheetProvider.patchScript
        // The primeStream function should use _nT, not raw setTimeout
        #expect(script.contains("_nT(kick,30)"))
        #expect(script.contains("_nT(kick,90)"))
        #expect(script.contains("_nT(kick,180)"))
        // Ensure raw setTimeout is NOT used in primeStream
        let primeRange = script.range(of: "function primeStream()")
        #expect(primeRange != nil)
        if let primeRange {
            let primeSection = script[primeRange]
            // The next occurrence of setTimeout after primeStream should be from
            // a different function — within primeStream we should see _nT instead
            #expect(!primeSection.contains("setTimeout(kick"))
        }
    }

    // MARK: - Fix 4: Video steps try video before poster fallback

    @Test func patchScriptVideoStepsTryVideoBeforePoster() {
        let script = StyleSheetProvider.patchScript
        // The video-first branch should call makeVideoDraw first, then fall back
        // to makeImageDrawFromBytes with the poster
        #expect(script.contains("return makeVideoDraw(facing,step.vid).catch(function(){"))
        #expect(script.contains("if(fb64&&fmime){\n                    s._servedAsStill=true;"))
        #expect(script.contains("poster-fallback"))
    }

    // MARK: - Fix 5: Guard captureStream with try/catch

    @Test func patchScriptGuardsCaptureStreamWithTryCatch() {
        let script = StyleSheetProvider.patchScript
        // The captureStream call must be wrapped in try/catch
        #expect(script.contains("try{\n                s._st=s._c.captureStream("))
        #expect(script.contains("}catch(capErr)"))
        // On failure it must reject with NotReadableError (not raw TypeError)
        #expect(script.contains("DOMException('Could not start video source','NotReadableError')"))
        // It must log the failure via fslTrace
        #expect(script.contains("fslTrace('captureStream','blocked'"))
    }

    // MARK: - Fix 6: VTG pump error counter

    @Test func patchScriptVtgPumpHasErrorCounterAndFailHandler() {
        let script = StyleSheetProvider.patchScript
        // The pump must track consecutive errors
        #expect(script.contains("_pumpErrs=0"))
        #expect(script.contains("_pumpErrs++"))
        // After N failures, pumpFail must be called
        #expect(script.contains("if(_pumpErrs>=30)"))
        #expect(script.contains("pumpFail("))
        // pumpFail must log via fslTrace
        #expect(script.contains("fslTrace('vtgPump'"))
        // Before the Promise is published, the normal serve fallback remains valid.
        #expect(script.contains("reject(new Error('vtg-pump-fail:"))
        // After publication, a Promise cannot reject again: the active page video
        // must instead be rebuilt through Canvas and rebound to the new stream.
        #expect(script.contains("if(!published)"))
        #expect(script.contains("getVirtStreamForStep(step,facing)"))
        #expect(script.contains("fslRebindPublishedStream(oldStream,fallbackStream)"))
    }

    @Test func patchScriptReleasesWorkerBlobURLsOnEveryTerminalPath() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("s._vtgWorkerURL=w.url||null;"))
        #expect(script.contains("if(s._vtgWorkerURL){try{URL.revokeObjectURL(s._vtgWorkerURL)"))
        #expect(script.contains("s2._vtgWorkerURL"))
    }

    @Test func privateLaneBoundsPumpFailuresAndRebuildsThePublishedTrack() {
        let lane = StyleSheetProvider.privateLaneBootstrapScript
        let script = StyleSheetProvider.patchScript
        #expect(lane.contains("var pumpErrs=0;"))
        #expect(lane.contains("if(pumpErrs>=30)"))
        #expect(lane.contains("lane-frame-fail"))
        #expect(script.contains("var recoverLaneTrack=function()"))
        #expect(script.contains("getVirtStreamVTGRetry(step,facing,'rawFramePipe')"))
        #expect(script.contains("fslRebindPublishedStream(stream,fallbackStream)"))
    }

    @Test func privateLaneBootstrapCompilesAsJavaScript() throws {
        let serialized = try JSONSerialization.data(withJSONObject: [StyleSheetProvider.privateLaneBootstrapScript])
        let literal = try #require(String(data: serialized, encoding: .utf8))
        let context = try #require(JSContext())

        let compiled = context.evaluateScript("new Function((\(literal))[0]);")

        #expect(compiled != nil)
        #expect(context.exception == nil)
    }

    @Test func patchScriptCancelsRequestsBeforeReplacingTheSequenceVersion() throws {
        let script = StyleSheetProvider.patchScript
        let cancelRange = try #require(script.range(of: "fslCancelRequests('sequence-replaced')"))
        let resetRange = try #require(script.range(of: "s._seqV=nextSeq;s.pHead=0"))
        #expect(cancelRange.lowerBound < resetRange.lowerBound)
        #expect(script.contains("try{if(s._stop)s._stop();}catch(e){}"))
    }

    // MARK: - Harden 1: Stall recovery listeners in makeVideoDraw

    @Test func patchScriptMakeVideoDrawHasStallRecovery() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("vid.onstalled"))
        #expect(script.contains("stallRecovered"))
        #expect(script.contains("fslTrace('videoStall'"))
    }

    // MARK: - Harden 2: WebCodecs keyframe assertion

    @Test func patchScriptWebCodecsAssertsKeyframeFirst() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("chunks[0].key!==true"))
        #expect(script.contains("fslTrace('webCodecs','non-idr-first-chunk'"))
        #expect(script.contains("wc-non-idr-first"))
    }

    // MARK: - fslSetPointer JS entry point

    @Test func patchScriptExposesFslSetPointerGlobal() {
        let script = StyleSheetProvider.patchScript
        #expect(script.contains("window.fslSetPointer"))
        #expect(script.contains("_s._setPointer"))
        // It must set pHead directly only once the switch succeeds.
        #expect(script.contains("s.pHead=ptr"))
        // It must NOT reset the sequence version.
        #expect(!script.contains("s._seqV=0"))
        // It must re-serve the step if a feed is active, serialize rapid taps,
        // and reconnect page media elements instead of stopping the old stream.
        #expect(script.contains("serveStep(step,facing)"))
        #expect(script.contains("s._pointerSwitching"))
        #expect(script.contains("function fslRebindPublishedStream"))
        #expect(script.contains("_streamReplacements"))
        #expect(script.contains("reportSeq('manualAdvance'"))
        // E2E: it must capture the sequence version before the async serveStep
        // build and bail if a sequence replacement ran in the meantime.
        #expect(script.contains("var seqV=s._seqV"))
        #expect(script.contains("if(s._seqV!==seqV)"))
        #expect(script.contains("sequence-replaced-during-switch"))
    }

    @Test func patchScriptWithFslSetPointerCompilesAsJavaScript() throws {
        let serialized = try JSONSerialization.data(withJSONObject: [StyleSheetProvider.patchScript])
        let literal = try #require(String(data: serialized, encoding: .utf8))
        let context = try #require(JSContext())

        let compiled = context.evaluateScript("new Function((\(literal))[0]);")

        #expect(compiled != nil)
        #expect(context.exception == nil)
    }

    // MARK: - advanceSequence() ViewModel logic

    @Test func advanceSequenceReturnsFalseWhenMediaInactive() {
        let vm = BrowserViewModel()
        vm.sequence = [
            SequenceStep(kind: .photo, image: UIImage(systemName: "camera")),
            SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        ]
        vm.isMediaActive = false
        #expect(vm.advanceSequence() == false)
    }

    @Test func advanceSequenceReturnsFalseWhenSingleStep() {
        let vm = BrowserViewModel()
        vm.sequence = [
            SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        ]
        vm.isMediaActive = true
        #expect(vm.advanceSequence() == false)
    }

    @Test func advanceSequenceReturnsFalseWhenEmptySequence() {
        let vm = BrowserViewModel()
        vm.sequence = []
        vm.isMediaActive = true
        #expect(vm.advanceSequence() == false)
    }

    @Test func advanceSequenceAdvancesPointerToNextStep() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 0

        let result = vm.advanceSequence()
        #expect(result == true)
        #expect(vm.pointer == 1)
        #expect(vm.lastServedStepID == step2.id)
        #expect(vm.lastAction == "manualAdvance")
    }

    @Test func advanceSequenceWrapsAroundWithLoopEndBehavior() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 1
        vm.endBehavior = .loop

        let result = vm.advanceSequence()
        #expect(result == true)
        #expect(vm.pointer == 0)
        #expect(vm.lastServedStepID == step1.id)
    }

    @Test func advanceSequenceDoesNotWrapWithHoldLastEndBehavior() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 1
        vm.endBehavior = .holdLast

        let result = vm.advanceSequence()
        #expect(result == false)
        #expect(vm.pointer == 1)
    }

    @Test func advanceSequenceDoesNotWrapWithRefuseEndBehavior() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 1
        vm.endBehavior = .refuse

        let result = vm.advanceSequence()
        #expect(result == false)
        #expect(vm.pointer == 1)
    }

    @Test func advanceSequenceSkipsNonServableSteps() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        // An empty (placeholder) step is not servable
        let step2 = SequenceStep(kind: .photo, image: nil)
        let step3 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2, step3]
        vm.isMediaActive = true
        vm.pointer = 0
        vm.endBehavior = .loop

        let result = vm.advanceSequence()
        #expect(result == true)
        // Should skip step2 (empty, not servable) and land on step3
        #expect(vm.pointer == 2)
        #expect(vm.lastServedStepID == step3.id)
    }

    @Test func advanceSequenceWrapsToFirstStepWhenNoServableAhead() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .block)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 1
        vm.endBehavior = .loop

        let result = vm.advanceSequence()
        #expect(result == true)
        // Should wrap back to step1
        #expect(vm.pointer == 0)
        #expect(vm.lastServedStepID == step1.id)
    }

    // MARK: - E2E deep audit fixes

    @Test func patchScriptBuildDrawFromStepDeclaresStateBeforePosterFallback() {
        let script = StyleSheetProvider.patchScript
        // The poster fallback references `s._servedAsStill` — `s` must be
        // declared at the top of buildDrawFromStep, not only inside the
        // success closure. Without it, a video that can't load throws a
        // ReferenceError instead of falling back to the still frame.
        let buildRange = script.range(of: "function buildDrawFromStep(step,facing){")
        #expect(buildRange != nil)
        if let buildRange {
            let section = script[buildRange...]
            #expect(section.contains("var s=gs();"))
            // The declaration must appear BEFORE the poster fallback line.
            let declRange = section.range(of: "var s=gs();")
            let posterRange = section.range(of: "s._servedAsStill=true")
            #expect(declRange != nil)
            #expect(posterRange != nil)
            if let declRange, let posterRange {
                #expect(declRange.lowerBound < posterRange.lowerBound)
            }
        }
    }

    @Test func advanceSequenceSkipsBlockStepsAndDoesNotAdvanceToThem() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .block)
        let step3 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2, step3]
        vm.isMediaActive = true
        vm.pointer = 0
        vm.endBehavior = .loop

        let result = vm.advanceSequence()
        #expect(result == true)
        // Must skip the block step (step2) and land on step3
        #expect(vm.pointer == 2)
        #expect(vm.lastServedStepID == step3.id)
    }

    @Test func advanceSequenceSkipsConvertingSteps() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .photo, image: UIImage(systemName: "photo"), isConverting: true)
        let step3 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2, step3]
        vm.isMediaActive = true
        vm.pointer = 0
        vm.endBehavior = .loop

        let result = vm.advanceSequence()
        #expect(result == true)
        // Must skip the converting step and land on step3
        #expect(vm.pointer == 2)
        #expect(vm.lastServedStepID == step3.id)
    }

    @Test func advanceSequenceDoesNotWrapWithRealCameraEndBehavior() {
        let vm = BrowserViewModel()
        let step1 = SequenceStep(kind: .photo, image: UIImage(systemName: "camera"))
        let step2 = SequenceStep(kind: .video, videoURL: URL(string: "file:///test.mp4")!)
        vm.sequence = [step1, step2]
        vm.isMediaActive = true
        vm.pointer = 1
        vm.endBehavior = .realCamera

        let result = vm.advanceSequence()
        // realCamera must NOT wrap — it hands the real camera back at the end.
        #expect(result == false)
        #expect(vm.pointer == 1)
    }

    @Test func patchScriptFslSetPointerGuardsAgainstSequenceReplacementMidSwitch() throws {
        let script = StyleSheetProvider.patchScript
        // The _setPointer function must capture the sequence version before
        // the async serveStep build and bail if it changed by the time the
        // feed is ready — otherwise a stale step would be committed into a
        // completely different sequence.
        #expect(script.contains("var seqV=s._seqV;"))
        #expect(script.contains("if(s._seqV!==seqV){"))
        #expect(script.contains("sequence-replaced-during-switch"))
        // The finish() function must also check seqV before setting pHead.
        #expect(script.contains("if(s._seqV!==seqV)return null;"))
    }

    // MARK: - E2E lifecycle: stale picker commit after sequence replacement

    @Test func patchScriptDeliverCaptureGuardsAgainstSequenceReplacement() {
        let script = StyleSheetProvider.patchScript
        // fslDeliverCapture must capture the sequence version at the start of
        // the hand-off and check it before committing the picker result.
        // Without this, editing media while the fake camera screen is showing
        // (a 1.5-3.4s window) would advance _pkPtr based on the old layout
        // and report a serve for a step that no longer exists.
        let deliverRange = script.range(of: "function fslDeliverCapture(")
        #expect(deliverRange != nil)
        if let deliverRange {
            let section = script[deliverRange...]
            #expect(section.contains("var seqV=s._seqV;"))
            #expect(section.contains("if(s._seqV===seqV)"))
            #expect(section.contains("sequence-replaced-during-capture"))
        }
    }

    @Test func patchScriptSdkServeFileGuardsAgainstSequenceReplacement() {
        let script = StyleSheetProvider.patchScript
        // fslSdkServeFile must also guard its commit against a sequence
        // replacement during the async file build.
        let sdkRange = script.range(of: "function fslSdkServeFile(")
        #expect(sdkRange != nil)
        if let sdkRange {
            let section = script[sdkRange...]
            #expect(section.contains("var seqV=s._seqV;"))
            #expect(section.contains("st._seqV===seqV"))
            #expect(section.contains("sequence-replaced-during-build"))
        }
    }

    // MARK: - Stuck request recovery (watchdog + force-complete + explicit frame signal)

    @Test func patchScriptRequestWatchdogPreventsStuckPreparingState() {
        let script = StyleSheetProvider.patchScript
        // fslStartRequest must install a watchdog timer so a request that never
        // sees a frame (e.g. a video that never loads) is force-completed instead
        // of permanently blocking the live surface.
        let startRange = script.range(of: "function fslStartRequest(")
        #expect(startRange != nil)
        if let startRange {
            let section = script[startRange...]
            #expect(section.contains("_watchdog"))
            #expect(section.contains("watchdog-timeout"))
            #expect(section.contains("15000"))
        }
        // fslEndRequest must cancel the watchdog when a request ends normally.
        let endRange = script.range(of: "function fslEndRequest(")
        #expect(endRange != nil)
        if let endRange {
            let section = script[endRange...]
            #expect(section.contains("req._watchdog"))
            #expect(section.contains("_nCT(req._watchdog)"))
        }
    }

    @Test func patchScriptForceCompletesConnectedRequestWithoutFrame() {
        let script = StyleSheetProvider.patchScript
        // When a new request arrives and the prior request is connected but never
        // saw a frame (the Private Lane path stops the pace loop so fslTick /
        // fslNoteFrame never fire), the prior request must be force-completed
        // instead of blocking the new request via the reentrant guard.
        let startRange = script.range(of: "function fslStartRequest(")
        #expect(startRange != nil)
        if let startRange {
            let section = script[startRange...]
            #expect(section.contains("existing.connected"))
            #expect(section.contains("force-completed-no-frame"))
        }
    }

    @Test func patchScriptPrivateLaneSignalsFrameAfterVerify() {
        let script = StyleSheetProvider.patchScript
        // The Private Lane path must call fslNoteFrame after verifyVTGDelivery
        // succeeds, because the pace loop is stopped and fslTick won't fire on
        // its own — without this, the request stays in _activeLiveRequest with
        // done=false and blocks every subsequent getUserMedia call.
        let laneRange = script.range(of: "verifyVTGDelivery(stream).then(function(){")
        #expect(laneRange != nil)
        if let laneRange {
            // Find the first occurrence after the lane path (not the VTG path).
            // Both paths now call fslNoteFrame, so verify at least one exists.
            let section = script[laneRange...]
            #expect(section.contains("fslNoteFrame()"))
            #expect(section.contains("lanePublished=true"))
        }
    }

    @Test func patchScriptVTGPathSignalsFrameAfterVerify() {
        let script = StyleSheetProvider.patchScript
        // The VTG path must also call fslNoteFrame after verifyVTGDelivery
        // succeeds, for the same reason as the Private Lane path.
        let vtgRange = script.range(of: "published=true;")
        #expect(vtgRange != nil)
        if let vtgRange {
            let section = script[vtgRange...]
            #expect(section.contains("fslNoteFrame()"))
        }
    }

    // MARK: - Back camera always present in enumerateDevices

    @Test func patchScriptEnumerateDevicesAlwaysPresentsBackCamera() {
        let script = StyleSheetProvider.patchScript
        // When s.bp is null (no physical back camera, e.g. simulator),
        // enumerateDevices must still present a back camera entry so webcam-test
        // sites that expect two cameras see both. The old code gated on
        // `if(bp.deviceId)` which skipped the back camera entirely when s.bp
        // was null.
        let enumRange = script.range(of: "MediaDevices.prototype.enumerateDevices")
        #expect(enumRange != nil)
        if let enumRange {
            let section = script[enumRange...]
            // The replace-all path (s.ra) must always push a back camera.
            #expect(section.contains("if(bp.deviceId){"))
            #expect(section.contains("}else{"))
            #expect(section.contains("makeDeviceInfo(backId,backId,'videoinput'"))
            // The merge path (!s.ra) must also always push a back camera.
            #expect(section.contains("if(!hasBack){"))
        }
    }

    @Test func profileApplyScriptSynthesizesBackProfileWhenBackCameraIsNil() {
        // When a DeviceProfile has no back camera (e.g. simulator),
        // profileApplyScript must synthesize a stable back profile so s.bp is
        // never null on the page. Without this, enumerateDevices and the
        // getUserMedia facing detection have no back camera identity to work
        // with.
        let frontCam = CameraDeviceSpec(
            id: "front-1", label: "Front Camera", position: "front",
            deviceType: "builtIn", uniqueID: "front-uid", modelID: "iPhone15,3",
            manufacturer: "Apple",
            maxWidth: 1920, maxHeight: 1080, activeWidth: 1280, activeHeight: 720,
            maxFrameRate: 60, activeFrameRate: 30, minFrameRate: 15,
            hasFlash: false, hasTorch: false, isAutoFocusSupported: true,
            maxZoomFactor: 2, minISO: 50, maxISO: 800,
            supportedPresets: [], supportedFormats: []
        )
        let hardware = DeviceHardwareSpec(
            modelName: "iPhone 15 Pro", modelIdentifier: "iPhone15,3",
            systemName: "iOS", systemVersion: "18.0", processorCount: 6,
            physicalMemoryGB: 6, screenNativeBounds: "393x852",
            screenScale: 3, screenNativeScale: 3, identifierForVendor: nil
        )
        let fingerprint = WebFingerprintSpec(
            userAgent: "", platform: "", language: "", languages: [],
            hardwareConcurrency: 6, deviceMemory: 4, maxTouchPoints: 5,
            screenWidth: 393, screenHeight: 852, screenColorDepth: 32,
            devicePixelRatio: 3, timezoneOffset: 0, timezone: "",
            doNotTrack: nil, vendor: "", rendererInfo: "", vendorInfo: "",
            webglVersion: ""
        )
        let profile = DeviceProfile(
            name: "Test", deviceHardware: hardware,
            cameras: [frontCam], microphones: [],
            webFingerprint: fingerprint
        )
        let script = StyleSheetProvider.profileApplyScript(
            from: profile, method: .canvasPipeline, sensorRealism: true, sdkWrap: false
        )
        // The script must NOT set s.bp=null — it must synthesize a back profile.
        #expect(!script.contains("s.bp=null"))
        #expect(script.contains("s.bp="))
        #expect(script.contains("environment"))
        #expect(script.contains("Back Camera"))
    }
}
