import SwiftUI
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

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        func tearDown() {
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
            ConnectionLogService.shared.error("WKWebView Web Content process terminated. Initiating recovery.")
            viewModel.handleWebContentProcessTerminated()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
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
            guard message.name == BrowserWebViewConfigurationFactory.runtimeBridgeName,
                  let body = message.body as? [String: Any],
                  let context = viewModel.bridgeContext(for: message.frameInfo) else {
                replyHandler(nil, "The page is not eligible for a media runtime state.")
                return
            }
            viewModel.noteRuntimeBridgeReady(context: context)
            let reqId = body["reqId"] as? String
            do {
                let json = try viewModel.runtimeStateJSON()
                if let reqId {
                    let replyJSON = "{\"reqId\":\"\(reqId)\",\"state\":\(json)}"
                    replyHandler(replyJSON, nil)
                } else {
                    replyHandler(json, nil)
                }
            } catch {
                replyHandler(nil, "Failed to serialize media runtime state.")
            }
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
    }
}
