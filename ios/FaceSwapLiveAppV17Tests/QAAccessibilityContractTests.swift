#if QA_AUTOMATION
import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct QAAccessibilityContractTests {
    @Test func requiredRemoteControlIdentifiersRemainPresent() throws {
        let sources = try allAppSourceText()
        let required = [
            "qa.banner",
            "qa.control.surface",
            "qa.command.jsonInput",
            "qa.command.executeJSON",
            "qa.command.resultJSON",
            "qa.value.manifestState",
            "qa.value.currentURL",
            "qa.value.featureMatrix",
            "qa.value.captureState",
            "qa.value.webRTCState",
            "qa.value.sequenceStep",
            "qa.value.audioOutcome",
            "qa.value.lastError",
            "qa.value.sessionTraceID",
            "qa.value.lastOperationTraceID",
            "qa.value.lastSpanID",
            "qa.value.lastTraceparent",
            "app.tabView",
            "tab.preview",
            "tab.browser",
            "tab.eyedeekit",
            "tab.media",
            "tab.diagnostics",
            "tab.profile",
            "preview.screen",
            "preview.capture",
            "browser.screen",
            "browser.urlField",
            "browser.media.toggle",
            "browser.media.next",
            "browser.media.status",
            "browser.controls.sheet",
            "browser.controls.sequence.add",
            "browser.controls.mediaEnabled",
            "browser.injection.picker",
            "browser.nativeCapture.overlay",
            "browser.cameraPrompt.sheet",
            "eyedeekit.screen",
            "eyedeekit.launch",
            "eyedeekit.browser.url",
            "media.screen",
            "media.import.menu",
            "media.filter",
            "diagnostics.screen",
            "diagnostics.fullTest.run",
            "diagnostics.fullTest.progress",
            "diagnostics.fullTest.summary",
            "diagnostics.exportLog",
            "diagnostics.connectionLog.export",
            "profile.screen",
            "profile.create",
            "profile.create.startScan",
            "profile.create.verification.run",
            "profile.create.save",
            "gatekeeper.screen",
            "gatekeeper.code",
            "gatekeeper.key.delete",
            "gatekeeper.lock"
        ]

        for identifier in required {
            let declaredDirectly = sources.contains("accessibilityIdentifier(\"\(identifier)\")")
            let declaredByProbe = sources.contains("probe(\"\(identifier)\"")
            #expect(declaredDirectly || declaredByProbe, "Missing accessibility identifier: \(identifier)")
        }
    }

    @Test func everyInteractiveSwiftUIFileDeclaresAnIdentifier() throws {
        let files = try appSwiftFiles().filter {
            $0.path.contains("/Views/")
                || $0.path.contains("/Gatekeeper/")
                || $0.lastPathComponent == "ContentView.swift"
        }
        let controlTokens = ["Button", "TextField", "SecureField", "TextEditor", "Picker", "Toggle", "Slider", "Stepper", "Menu", "PhotosPicker", "NavigationLink"]

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard controlTokens.contains(where: source.contains) else { continue }
            #expect(source.contains("accessibilityIdentifier("), "Interactive source lacks an accessibility identifier: \(file.lastPathComponent)")
        }
    }

    @Test func machineReadableProbesAreMountedAtTheQARoot() throws {
        let appSource = try String(contentsOf: appRoot.appendingPathComponent("FaceSwapLiveAppV17App.swift"), encoding: .utf8)
        let probeSource = try String(contentsOf: appRoot.appendingPathComponent("QA/QAControlSurfaceView.swift"), encoding: .utf8)

        #expect(appSource.contains("QAAutomationProbeView(runtime: qaRuntime)"))
        #expect(probeSource.contains("qa.value.manifestState"))
        #expect(probeSource.contains("qa.value.lastCommandStatus"))
        #expect(probeSource.contains("qa.value.featureMatrix"))
        #expect(probeSource.contains("qa.value.captureState"))
        #expect(probeSource.contains("qa.value.sessionTraceID"))
        #expect(probeSource.contains("qa.value.lastOperationTraceID"))
        #expect(probeSource.contains("qa.value.lastSpanID"))
        #expect(probeSource.contains("qa.value.lastTraceparent"))
    }

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appRoot: URL {
        iosRoot.appendingPathComponent("FaceSwapLiveAppV17", isDirectory: true)
    }

    private func appSwiftFiles() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private func allAppSourceText() throws -> String {
        try appSwiftFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
#endif
