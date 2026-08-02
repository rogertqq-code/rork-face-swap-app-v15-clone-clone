#if QA_AUTOMATION
import Foundation

nonisolated struct QASessionState: Codable, Sendable, Hashable {
    let runID: UUID?
    let activatedAt: Date?
    let manifest: QASessionManifest?
    let featureValues: [QAFeatureKey: QAValue]
    let revision: UInt64
}

actor QAFeatureRegistry {
    static let shared = QAFeatureRegistry()

    static let descriptors: [QAFeatureDescriptor] = [
        .init(key: .onboardingComplete, defaultValue: .bool(false), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls the app-owned onboarding completion state."),
        .init(key: .activeTab, defaultValue: .string("preview"), mutableDuringRun: true, requiresRelaunch: false, summary: "Selects the visible root tab."),
        .init(key: .targetURL, defaultValue: .string("about:blank"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls the browser target URL."),
        .init(key: .activeProfileID, defaultValue: .string(""), mutableDuringRun: true, requiresRelaunch: false, summary: "Selects an app-owned device profile."),
        .init(key: .mediaEnabled, defaultValue: .bool(false), mutableDuringRun: true, requiresRelaunch: false, summary: "Enables or disables media delivery."),
        .init(key: .injectionProfile, defaultValue: .string("canvasPipeline"), mutableDuringRun: true, requiresRelaunch: false, summary: "Selects the app-owned media injection implementation."),
        .init(key: .sdkWrappersEnabled, defaultValue: .bool(true), mutableDuringRun: true, requiresRelaunch: false, summary: "Enables supported SDK adapter wrappers."),
        .init(key: .nativeWebRTCEnabled, defaultValue: .bool(true), mutableDuringRun: true, requiresRelaunch: false, summary: "Enables the native WebRTC delivery path."),
        .init(key: .sensorSimulationEnabled, defaultValue: .bool(false), mutableDuringRun: true, requiresRelaunch: false, summary: "Enables deterministic sensor fixtures."),
        .init(key: .sequenceLoopEnabled, defaultValue: .bool(false), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls sequence looping."),
        .init(key: .sequenceEndBehavior, defaultValue: .string("hold"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls sequence completion behavior."),
        .init(key: .audioPolicy, defaultValue: .string("compatibilitySilentFallback"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls combined audio/video fallback behavior."),
        .init(key: .diagnosticsVerbosity, defaultValue: .string("standard"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls QA diagnostics detail."),
        .init(key: .rawSampleMode, defaultValue: .string("off"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls raw-media sample export."),
        .init(key: .rawSampleInterval, defaultValue: .integer(30), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls interval sampling cadence."),
        .init(key: .networkRewriteEnabled, defaultValue: .bool(false), mutableDuringRun: true, requiresRelaunch: false, summary: "Enables the app-owned network rewrite layer."),
        .init(key: .cameraPromptBehavior, defaultValue: .string("automatic"), mutableDuringRun: true, requiresRelaunch: false, summary: "Controls app-owned camera prompt behavior.")
    ]

    private static let defaultsByKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0.defaultValue) })
    private static let descriptorByKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })

    private let defaults: UserDefaults
    private var values: [QAFeatureKey: QAValue] = defaultsByKey
    private var activeManifest: QASessionManifest?
    private var activatedAt: Date?
    private var revision: UInt64 = 0

    init(defaults: UserDefaults = UserDefaults(suiteName: "app.rork.face-swap-live-app-v17.qa") ?? .standard) {
        self.defaults = defaults
    }

    func activate(_ manifest: QASessionManifest) throws -> QASessionState {
        try manifest.validate()
        values = Self.defaultsByKey
        for (key, value) in manifest.featureOverrides {
            try validate(value, for: key)
            values[key] = value
        }
        if let targetURL = manifest.targetURL {
            values[.targetURL] = .string(targetURL.absoluteString)
        }
        activeManifest = manifest
        activatedAt = Date()
        revision &+= 1
        persist()
        return snapshot()
    }

    func value(for key: QAFeatureKey) -> QAValue {
        values[key] ?? Self.defaultsByKey[key] ?? .string("")
    }

    func set(_ value: QAValue, for key: QAFeatureKey) throws -> QASessionState {
        guard let descriptor = Self.descriptorByKey[key], descriptor.mutableDuringRun else {
            throw QAManifestError.invalidFeatureValue(key, expected: "immutable", received: value.typeName)
        }
        try validate(value, for: key)
        values[key] = value
        revision &+= 1
        persist()
        return snapshot()
    }

    func apply(_ overrides: [QAFeatureKey: QAValue]) throws -> QASessionState {
        for (key, value) in overrides {
            guard Self.descriptorByKey[key]?.mutableDuringRun == true else {
                throw QAManifestError.invalidFeatureValue(key, expected: "immutable", received: value.typeName)
            }
            try validate(value, for: key)
        }
        for (key, value) in overrides { values[key] = value }
        revision &+= 1
        persist()
        return snapshot()
    }

    func reset() -> QASessionState {
        values = Self.defaultsByKey
        activeManifest = nil
        activatedAt = nil
        revision &+= 1
        defaults.removeObject(forKey: "qa.activeSession")
        return snapshot()
    }

    func snapshot() -> QASessionState {
        QASessionState(
            runID: activeManifest?.runID,
            activatedAt: activatedAt,
            manifest: activeManifest,
            featureValues: values,
            revision: revision
        )
    }

    private func validate(_ value: QAValue, for key: QAFeatureKey) throws {
        guard let expected = Self.descriptorByKey[key]?.defaultValue.typeName else { return }
        guard value.typeName == expected else {
            throw QAManifestError.invalidFeatureValue(key, expected: expected, received: value.typeName)
        }
    }

    private func persist() {
        let state = snapshot()
        guard let encoded = try? JSONEncoder.qaEncoder.encode(state) else { return }
        defaults.set(encoded, forKey: "qa.activeSession")
    }
}

private extension JSONEncoder {
    nonisolated static var qaEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
#endif
