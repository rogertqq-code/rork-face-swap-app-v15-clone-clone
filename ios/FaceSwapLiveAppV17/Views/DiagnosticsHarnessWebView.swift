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

        harness.attach(webView)
        webView.loadHTMLString(
            DiagnosticsHarnessScripts.testPageHTML,
            baseURL: URL(string: "https://fsl.diagnostics.local/camera-test")!
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        BrowserWebViewConfigurationFactory.tearDown(webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        let harness: DiagnosticsTestHarness

        init(harness: DiagnosticsTestHarness) {
            self.harness = harness
        }

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
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }

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
            // The diagnostics engine reads results through its explicit probe calls.
            // No fixture message is allowed to alter browser UI or persisted state.
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard message.name == BrowserWebViewConfigurationFactory.runtimeBridgeName else {
                replyHandler(nil, "Unsupported diagnostics bridge message.")
                return
            }
            replyHandler(MediaRuntimeState.idle().serializedJSON(), nil)
        }
    }
}
