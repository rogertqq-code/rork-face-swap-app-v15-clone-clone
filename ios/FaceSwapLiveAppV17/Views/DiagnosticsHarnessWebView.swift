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
            completionHandler(nil)
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
                replyHandler(try? MediaRuntimeState.idle().serializedJSON(), nil)
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
            Task { try? await webView.callAsyncJavaScript(signalBody, arguments: ["event": payload], in: frame, in: .page) }
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
