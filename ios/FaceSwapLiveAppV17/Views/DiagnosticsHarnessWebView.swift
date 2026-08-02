import SwiftUI
import WebKit

/// Hosts the app-owned diagnostics fixture with the same immutable WebKit runtime
/// configuration as the browser. Keeping it mounted prevents its frame pipeline
/// from being throttled while the diagnostics screen is visible.
struct DiagnosticsHarnessWebView: UIViewRepresentable {
    let harness: DiagnosticsTestHarness

    func makeCoordinator() -> Coordinator { Coordinator(harness: harness) }

    func makeUIView(context: Context) -> WKWebView {
        let resourceHandler = LocalResourceHandler()
        let configuration = BrowserWebViewConfigurationFactory.makeConfiguration(
            videoHandler: resourceHandler,
            imageHandler: resourceHandler,
            messageHandler: context.coordinator,
            replyHandler: context.coordinator,
            isDiagnosticsHarness: true
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let defaultUserAgent = webView.value(forKey: "userAgent") as? String ?? ""
        webView.customUserAgent = StyleSheetProvider.buildSafariUserAgent(from: defaultUserAgent)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        context.coordinator.webView = webView

        harness.attach(webView)
        webView.loadHTMLString(
            DiagnosticsHarnessScripts.testPageHTML,
            baseURL: URL(string: "https://fsl.diagnostics.local/camera-test")!
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let bridge = coordinator.nativeWebRTCBridge
        Task { await bridge.stopAll(reason: .navigationReplaced) }
        coordinator.webView = nil
        BrowserWebViewConfigurationFactory.tearDown(webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        let harness: DiagnosticsTestHarness
        weak var webView: WKWebView?
        private let navigationSessionID = "diagnostics-\(UUID().uuidString)"
        private var requestFrames: [UUID: WKFrameInfo] = [:]
        fileprivate lazy var nativeWebRTCBridge = NativeWebRTCBridgeCoordinator { [weak self] event in
            Task { @MainActor [weak self] in self?.deliverNativeWebRTCSignal(event) }
        }

        init(harness: DiagnosticsTestHarness) {
            self.harness = harness
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let isFixture = origin.protocol == "https" && origin.host == "fsl.diagnostics.local"
            decisionHandler(isFixture ? .grant : .deny)
        }

        @available(iOS 18.4, *)
        @MainActor
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            // B-02: The fixture needs file-delivery to prove picker/capture
            // outcomes. Write a small JPEG to a temp file and return its URL
            // so the fixture's change listener receives a real file.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fsl_fixture_pick.jpg")
            let jpegData = Self.fixtureJPEG()
            do {
                try jpegData.write(to: tempURL)
                completionHandler([tempURL])
            } catch {
                completionHandler(nil)
            }
        }

        /// Minimal 1×1 JPEG for the fixture file-delivery path.
        private static let fixtureJPEGBytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
            0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
            0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C,
            0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D,
            0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20,
            0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
            0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
            0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34,
            0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4,
            0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01,
            0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF,
            0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
            0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04,
            0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00,
            0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
            0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
            0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1,
            0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
            0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A,
            0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35,
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55,
            0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65,
            0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
            0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85,
            0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94,
            0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
            0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2,
            0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
            0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
            0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
            0xD9, 0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6,
            0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
            0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA,
            0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
            0xFB, 0xD2, 0x8A, 0x28, 0xA0, 0xFF, 0xD9
        ]

        private static func fixtureJPEG() -> Data {
            Data(fixtureJPEGBytes)
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            completionHandler(nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            harness.markPageLoaded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // The diagnostics engine reads results through explicit probe calls.
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            if message.name == BrowserWebViewConfigurationFactory.runtimeBridgeName {
                do {
                    replyHandler(try MediaRuntimeState.idle().serializedJSON(), nil)
                } catch {
                    replyHandler(nil, "Runtime-state serialization failed: \(error.localizedDescription)")
                }
                return
            }
            guard message.name == BrowserWebViewConfigurationFactory.nativeWebRTCBridgeName else {
                replyHandler(nil, "Unsupported diagnostics bridge message.")
                return
            }
            let origin = message.frameInfo.securityOrigin
            guard origin.protocol == "https", origin.host == "fsl.diagnostics.local" else {
                replyHandler(nil, "The native WebRTC diagnostics bridge only serves the mounted fixture.")
                return
            }
            guard let body = message.body as? [String: Any] else {
                replyHandler(nil, "Invalid native WebRTC diagnostics message.")
                return
            }
            handleNativeWebRTCMessage(body, frame: message.frameInfo, replyHandler: replyHandler)
        }

        private func handleNativeWebRTCMessage(
            _ body: [String: Any],
            frame: WKFrameInfo,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let action = body["action"] as? String,
                  let requestText = body["requestId"] as? String,
                  let requestID = UUID(uuidString: requestText) else {
                replyHandler(nil, "Invalid native WebRTC diagnostics action or request ID.")
                return
            }

            switch action {
            case "start":
                let values = body["constraints"] as? [String: Any] ?? [:]
                let width = intValue(values["width"]) ?? 0
                let height = intValue(values["height"]) ?? 0
                let wantsAudio = boolValue(values["wantsAudio"]) ?? false
                let audioPolicy = MediaAudioPolicy(rawValue: values["audioPolicy"] as? String ?? "")
                    ?? (wantsAudio ? .compatibilitySilentFallback : .notRequested)
                let rawMode = MediaRawSampleMode(
                    kind: MediaRawSampleModeKind(rawValue: values["rawSampleMode"] as? String ?? "") ?? .off,
                    interval: intValue(values["rawSampleInterval"])
                )
                let request = MediaDeliveryRequest(
                    id: requestID,
                    navigationSessionID: navigationSessionID,
                    origin: "https://fsl.diagnostics.local",
                    kind: .webRTC,
                    constraints: MediaDeliveryConstraints(
                        wantsVideo: boolValue(values["wantsVideo"]) ?? true,
                        wantsAudio: wantsAudio,
                        facingMode: MediaFacingMode(rawValue: values["facingMode"] as? String ?? "") ?? .unspecified,
                        dimensions: width > 0 && height > 0 ? MediaDimensions(width: width, height: height) : nil,
                        frameRate: doubleValue(values["frameRate"]),
                        audioPolicy: audioPolicy
                    ),
                    rawSampleMode: rawMode
                )
                requestFrames[requestID] = frame
                let bridge = nativeWebRTCBridge
                Task {
                    do {
                        let started = try await bridge.startNativeCameraSession(for: request)
                        var audio: [String: Any] = ["kind": started.audioOutcome.kind.rawValue]
                        if let reason = started.audioOutcome.reason { audio["reason"] = reason }
                        replyHandler([
                            "ok": true,
                            "requestId": requestText,
                            "offer": ["type": started.offer.type.rawValue, "sdp": started.offer.sdp],
                            "audioOutcome": audio,
                        ], nil)
                    } catch {
                        requestFrames.removeValue(forKey: requestID)
                        replyHandler(nil, error.localizedDescription)
                    }
                }
            case "answer":
                guard let value = body["answer"] as? [String: Any],
                      let type = NativeWebRTCSDPType(rawValue: value["type"] as? String ?? ""),
                      let sdp = value["sdp"] as? String else {
                    replyHandler(nil, "Invalid native WebRTC diagnostics answer.")
                    return
                }
                let bridge = nativeWebRTCBridge
                Task {
                    do {
                        try await bridge.setPageAnswer(.init(type: type, sdp: sdp), requestID: requestID)
                        replyHandler(["ok": true], nil)
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
            case "candidate":
                guard let value = body["candidate"] as? [String: Any],
                      let sdp = value["sdp"] as? String else {
                    replyHandler(nil, "Invalid native WebRTC diagnostics candidate.")
                    return
                }
                let candidate = NativeWebRTCIceCandidate(
                    sdp: sdp,
                    sdpMLineIndex: Int32(intValue(value["sdpMLineIndex"]) ?? 0),
                    sdpMid: value["sdpMid"] as? String
                )
                let bridge = nativeWebRTCBridge
                Task {
                    do {
                        try await bridge.addPageCandidate(candidate, requestID: requestID)
                        replyHandler(["ok": true], nil)
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
            case "active":
                let bridge = nativeWebRTCBridge
                Task { await bridge.markActive(requestID: requestID); replyHandler(["ok": true], nil) }
            case "stop":
                requestFrames.removeValue(forKey: requestID)
                let bridge = nativeWebRTCBridge
                Task { await bridge.stop(requestID: requestID); replyHandler(["ok": true], nil) }
            default:
                replyHandler(nil, "Unsupported native WebRTC diagnostics action.")
            }
        }

        private func deliverNativeWebRTCSignal(_ event: NativeWebRTCSignalEvent) {
            guard let frame = requestFrames[event.requestID], let webView else { return }
            var payload: [String: Any] = ["kind": event.kind.rawValue, "requestID": event.requestID.uuidString]
            if let candidate = event.candidate {
                var value: [String: Any] = [
                    "sdp": candidate.sdp,
                    "sdpMLineIndex": candidate.sdpMLineIndex,
                ]
                if let sdpMid = candidate.sdpMid { value["sdpMid"] = sdpMid }
                payload["candidate"] = value
            }
            let signalBody = "return window.__fslNativeRTCStep1 && window.__fslNativeRTCStep1.receiveSignal(event);"
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    signalBody,
                    arguments: ["event": payload],
                    in: frame,
                    in: .page
                )
            }
        }

        private func boolValue(_ value: Any?) -> Bool? {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            return nil
        }

        private func intValue(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? Double { return Int(value) }
            return nil
        }

        private func doubleValue(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? Int { return Double(value) }
            return nil
        }
    }
}
