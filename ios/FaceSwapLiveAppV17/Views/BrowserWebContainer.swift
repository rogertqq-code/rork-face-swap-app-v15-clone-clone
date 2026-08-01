import SwiftUI
import UIKit
import WebKit

struct BrowserWebContainer: UIViewRepresentable {
    let viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = BrowserWebViewConfigurationFactory.makeConfiguration(
            videoHandler: viewModel.schemeHandler,
            imageHandler: viewModel.imageSchemeHandler,
            messageHandler: context.coordinator,
            replyHandler: context.coordinator,
            isDiagnosticsHarness: false
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let defaultUserAgent = webView.value(forKey: "userAgent") as? String ?? ""
        webView.customUserAgent = StyleSheetProvider.buildSafariUserAgent(from: defaultUserAgent)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = true

        context.coordinator.webView = webView
        viewModel.webView = webView
        viewModel.resetContentFilterState()
        InjectionStreamRegistry.shared.activeWebView = webView

        context.coordinator.progressObservation = webView.observe(\.estimatedProgress) { [weak viewModel] view, _ in
            Task { @MainActor in viewModel?.estimatedProgress = view.estimatedProgress }
        }
        context.coordinator.titleObservation = webView.observe(\.title) { [weak viewModel] view, _ in
            Task { @MainActor in viewModel?.pageTitle = view.title ?? "" }
        }
        context.coordinator.urlObservation = webView.observe(\.url) { [weak viewModel] view, _ in
            Task { @MainActor in
                guard let url = view.url else { return }
                viewModel?.urlText = url.absoluteString
                viewModel?.currentURL = url
            }
        }
        context.coordinator.loadingObservation = webView.observe(\.isLoading) { [weak viewModel] view, _ in
            Task { @MainActor in viewModel?.isLoading = view.isLoading }
        }
        context.coordinator.canGoBackObservation = webView.observe(\.canGoBack) { [weak viewModel] view, _ in
            Task { @MainActor in viewModel?.canGoBack = view.canGoBack }
        }
        context.coordinator.canGoForwardObservation = webView.observe(\.canGoForward) { [weak viewModel] view, _ in
            Task { @MainActor in viewModel?.canGoForward = view.canGoForward }
        }
        context.coordinator.cameraCaptureStateObservation = webView.observe(\.cameraCaptureState) { [weak coordinator = context.coordinator] view, _ in
            if view.cameraCaptureState == .none, let ownerID = coordinator?.leaseOwnerID {
                Task { await MediaResourceCoordinator.shared.releaseLease(for: ownerID + ".Camera") }
            }
        }
        context.coordinator.microphoneCaptureStateObservation = webView.observe(\.microphoneCaptureState) { [weak coordinator = context.coordinator] view, _ in
            if view.microphoneCaptureState == .none, let ownerID = coordinator?.leaseOwnerID {
                Task { await MediaResourceCoordinator.shared.releaseLease(for: ownerID + ".Microphone") }
            }
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let url = viewModel.pendingNavigationURL {
            viewModel.pendingNavigationURL = nil
            viewModel.restoreSiteMemory(for: url)
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        BrowserWebViewConfigurationFactory.tearDown(webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if InjectionStreamRegistry.shared.activeWebView === webView {
            InjectionStreamRegistry.shared.activeWebView = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        let viewModel: BrowserViewModel
        /// Unique string token used to scope hardware leases to this specific Coordinator instance.
        let leaseOwnerID: String = "WebKit.\(UUID().uuidString)"
        weak var webView: WKWebView?
        var progressObservation: NSKeyValueObservation?
        var titleObservation: NSKeyValueObservation?
        var urlObservation: NSKeyValueObservation?
        var loadingObservation: NSKeyValueObservation?
        var canGoBackObservation: NSKeyValueObservation?
        var canGoForwardObservation: NSKeyValueObservation?
        var cameraCaptureStateObservation: NSKeyValueObservation?
        var microphoneCaptureStateObservation: NSKeyValueObservation?
        /// Tracks whether this coordinator successfully acquired hardware leases.
        var cameraLeaseHeld = false
        var microphoneLeaseHeld = false
        private var nativeWebRTCRequestFrames: [UUID: WKFrameInfo] = [:]
        private var backgroundObserver: NSObjectProtocol?
        private lazy var nativeWebRTCBridge = NativeWebRTCBridgeCoordinator { [weak self] event in
            Task { @MainActor [weak self] in
                self?.deliverNativeWebRTCSignal(event)
            }
        }

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
            super.init()
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let bridge = self.nativeWebRTCBridge
                    self.nativeWebRTCRequestFrames.removeAll()
                    await bridge.stopAll(reason: .backgrounded)
                }
            }
        }

        func tearDown() {
            let bridge = nativeWebRTCBridge
            Task { await bridge.stopAll(reason: .callerStopped) }
            nativeWebRTCRequestFrames.removeAll()
            if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
            backgroundObserver = nil
            progressObservation?.invalidate()
            titleObservation?.invalidate()
            urlObservation?.invalidate()
            loadingObservation?.invalidate()
            canGoBackObservation?.invalidate()
            canGoForwardObservation?.invalidate()
            cameraCaptureStateObservation?.invalidate()
            microphoneCaptureStateObservation?.invalidate()

            // Only release leases this coordinator actually acquired.
            let id = leaseOwnerID
            let cam = cameraLeaseHeld
            let mic = microphoneLeaseHeld
            if cam || mic {
                Task {
                    if cam { await MediaResourceCoordinator.shared.releaseLease(for: id + ".Camera") }
                    if mic { await MediaResourceCoordinator.shared.releaseLease(for: id + ".Microphone") }
                }
            }

            progressObservation = nil
            titleObservation = nil
            urlObservation = nil
            loadingObservation = nil
            canGoBackObservation = nil
            canGoForwardObservation = nil
            cameraCaptureStateObservation = nil
            microphoneCaptureStateObservation = nil
            webView = nil
        }

        // MARK: - Supported WebKit UI and permission decisions

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            guard viewModel.shouldGrantWebMediaCapture(for: origin, frame: frame, type: type) else {
                decisionHandler(.deny)
                return
            }
            // Grant immediately so WebKit doesn't time out waiting for the decision.
            // We record lease intent and acquire asynchronously; the KVO on
            // cameraCaptureState/.none will release when WebKit actually stops capture.
            if type == .camera || type == .cameraAndMicrophone { cameraLeaseHeld = true }
            if type == .microphone || type == .cameraAndMicrophone { microphoneLeaseHeld = true }
            decisionHandler(.grant)
            let id = leaseOwnerID
            Task {
                if type == .camera || type == .cameraAndMicrophone {
                    await MediaResourceCoordinator.shared.acquireLease(for: id + ".Camera")
                }
                if type == .microphone || type == .cameraAndMicrophone {
                    await MediaResourceCoordinator.shared.acquireLease(for: id + ".Microphone")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            if let context = viewModel.bridgeContext(for: frame) {
                viewModel.noteNativePanelSuppressed(kind: "JavaScript alert", context: context)
            }
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            if let context = viewModel.bridgeContext(for: frame) {
                viewModel.noteNativePanelSuppressed(kind: "JavaScript confirmation", context: context)
            }
            completionHandler(false)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            if let context = viewModel.bridgeContext(for: frame) {
                viewModel.noteNativePanelSuppressed(kind: "JavaScript text input", context: context)
            }
            completionHandler(nil)
        }

        // MARK: - Navigation

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            if let destination = navigationAction.request.url {
                if viewModel.shouldBlockCameraCustomScheme(destination) {
                    viewModel.noteCameraCustomSchemeBlocked(destination)
                    webView.callAsyncJavaScript(
                        "return window.__fslMediaAdapters && window.__fslMediaAdapters.request('both', label);",
                        arguments: ["label": "custom-scheme-\(destination.scheme ?? "unknown")"],
                        in: navigationAction.sourceFrame,
                        contentWorld: .page
                    ) { _ in }
                    decisionHandler(.cancel)
                    return
                }
                if isMainFrame {
                    viewModel.currentURL = destination
                    viewModel.restoreSiteMemory(for: destination)
                }
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse,
               let host = response.url?.host,
               !host.isEmpty {
                let enforced = response.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
                let reportOnly = response.value(forHTTPHeaderField: "Content-Security-Policy-Report-Only") ?? ""
                InjectionStreamRegistry.shared.recordCSP(host: host, enforced: enforced, reportOnly: reportOnly)
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let bridge = nativeWebRTCBridge
            Task { await bridge.stopAll(reason: .interrupted) }
            nativeWebRTCRequestFrames.removeAll()
            ConnectionLogService.shared.error("WKWebView Web Content process terminated. Initiating recovery.")
            viewModel.handleWebContentProcessTerminated()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let bridge = nativeWebRTCBridge
            Task { await bridge.stopAll(reason: .navigationReplaced) }
            nativeWebRTCRequestFrames.removeAll()
            viewModel.beginNavigation()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            viewModel.markPageFinishedLoading()
            viewModel.restoreSiteMemoryForCurrentPage()
            viewModel.syncMediaToPage()
            viewModel.fetchConstraintLogs()
            ConnectionLogService.shared.log(.navigation, "WKWebView didFinish \u{2014} url=\(webView.url?.host ?? "unknown")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            viewModel.markPageLoadFailed()
            ConnectionLogService.shared.error("WKWebView didFail \u{2014} error=\(error.localizedDescription) url=\(webView.url?.host ?? "unknown")")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            viewModel.markPageLoadFailed()
            ConnectionLogService.shared.error("WKWebView didFailProvisional \u{2014} error=\(error.localizedDescription) url=\(webView.url?.host ?? "unknown")")
        }

        // MARK: - Page bridge

        struct BridgeMessageEnvelope: Codable {
            let session: String?
            let version: Int?
            let action: String?
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            
            var sessionID: String? = nil
            if let data = try? JSONSerialization.data(withJSONObject: message.body),
               let envelope = try? JSONDecoder().decode(BridgeMessageEnvelope.self, from: data) {
                sessionID = envelope.session
            } else {
                sessionID = body["session"] as? String
            }
            
            guard let context = viewModel.bridgeContext(for: message.frameInfo, expectedSessionID: sessionID) else { return }

            switch message.name {
            case BrowserWebViewConfigurationFactory.cameraBridgeName:
                handleCameraMessage(body, frame: message.frameInfo, context: context)
            case BrowserWebViewConfigurationFactory.traceBridgeName:
                InjectionTraceRecorder.shared.recordFromPage(body, context: context)
            case BrowserWebViewConfigurationFactory.sequenceBridgeName:
                handleSequenceMessage(body, frame: message.frameInfo, context: context)
            default:
                break
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let body = message.body as? [String: Any],
                  let context = viewModel.bridgeContext(for: message.frameInfo) else {
                replyHandler(nil, "The page is not eligible for this media bridge.")
                return
            }
            switch message.name {
            case BrowserWebViewConfigurationFactory.runtimeBridgeName:
                handleRuntimeReplyMessage(body, context: context, replyHandler: replyHandler)
            case BrowserWebViewConfigurationFactory.nativeWebRTCBridgeName:
                handleNativeWebRTCReplyMessage(body, frame: message.frameInfo, context: context, replyHandler: replyHandler)
            default:
                replyHandler(nil, "Unknown media bridge.")
            }
        }

        private func handleRuntimeReplyMessage(
            _ body: [String: Any],
            context: MediaBridgeContext,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            viewModel.noteRuntimeBridgeReady(context: context)
            let reqId = body["reqId"] as? String
            do {
                let json = try viewModel.runtimeStateJSON()
                if let reqId {
                    replyHandler("{\"reqId\":\"\(reqId)\",\"state\":\(json)}", nil)
                } else {
                    replyHandler(json, nil)
                }
            } catch {
                replyHandler(nil, "Failed to serialize media runtime state.")
            }
        }

        private func handleNativeWebRTCReplyMessage(
            _ body: [String: Any],
            frame: WKFrameInfo,
            context: MediaBridgeContext,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let action = body["action"] as? String,
                  let requestText = body["requestId"] as? String,
                  let requestID = UUID(uuidString: requestText) else {
                replyHandler(nil, "Invalid native WebRTC action or request ID.")
                return
            }
            switch action {
            case "start":
                let values = body["constraints"] as? [String: Any] ?? [:]
                let width = intValue(values["width"]) ?? 0
                let height = intValue(values["height"]) ?? 0
                let dimensions = width > 0 && height > 0 ? MediaDimensions(width: width, height: height) : nil
                let wantsAudio = boolValue(values["wantsAudio"]) ?? false
                let audioPolicy = MediaAudioPolicy(rawValue: values["audioPolicy"] as? String ?? "")
                    ?? (wantsAudio ? .compatibilitySilentFallback : .notRequested)
                let rawModeKind = MediaRawSampleModeKind(rawValue: values["rawSampleMode"] as? String ?? "") ?? .off
                let rawSampleMode = MediaRawSampleMode(
                    kind: rawModeKind,
                    interval: intValue(values["rawSampleInterval"])
                )
                let request = MediaDeliveryRequest(
                    id: requestID,
                    navigationSessionID: context.navigationSessionID,
                    origin: context.origin,
                    kind: .webRTC,
                    constraints: MediaDeliveryConstraints(
                        wantsVideo: boolValue(values["wantsVideo"]) ?? true,
                        wantsAudio: wantsAudio,
                        facingMode: MediaFacingMode(rawValue: values["facingMode"] as? String ?? "") ?? .unspecified,
                        dimensions: dimensions,
                        frameRate: doubleValue(values["frameRate"]),
                        audioPolicy: audioPolicy
                    ),
                    rawSampleMode: rawSampleMode
                )
                nativeWebRTCRequestFrames[requestID] = frame
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
                        nativeWebRTCRequestFrames.removeValue(forKey: requestID)
                        replyHandler(nil, error.localizedDescription)
                    }
                }
            case "answer":
                guard let value = body["answer"] as? [String: Any],
                      let type = NativeWebRTCSDPType(rawValue: value["type"] as? String ?? ""),
                      let sdp = value["sdp"] as? String else {
                    replyHandler(nil, "Invalid SDP answer.")
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
                    replyHandler(nil, "Invalid ICE candidate.")
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
                nativeWebRTCRequestFrames.removeValue(forKey: requestID)
                let bridge = nativeWebRTCBridge
                Task { await bridge.stop(requestID: requestID); replyHandler(["ok": true], nil) }
            default:
                replyHandler(nil, "Unsupported native WebRTC action.")
            }
        }

        private func deliverNativeWebRTCSignal(_ event: NativeWebRTCSignalEvent) {
            guard let frame = nativeWebRTCRequestFrames[event.requestID], let webView else { return }
            var payload: [String: Any] = ["kind": event.kind.rawValue, "requestID": event.requestID.uuidString]
            if let candidate = event.candidate {
                var candidatePayload: [String: Any] = [
                    "sdp": candidate.sdp,
                    "sdpMLineIndex": candidate.sdpMLineIndex,
                ]
                if let sdpMid = candidate.sdpMid { candidatePayload["sdpMid"] = sdpMid }
                payload["candidate"] = candidatePayload
            }
            webView.callAsyncJavaScript(
                "return window.__fslNativeRTCStep1 && window.__fslNativeRTCStep1.receiveSignal(event);",
                arguments: ["event": payload],
                in: frame,
                contentWorld: .page
            ) { _ in }
        }

        struct CameraMessageBody: Codable {
            let action: String
            let requestId: String?
            let stepId: String?
            let facing: String?
            let result: String?
            let error: String?
        }

        private func handleCameraMessage(_ body: [String: Any], frame: WKFrameInfo, context: MediaBridgeContext) {
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let msg = try? JSONDecoder().decode(CameraMessageBody.self, from: data) else { return }
            
            let action = msg.action
            let token = body["token"] as? String ?? ""
            if action == "ask" {
                let kindRaw = body["kind"] as? String ?? ""
                let facing = msg.facing ?? ""
                viewModel.noteActiveFrame(frame, context: context)
                viewModel.noteCameraRequestFrame(frame, token: token)
                viewModel.presentCameraRequest(
                    token: token,
                    kindRaw: kindRaw,
                    facing: facing,
                    width: body["w"] as? Int,
                    height: body["h"] as? Int,
                    frameRate: body["fps"] as? Int,
                    origin: context.origin,
                    isFrame: !context.isMainFrame
                )
                return
            }
            if action == "askTimeout" {
                viewModel.cameraRequestTimedOut(token: token)
                return
            }
            viewModel.noteActiveFrame(frame, context: context)
            viewModel.handleNativeCameraEvent(
                action,
                token: token,
                origin: context.origin,
                isFrame: !context.isMainFrame
            )
        }

        private func handleSequenceMessage(_ body: [String: Any], frame: WKFrameInfo, context: MediaBridgeContext) {
            let action = body["action"] as? String ?? ""
            if action == "lifecycle" {
                viewModel.handleMediaLifecycle(body, context: context)
                return
            }
            
            let expectedVersion = viewModel.sequenceVersion
            let sequenceValue = (body["sequenceVersion"] as? NSNumber)?.intValue ?? (body["sequenceVersion"] as? Int) ?? expectedVersion
            guard sequenceValue == expectedVersion else { return }

            viewModel.noteActiveFrame(frame, context: context)
            let servedID = body["id"] as? String
            let surface = body["surface"] as? String ?? "live"
            let feed = body["feed"] as? String ?? ""
            let lane = body["lane"] as? String ?? ""
            let downgraded = (body["downgraded"] as? NSNumber)?.boolValue ?? (body["downgraded"] as? Bool ?? false)
            viewModel.updateSequenceProgress(
                pointer: intValue(body["ptr"]) ?? 0,
                pickerPointer: intValue(body["pickerPtr"]),
                surface: surface,
                servedID: servedID,
                action: action,
                feed: feed,
                lane: lane,
                downgraded: downgraded,
                reason: body["reason"] as? String ?? "",
                engine: body["engine"] as? String ?? ""
            )
        }

        private func intValue(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            return value as? Int
        }

        private func doubleValue(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            return value as? Double
        }

        private func boolValue(_ value: Any?) -> Bool? {
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }
    }
}
