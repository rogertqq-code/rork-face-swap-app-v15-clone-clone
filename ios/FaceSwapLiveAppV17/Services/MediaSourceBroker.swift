import Foundation

actor MediaSourceRegistry: MediaSourceResolving {
    private var sources: [UUID: MediaSourceDescriptor] = [:]
    private var requestSources: [UUID: UUID] = [:]

    func register(_ source: MediaSourceDescriptor, for requestID: UUID? = nil) {
        sources[source.id] = source
        if let requestID { requestSources[requestID] = source.id }
    }

    func removeSource(_ sourceID: UUID) {
        sources.removeValue(forKey: sourceID)
        requestSources = requestSources.filter { $0.value != sourceID }
    }

    func removeAll() {
        sources.removeAll()
        requestSources.removeAll()
    }

    func resolveSource(for request: MediaDeliveryRequest) async throws -> MediaSourceDescriptor {
        guard Date() < request.deadline else { throw MediaDeliveryContractError.timedOut }
        if let sourceID = requestSources[request.id], let source = sources[sourceID] {
            return try validated(source)
        }
        if let source = sources.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
            return try validated(source)
        }
        throw MediaDeliveryContractError.sourceUnavailable("No media source is registered for the request.")
    }

    private func validated(_ source: MediaSourceDescriptor) throws -> MediaSourceDescriptor {
        guard !source.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaDeliveryContractError.sourceUnavailable("The media source has no content type.")
        }
        guard FileManager.default.fileExists(atPath: source.resourceURL.path) else {
            throw MediaDeliveryContractError.sourceUnavailable("The media source file is unavailable.")
        }
        return source
    }
}

actor MediaAdapterBroker: MediaAdapterServing {
    typealias CustomAdapter = @Sendable (
        MediaDeliveryRequest,
        MediaSourceDescriptor
    ) async throws -> MediaAdapterResult

    private var registeredCustomAdapters: [String: CustomAdapter] = [:]

    func registerCustomAdapter(
        identifier: String,
        adapter: @escaping CustomAdapter
    ) {
        registeredCustomAdapters[normalized(identifier)] = adapter
    }

    func serve(
        adapter: MediaAdapterKind,
        request: MediaDeliveryRequest,
        source: MediaSourceDescriptor
    ) async throws -> MediaAdapterResult {
        guard Date() < request.deadline else { throw MediaDeliveryContractError.timedOut }
        let resource = try makeResource(from: source)

        switch adapter {
        case .cordovaCamera:
            return MediaAdapterResult(
                requestID: request.id,
                adapter: adapter,
                kind: .fileURL,
                resources: [resource],
                validatedResultShape: true
            )
        case .cordovaMediaCapture:
            return MediaAdapterResult(
                requestID: request.id,
                adapter: adapter,
                kind: .mediaFiles,
                resources: [resource],
                validatedResultShape: true
            )
        case .capacitorCamera:
            return MediaAdapterResult(
                requestID: request.id,
                adapter: adapter,
                kind: .webPath,
                resources: [resource],
                validatedResultShape: true
            )
        case .htmlFileInput:
            return MediaAdapterResult(
                requestID: request.id,
                adapter: adapter,
                kind: .fileURL,
                resources: [resource],
                validatedResultShape: true
            )
        case .customScheme, .registeredSDK:
            let identifier = normalized(request.adapterVersion ?? "")
            if let customAdapter = registeredCustomAdapters[identifier] {
                let result = try await customAdapter(request, source)
                guard !result.resources.isEmpty || result.kind == .unsupported else {
                    throw MediaDeliveryContractError.adapterResultInvalid("The custom adapter returned no resources.")
                }
                return result
            }
            return MediaAdapterResult(
                requestID: request.id,
                adapter: adapter,
                kind: .fileURL,
                resources: [resource],
                validatedResultShape: false,
                degradedReason: "No exact adapter matched '\(request.adapterVersion ?? "unknown")'; returned a best-effort file URL."
            )
        }
    }

    private func makeResource(from source: MediaSourceDescriptor) throws -> MediaAdapterResource {
        let filename = source.filename ?? source.resourceURL.lastPathComponent
        guard !filename.isEmpty else {
            throw MediaDeliveryContractError.adapterResultInvalid("The media resource has no filename.")
        }
        let values = try? source.resourceURL.resourceValues(forKeys: [.fileSizeKey])
        return MediaAdapterResource(
            url: source.resourceURL,
            filename: filename,
            mimeType: source.contentType,
            byteCount: values?.fileSize,
            duration: source.duration
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
