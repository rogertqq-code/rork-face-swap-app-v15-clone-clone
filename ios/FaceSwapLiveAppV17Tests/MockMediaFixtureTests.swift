import AVFoundation
import Foundation
import Testing
import UIKit
@testable import FaceSwapLiveAppV17

struct MockMediaFixtureTests {
    @MainActor
    @Test func generatedStillAndFrameFixturesAreDecodable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainMockFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let factory = MockMediaFixtureFactory(rootDirectory: root)
        defer { factory.removeAllFixtures() }

        let still = try factory.makeStillFixture(size: MediaDimensions(width: 320, height: 240))
        let frame = try factory.makeFrameFixture(size: MediaDimensions(width: 160, height: 120), frameIndex: 9)

        #expect(still.kind == .mockStill)
        #expect(frame.kind == .mockStill)
        #expect(still.isMock)
        #expect(FileManager.default.fileExists(atPath: still.resourceURL.path))
        #expect(UIImage(contentsOfFile: still.resourceURL.path)?.size.width == 320)
        #expect(UIImage(contentsOfFile: frame.resourceURL.path)?.size.height == 120)
    }

    @MainActor
    @Test func sourceImageCanBecomeAPlainFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainSourceFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let factory = MockMediaFixtureFactory(rootDirectory: root)
        defer { factory.removeAllFixtures() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }

        let source = try factory.makeStillFixture(from: image)

        #expect(source.dimensions == MediaDimensions(width: 80, height: 60))
        #expect(UIImage(contentsOfFile: source.resourceURL.path) != nil)
    }

    @MainActor
    @Test func shortVideoFixtureIsReadable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainVideoFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let factory = MockMediaFixtureFactory(rootDirectory: root)
        defer { factory.removeAllFixtures() }

        let source = try await factory.makeVideoFixture(
            size: MediaDimensions(width: 160, height: 120),
            frameRate: 5,
            duration: 0.4
        )
        let asset = AVURLAsset(url: source.resourceURL)
        let duration = try await asset.load(.duration)

        #expect(source.kind == .mockVideo)
        #expect(FileManager.default.fileExists(atPath: source.resourceURL.path))
        #expect(duration.seconds > 0)
    }

    @Test func lifecycleHooksCoverTheApprovedStopSurfaces() throws {
        let container = try String(contentsOf: sourceURL("Views/BrowserWebContainer.swift"), encoding: .utf8)
        let script = StyleSheetProvider.nativeWebRTCClientScript

        #expect(container.contains("UIApplication.didEnterBackgroundNotification"))
        #expect(container.contains("stopAll(reason: .navigationReplaced)"))
        #expect(container.contains("stopAll(reason: .backgrounded)"))
        #expect(container.contains("stopAll(reason: .callerStopped)"))
        #expect(script.contains("addEventListener('pagehide'"))
        #expect(script.contains("track.stop=function()"))
        #expect(script.contains("stop(requestId)"))
    }

    private func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FaceSwapLiveAppV17")
            .appendingPathComponent(relativePath)
    }
}
