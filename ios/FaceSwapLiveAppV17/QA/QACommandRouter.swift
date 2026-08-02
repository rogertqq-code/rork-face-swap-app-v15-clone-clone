#if QA_AUTOMATION
import Foundation

actor QACommandRouter {
    private let registry: QAFeatureRegistry
    private let application: QAApplicationAdapter
    private var results: [QACommandResult] = []
    private let maximumHistory = 500

    init(registry: QAFeatureRegistry = .shared, application: QAApplicationAdapter) {
        self.registry = registry
        self.application = application
    }

    func execute(_ envelope: QACommandEnvelope) async -> QACommandResult {
        let startedAt = Date()
        let before = await application.snapshot()
        var values: [String: QAValue] = [:]
        var artifacts: [String] = []
        var traceContext: QATraceContext?

        do {
            guard envelope.version >= QACommandEnvelope.minimumSupportedVersion,
                  envelope.version <= QACommandEnvelope.currentVersion else {
                throw QACommandError.unsupportedVersion(envelope.version)
            }
            traceContext = try envelope.validatedTraceContext()

            switch envelope.name {
            case .getCapabilities:
                values = [
                    "commands": .strings(QACommandName.allCases.map(\.rawValue)),
                    "features": .strings(QAFeatureKey.allCases.map(\.rawValue)),
                    "manifestVersion": .integer(QASessionManifest.currentVersion),
                    "commandVersion": .integer(QACommandEnvelope.currentVersion)
                ]

            case .getState:
                let state = await registry.snapshot()
                values = [
                    "registryRevision": .integer(Int(clamping: state.revision)),
                    "runID": .string(state.runID?.uuidString ?? "")
                ]

            case .setFeature:
                guard let key = envelope.payload.featureKey else { throw QACommandError.missingPayload("featureKey") }
                guard let value = envelope.payload.featureValue else { throw QACommandError.missingPayload("featureValue") }
                values = try await application.applyFeature(key, value: value)
                _ = try await registry.set(value, for: key)

            case .navigateTab:
                guard let tab = envelope.payload.tab else { throw QACommandError.missingPayload("tab") }
                try await application.navigateTab(tab)
                _ = try await registry.set(.string(tab.lowercased()), for: .activeTab)
                values = ["tab": .string(tab.lowercased())]

            case .loadURL:
                guard let url = envelope.payload.url else { throw QACommandError.missingPayload("url") }
                try await application.loadURL(url)
                _ = try await registry.set(.string(url), for: .targetURL)
                values = ["url": .string(url)]

            case .selectProfile:
                guard envelope.payload.profileID != nil || envelope.payload.profileName != nil else {
                    throw QACommandError.missingPayload("profileID or profileName")
                }
                try await application.selectProfile(id: envelope.payload.profileID, name: envelope.payload.profileName)
                values = [
                    "profileID": .string(envelope.payload.profileID?.uuidString ?? ""),
                    "profileName": .string(envelope.payload.profileName ?? "")
                ]

            case .loadSequence:
                guard envelope.payload.sequenceID != nil || envelope.payload.sequenceName != nil else {
                    throw QACommandError.missingPayload("sequenceID or sequenceName")
                }
                try await application.loadSequence(id: envelope.payload.sequenceID, name: envelope.payload.sequenceName)
                values = [
                    "sequenceID": .string(envelope.payload.sequenceID?.uuidString ?? ""),
                    "sequenceName": .string(envelope.payload.sequenceName ?? "")
                ]

            case .enableMedia:
                try await application.enableMedia()
                _ = try await registry.set(.bool(true), for: .mediaEnabled)
                values = ["mediaEnabled": .bool(true)]

            case .startNativeWebRTC:
                if await registry.value(for: .nativeWebRTCEnabled) == .bool(false) {
                    throw QACommandError.commandFailed("Native WebRTC is disabled in the active QA feature registry.")
                }
                let registryAudioPolicy = await registry.value(for: .audioPolicy)
                let registrySampleMode = await registry.value(for: .rawSampleMode)
                let registrySampleInterval = await registry.value(for: .rawSampleInterval)
                values = try await application.startNativeWebRTC(
                    audio: envelope.payload.audio ?? true,
                    video: envelope.payload.video ?? true,
                    audioPolicy: envelope.payload.audioPolicy ?? registryAudioPolicy.stringValue ?? "compatibilitySilentFallback",
                    rawSampleMode: envelope.payload.rawSampleMode ?? registrySampleMode.stringValue ?? "off",
                    rawSampleInterval: envelope.payload.rawSampleInterval ?? registrySampleInterval.integerValue ?? 30
                )

            case .stopMedia:
                try await application.stopMedia()
                _ = try await registry.set(.bool(false), for: .mediaEnabled)
                values = ["mediaEnabled": .bool(false)]

            case .runDiagnostics:
                values = try await application.runDiagnostics()

            case .exportEvidence:
                artifacts = try await application.exportEvidence()
                values = ["artifactCount": .integer(artifacts.count)]

            case .clearState:
                try await application.clearState()
                _ = await registry.reset()
                values = ["cleared": .bool(true)]

            case .simulateMemoryWarning:
                await application.simulateMemoryWarning()
                values = ["notification": .string("UIApplication.didReceiveMemoryWarningNotification")]

            case .terminateSession:
                await application.terminateSession()
                values = ["terminationRequested": .bool(true)]
            }

            let result = QACommandResult(
                id: UUID(),
                runID: envelope.runID,
                commandID: envelope.id,
                command: envelope.name,
                startedAt: startedAt,
                completedAt: Date(),
                status: .succeeded,
                traceID: traceContext?.traceID,
                rootTraceID: traceContext?.rootTraceID,
                spanID: traceContext?.spanID,
                traceparent: traceContext?.traceparent,
                before: before,
                after: await application.snapshot(),
                values: values,
                artifacts: artifacts,
                failure: nil
            )
            append(result)
            return result
        } catch {
            let commandError = error as? QACommandError
            let result = QACommandResult(
                id: UUID(),
                runID: envelope.runID,
                commandID: envelope.id,
                command: envelope.name,
                startedAt: startedAt,
                completedAt: Date(),
                status: .failed,
                traceID: traceContext?.traceID,
                rootTraceID: traceContext?.rootTraceID,
                spanID: traceContext?.spanID,
                traceparent: traceContext?.traceparent,
                before: before,
                after: await application.snapshot(),
                values: values,
                artifacts: artifacts,
                failure: QACommandFailure(
                    code: commandError?.code ?? "command_failed",
                    message: error.localizedDescription
                )
            )
            append(result)
            return result
        }
    }

    func history() -> [QACommandResult] { results }

    func result(for commandID: UUID) -> QACommandResult? {
        results.last { $0.commandID == commandID }
    }

    private func append(_ result: QACommandResult) {
        results.append(result)
        if results.count > maximumHistory {
            results.removeFirst(results.count - maximumHistory)
        }
    }
}

private extension QAValue {
    nonisolated var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    nonisolated var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }
}
#endif
