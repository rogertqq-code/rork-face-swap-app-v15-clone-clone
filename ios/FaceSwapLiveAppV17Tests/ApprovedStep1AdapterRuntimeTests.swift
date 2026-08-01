import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct ApprovedStep1AdapterRuntimeTests {
    @Test func sdkBrokerIsDefinedBeforeAllKnownWrapperCalls() {
        let script = StyleSheetProvider.patchScript
        let declaration = script.range(of: "function fslSdkServeFile(")

        #expect(declaration != nil)
        #expect(script.components(separatedBy: "fslSdkServeFile(").count - 1 >= 7)
        if let declaration {
            for token in [
                "navigator.camera.getPicture",
                "captureImage",
                "captureVideo",
                "_capCam.getPhoto",
                "_capCam.takePhoto",
                "_capCam.recordVideo",
            ] {
                let wrapper = script.range(of: token)
                #expect(wrapper != nil)
                if let wrapper { #expect(declaration.lowerBound < wrapper.lowerBound) }
            }
        }
    }

    @Test func bestEffortAdaptersReturnUsableMediaURLShapes() {
        let script = StyleSheetProvider.patchScript

        #expect(script.contains("function fslSdkBestEffort("))
        #expect(script.contains("window.__fslMediaAdapters"))
        #expect(script.contains("validatedResultShape:false"))
        #expect(script.contains("fslmediaresult"))
        #expect(script.contains("custom-scheme-location"))
        #expect(script.contains("custom-scheme-window-open"))
        #expect(script.contains("custom-scheme-iframe"))
    }

    @Test func htmlFileInputStillUsesARealDataTransferFileList() {
        let script = StyleSheetProvider.patchScript

        #expect(script.contains("function fslApplyFile(input, file)"))
        #expect(script.contains("dt.items.add(file)"))
        #expect(script.contains("input.files = dt.files"))
        #expect(script.contains("new Event('change'"))
    }

    @Test func nativeNavigationDelegateInvokesBestEffortBroker() throws {
        let source = try String(contentsOf: sourceURL("Views/BrowserWebContainer.swift"), encoding: .utf8)

        #expect(source.contains("window.__fslMediaAdapters.request('both', label)"))
        #expect(source.contains("custom-scheme-"))
    }

    private func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FaceSwapLiveAppV17")
            .appendingPathComponent(relativePath)
    }
}
