import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct NativeWebRTCContractTests {
    @Test func sessionDescriptionRoundTripsThroughJSON() throws {
        let description = NativeWebRTCSessionDescription(
            type: .offer,
            sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
        )

        let data = try JSONEncoder().encode(description)
        let decoded = try JSONDecoder().decode(NativeWebRTCSessionDescription.self, from: data)

        #expect(decoded == description)
        #expect(decoded.type == .offer)
    }

    @Test func iceCandidateRoundTripsThroughJSON() throws {
        let candidate = NativeWebRTCIceCandidate(
            sdp: "candidate:1 1 UDP 2122260223 192.0.2.1 5000 typ host",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )

        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(NativeWebRTCIceCandidate.self, from: data)

        #expect(decoded == candidate)
        #expect(decoded.sdpMid == "0")
    }

    @Test func nativeClientUsesReplyBridgeAndLocalPeerConnection() {
        let script = StyleSheetProvider.nativeWebRTCClientScript

        #expect(script.contains("messageHandlers.fslNativeRTC"))
        #expect(script.contains("new RTCPeerConnection({iceServers:[]})"))
        #expect(script.contains("pc.setRemoteDescription(started.offer)"))
        #expect(script.contains("pc.createAnswer()"))
        #expect(script.contains("action:'candidate'"))
        #expect(script.contains("receiveSignal"))
    }

    @Test func nativeBridgeIsRegisteredAndRemovedSymmetrically() throws {
        let source = try String(contentsOf: sourceURL("Services/BrowserWebViewConfigurationFactory.swift"), encoding: .utf8)

        #expect(source.contains("nativeWebRTCBridgeName"))
        #expect(source.contains("addScriptMessageHandler(replyHandler, contentWorld: .page, name: nativeWebRTCBridgeName)"))
        #expect(source.contains("removeScriptMessageHandler(forName: nativeWebRTCBridgeName, contentWorld: .page)"))
    }

    @Test func mountedDiagnosticsPageStartsRendersAndStopsNativeTrack() throws {
        let probe = DiagnosticsHarnessScripts.nativeWebRTCProbeBody
        let host = try String(contentsOf: sourceURL("Views/DiagnosticsHarnessWebView.swift"), encoding: .utf8)
        let engine = try String(contentsOf: sourceURL("Services/DeviceTestEngine.swift"), encoding: .utf8)

        #expect(probe.contains("__fslNativeRTCStep1"))
        #expect(probe.contains("video.srcObject=stream"))
        #expect(probe.contains("await api.stop(out.requestID)"))
        #expect(host.contains("nativeWebRTCBridgeName"))
        #expect(host.contains("startNativeCameraSession"))
        #expect(engine.contains("runNativeWebRTCProbe"))
        #expect(engine.contains("nativeWebRTCResult"))
    }

    @Test func captureServiceUsesExplicitActorOwnedShutdown() throws {
        let source = try String(contentsOf: sourceURL("Services/CaptureService.swift"), encoding: .utf8)

        #expect(source.contains("func shutdown() async"))
        #expect(source.contains("stopSessionForShutdown"))
        #expect(source.contains("lifecycleGeneration"))
        #expect(source.contains("await shutdown()"))
        #expect(!source.contains("asUnownedSerialExecutor"))
        #expect(!source.contains("CaptureSessionActor.shared.queue"))
        #expect(!source.contains("CaptureSessionActor.queue"))
        #expect(!source.contains("captureSession.stopRunning()"))
    }

    @Test func nativeDiagnosticResultRoundTripsThroughReportJSON() throws {
        let native = NativeWebRTCDiagnosticResult(
            status: .pass,
            requestID: UUID().uuidString,
            receivedVideo: true,
            videoTrackCount: 1,
            audioTrackCount: 1,
            audioOutcome: "silentFallback",
            rawSampleMode: "firstFrame",
            lifecycleStopped: true
        )
        let report = DiagnosticsFullTestReport(nativeWebRTC: native)
        let decoded = try JSONDecoder().decode(
            DiagnosticsFullTestReport.self,
            from: JSONEncoder().encode(report)
        )

        #expect(decoded.nativeWebRTC.status == .pass)
        #expect(decoded.nativeWebRTC.receivedVideo)
        #expect(decoded.nativeWebRTC.lifecycleStopped)
        #expect(decoded.nativeWebRTC.rawSampleMode == "firstFrame")
    }

    private func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FaceSwapLiveAppV17")
            .appendingPathComponent(relativePath)
    }
}
