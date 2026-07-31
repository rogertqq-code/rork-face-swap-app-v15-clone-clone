import Foundation
import WebKit

/// Creates the one stable WebKit configuration shared by browsing and the in-app diagnostics fixture.
enum BrowserWebViewConfigurationFactory {
    static let sequenceBridgeName = "fslSeq"
    static let cameraBridgeName = "fslCamera"
    static let traceBridgeName = "fslTrace"
    static let runtimeBridgeName = "fslState"

    static func makeConfiguration(
        videoHandler: any WKURLSchemeHandler,
        imageHandler: any WKURLSchemeHandler,
        messageHandler: any WKScriptMessageHandler,
        replyHandler: any WKScriptMessageHandlerWithReply,
        isDiagnosticsHarness: Bool
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(videoHandler, forURLScheme: "fslvideo")
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: "fslimage")

        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: StyleSheetProvider.patchScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: StyleSheetProvider.constraintLoggingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: StyleSheetProvider.runtimeStateBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: StyleSheetProvider.privateLaneBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: PrivateLane.world
        ))
        if isDiagnosticsHarness {
            controller.addUserScript(WKUserScript(
                source: StyleSheetProvider.harnessMarkScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        controller.add(messageHandler, name: sequenceBridgeName)
        controller.add(messageHandler, name: cameraBridgeName)
        controller.add(messageHandler, name: traceBridgeName)
        controller.addScriptMessageHandler(replyHandler, contentWorld: .page, name: runtimeBridgeName)
        return configuration
    }

    static func tearDown(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: sequenceBridgeName)
        controller.removeScriptMessageHandler(forName: cameraBridgeName)
        controller.removeScriptMessageHandler(forName: traceBridgeName)
        controller.removeScriptMessageHandler(forName: runtimeBridgeName, contentWorld: .page)
    }
}
