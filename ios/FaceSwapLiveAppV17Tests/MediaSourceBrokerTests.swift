import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct MediaSourceBrokerTests {
    @Test func requestSpecificSourceResolves() async throws {
        let registry = MediaSourceRegistry()
        let request = makeRequest(kind: .cordovaCamera)
        let source = try makeSource(requestID: request.id)
        defer { try? FileManager.default.removeItem(at: source.resourceURL) }

        await registry.register(source, for: request.id)
        let resolved = try await registry.resolveSource(for: request)

        #expect(resolved == source)
    }

    @Test func standardAdapterShapesAreValidated() async throws {
        let adapter = MediaAdapterBroker()
        let request = makeRequest(kind: .capacitorCamera)
        let source = try makeSource(requestID: request.id)
        defer { try? FileManager.default.removeItem(at: source.resourceURL) }

        let capacitor = try await adapter.serve(adapter: .capacitorCamera, request: request, source: source)
        let cordova = try await adapter.serve(adapter: .cordovaMediaCapture, request: request, source: source)
        let html = try await adapter.serve(adapter: .htmlFileInput, request: request, source: source)

        #expect(capacitor.kind == .webPath)
        #expect(capacitor.validatedResultShape)
        #expect(cordova.kind == .mediaFiles)
        #expect(cordova.resources.first?.filename.hasSuffix(".jpg") == true)
        #expect(html.kind == .fileURL)
    }

    @Test func unlistedCustomAdapterReturnsBestEffortResult() async throws {
        let adapter = MediaAdapterBroker()
        let request = makeRequest(kind: .customScheme, adapterVersion: "unknown-camera-v7")
        let source = try makeSource(requestID: request.id)
        defer { try? FileManager.default.removeItem(at: source.resourceURL) }

        let result = try await adapter.serve(adapter: .customScheme, request: request, source: source)

        #expect(result.kind == .fileURL)
        #expect(!result.validatedResultShape)
        #expect(result.resources.count == 1)
        #expect(result.degradedReason?.contains("best-effort") == true)
    }

    @Test func registeredCustomAdapterPreservesItsTypedResult() async throws {
        let adapter = MediaAdapterBroker()
        let request = makeRequest(kind: .registeredSDK, adapterVersion: "fixture-v1")
        let source = try makeSource(requestID: request.id)
        defer { try? FileManager.default.removeItem(at: source.resourceURL) }

        await adapter.registerCustomAdapter(identifier: "fixture-v1") { request, source in
            MediaAdapterResult(
                requestID: request.id,
                adapter: .registeredSDK,
                kind: .fileURL,
                resources: [MediaAdapterResource(
                    url: source.resourceURL,
                    filename: source.filename ?? "fixture.jpg",
                    mimeType: source.contentType
                )],
                validatedResultShape: true
            )
        }

        let result = try await adapter.serve(adapter: .registeredSDK, request: request, source: source)

        #expect(result.requestID == request.id)
        #expect(result.validatedResultShape)
    }

    private func makeRequest(
        kind: MediaDeliveryRequestKind,
        adapterVersion: String? = nil
    ) -> MediaDeliveryRequest {
        MediaDeliveryRequest(
            navigationSessionID: "navigation-1",
            origin: "https://test.invalid",
            kind: kind,
            constraints: MediaDeliveryConstraints(wantsVideo: true, wantsAudio: false),
            timeout: 60,
            adapterVersion: adapterVersion
        )
    }

    private func makeSource(requestID: UUID) throws -> MediaSourceDescriptor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(requestID.uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url, options: .atomic)
        return MediaSourceDescriptor(
            id: requestID,
            kind: .mockStill,
            contentType: "image/jpeg",
            resourceURL: url,
            filename: url.lastPathComponent,
            dimensions: MediaDimensions(width: 640, height: 480),
            isMock: true
        )
    }
}
