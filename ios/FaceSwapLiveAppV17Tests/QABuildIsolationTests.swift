import Foundation
import Testing

struct QABuildIsolationTests {
    @Test func qaConfigurationIsDistinctFromRelease() throws {
        let project = try String(contentsOf: repositoryURL("FaceSwapLiveAppV17.xcodeproj/project.pbxproj"), encoding: .utf8)
        let scheme = try String(contentsOf: repositoryURL("FaceSwapLiveAppV17.xcodeproj/xcshareddata/xcschemes/FaceSwapLiveAppV17-QA.xcscheme"), encoding: .utf8)
        let testPlan = try String(contentsOf: repositoryURL("FaceSwapLiveAppV17-QA.xctestplan"), encoding: .utf8)

        #expect(project.contains("name = \"QA-Debug\""))
        #expect(project.contains("DEBUG QA_AUTOMATION $(inherited)"))
        #expect(project.contains("app.rork.face-swap-live-app-v17.qa"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \"app.rork.face-swap-live-app-v17\""))
        #expect(scheme.contains("buildConfiguration = \"QA-Debug\""))
        #expect(scheme.contains("FaceSwapLiveAppV17-QA.xctestplan"))
        #expect(testPlan.contains("QA_AUTOMATION"))
        #expect(testPlan.contains("Cable Device"))
    }

    @Test func everyQASourceIsCompileGatedAndReleaseDoesNotEnableIt() throws {
        let qaDirectory = repositoryURL("FaceSwapLiveAppV17/QA")
        let files = try FileManager.default.contentsOfDirectory(
            at: qaDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.hasPrefix("#if QA_AUTOMATION"))
            #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        }

        let project = try String(contentsOf: repositoryURL("FaceSwapLiveAppV17.xcodeproj/project.pbxproj"), encoding: .utf8)
        let releaseBlocks = project.components(separatedBy: "name = Release;")
        #expect(releaseBlocks.count >= 5)
        #expect(!releaseBlocks.dropLast().contains { $0.suffix(1_500).contains("QA_AUTOMATION") })
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
