import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct MediaDeliveryTelemetryTests {
    @Test func eventSnapshotExportsRequestStagesAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaTelemetryEvents-\(UUID().uuidString)", isDirectory: true)
        let store = MediaDeliveryTelemetryStore(rootDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestID = UUID()

        await store.record(MediaDeliveryTraceEvent(
            requestID: requestID,
            navigationSessionID: "navigation-1",
            origin: "https://test.invalid",
            stage: .sourceReady,
            sourceKind: .nativeCamera,
            detail: "camera ready",
            metadata: ["width": "640", "height": "480", "frameRate": "30"]
        ))
        let url = try await store.exportEventSnapshot()
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains(requestID.uuidString))
        #expect(text.contains("sourceReady"))
        #expect(text.contains("frameRate"))
    }

    @Test func rawSampleExportWritesEveryCapturedByte() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaTelemetryRaw-\(UUID().uuidString)", isDirectory: true)
        let store = MediaDeliveryTelemetryStore(rootDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let requestID = UUID()
        let sample = MediaRawSample(
            requestID: requestID,
            sequenceNumber: 1,
            presentationTime: 0.25,
            width: 32,
            height: 32,
            pixelFormat: kCVPixelFormatType_32BGRA,
            planes: [.init(offset: 0, byteCount: bytes.count, bytesPerRow: 128, height: 32)],
            bytes: bytes
        )

        let record = try await store.recordRawSample(sample)
        let persisted = try Data(contentsOf: record.rawFileURL)
        let metadata = try String(contentsOf: record.metadataFileURL, encoding: .utf8)

        #expect(persisted == bytes)
        #expect(record.byteCount == bytes.count)
        #expect(metadata.contains("4096"))
        #expect(metadata.contains(requestID.uuidString))
    }

    @Test func selectorCapturesTheFullPixelBufferForAllFramesMode() throws {
        let requestID = UUID()
        let selector = MediaRawSampleSelector.shared
        selector.configure(requestID: requestID, mode: MediaRawSampleMode(kind: .allFrames))
        defer { selector.remove(requestID: requestID) }

        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            3,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess)
        guard let pixelBuffer else {
            Issue.record("Failed to create test pixel buffer.")
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x5A, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr)
        guard let format else {
            Issue.record("Failed to create test format description.")
            return
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        guard let sampleBuffer, let sample = selector.captureIfSelected(requestID: requestID, sampleBuffer: sampleBuffer) else {
            Issue.record("Failed to capture the selected test sample.")
            return
        }

        #expect(sample.bytes.count == CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        #expect(sample.bytes.allSatisfy { $0 == 0x5A })
    }

    @Test func rawSampleModeIsCarriedFromJavaScriptIntoTheNativeRequest() throws {
        let script = StyleSheetProvider.nativeWebRTCClientScript
        let container = try String(contentsOf: sourceURL("Views/BrowserWebContainer.swift"), encoding: .utf8)

        #expect(script.contains("rawSampleMode"))
        #expect(script.contains("rawSampleInterval"))
        #expect(container.contains("MediaRawSampleModeKind"))
        #expect(container.contains("rawSampleMode: rawSampleMode"))
    }

    private func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FaceSwapLiveAppV17")
            .appendingPathComponent(relativePath)
    }
}
