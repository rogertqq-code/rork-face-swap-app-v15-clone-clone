#if QA_AUTOMATION
import Foundation
import UIKit
import WebKit

@MainActor
final class QAApplicationAdapter {
    private weak var profileManager: DeviceProfileManager?
    private weak var verificationStore: OfflineVerificationStore?
    private weak var browser: BrowserViewModel?
    private weak var diagnosticsHarness: DiagnosticsTestHarness?

    private var activeTabReader: (() -> String)?
    private var tabSelector: ((String) -> Void)?
    private var onboardingSetter: ((Bool) -> Void)?
    private(set) var terminationRequested = false

    func attachRoot(
        profileManager: DeviceProfileManager,
        verificationStore: OfflineVerificationStore,
        activeTab: @escaping () -> String,
        selectTab: @escaping (String) -> Void,
        setOnboardingComplete: @escaping (Bool) -> Void
    ) {
        self.profileManager = profileManager
        self.verificationStore = verificationStore
        activeTabReader = activeTab
        tabSelector = selectTab
        onboardingSetter = setOnboardingComplete
    }

    func attachBrowser(_ browser: BrowserViewModel) {
        self.browser = browser
    }

    func detachBrowser(_ browser: BrowserViewModel) {
        if self.browser === browser { self.browser = nil }
    }

    func attachDiagnostics(_ harness: DiagnosticsTestHarness) {
        diagnosticsHarness = harness
    }

    @discardableResult
    func installFixtures(_ fixtures: [QAFixtureReference]) throws -> [String] {
        guard let profileManager else { throw QACommandError.rootUnavailable }
        var installed: [String] = []

        for fixture in fixtures where fixture.kind == .profile {
            let profile = try QABuiltInFixtures.profile(from: fixture)
            if profileManager.profiles.contains(where: { $0.id == profile.id }) {
                profileManager.updateProfile(profile)
                profileManager.selectProfile(profile)
            } else {
                profileManager.addProfile(profile)
            }
            onboardingSetter?(true)
            installed.append(fixture.id)
        }

        return installed
    }

    @discardableResult
    func installBrowserFixtures(_ fixtures: [QAFixtureReference]) async throws -> [String] {
        let sequenceFixtures = fixtures.filter { $0.kind == .mediaSequence }
        guard !sequenceFixtures.isEmpty else { return [] }
        let browser = try await requireBrowser()
        var installed: [String] = []
        for fixture in sequenceFixtures {
            _ = try QABuiltInFixtures.installMediaSequence(from: fixture, into: browser.sequenceLibrary)
            installed.append(fixture.id)
        }
        return installed
    }

    func detachDiagnostics(_ harness: DiagnosticsTestHarness) {
        if diagnosticsHarness === harness { diagnosticsHarness = nil }
    }

    func snapshot() async -> QAApplicationSnapshot {
        let eventCount = await MediaDeliveryTelemetryStore.shared.events.count
        let rawCount = await MediaDeliveryTelemetryStore.shared.rawSamples.count
        let profile = profileManager?.activeProfile
        let report = diagnosticsHarness?.latestReport

        return QAApplicationSnapshot(
            capturedAt: Date(),
            rootMounted: profileManager != nil,
            browserMounted: browser != nil,
            diagnosticsMounted: diagnosticsHarness != nil,
            activeTab: activeTabReader?() ?? "unmounted",
            activeProfileID: profile?.id,
            activeProfileName: profile?.name ?? "",
            currentURL: browser?.currentURL?.absoluteString ?? "",
            pageTitle: browser?.pageTitle ?? "",
            sequenceCount: browser?.sequence.count ?? 0,
            sequencePointer: browser?.pointer ?? 0,
            mediaActive: browser?.isMediaActive ?? false,
            injectionProfile: browser?.activeInjectionProfile.rawValue ?? "",
            blockDetectionScripts: browser?.activeNetworkBackend.blockDetectionScripts ?? false,
            rewriteProxy: browser?.activeNetworkBackend.useRewriteProxy ?? false,
            mediaDeliveryStatus: browser?.mediaDeliveryStatus.rawValue ?? "unmounted",
            mediaDeliveryDetail: browser?.mediaDeliveryDetail ?? "",
            diagnosticsRunning: diagnosticsHarness?.isRunning ?? false,
            diagnosticsProgress: diagnosticsHarness?.progress ?? 0,
            diagnosticsSummary: report?.summaryLine ?? "",
            diagnosticsError: diagnosticsHarness?.lastError ?? "",
            telemetryEventCount: eventCount,
            rawSampleCount: rawCount
        )
    }

    func applyFeature(_ key: QAFeatureKey, value: QAValue) async throws -> [String: QAValue] {
        switch (key, value) {
        case (.onboardingComplete, .bool(let complete)):
            guard let onboardingSetter else { throw QACommandError.rootUnavailable }
            onboardingSetter(complete)
        case (.activeTab, .string(let tab)):
            try navigateTab(tab)
        case (.targetURL, .string(let url)):
            try await loadURL(url)
        case (.activeProfileID, .string(let identifier)):
            guard let id = UUID(uuidString: identifier) else { throw QACommandError.invalidPayload("activeProfileID must be a UUID string") }
            try selectProfile(id: id, name: nil)
        case (.mediaEnabled, .bool(let enabled)):
            if enabled { try await enableMedia() } else { try await stopMedia() }
        case (.injectionProfile, .string(let raw)):
            let browser = try await requireBrowser()
            guard let kind = InjectionMethodKind(rawValue: raw) else { throw QACommandError.invalidPayload("Unknown injection profile \(raw)") }
            browser.setInjectionProfile(kind)
        case (.sdkWrappersEnabled, .bool(let enabled)):
            SdkInterceptionStore.shared.isEnabled = enabled
        case (.nativeWebRTCEnabled, .bool(let enabled)):
            if !enabled { try await stopNativeWebRTC() }
        case (.sensorSimulationEnabled, .bool(let enabled)):
            SensorRealismStore.shared.isEnabled = enabled
        case (.sequenceLoopEnabled, .bool(let enabled)):
            let browser = try await requireBrowser()
            browser.endBehavior = enabled ? .loop : .holdLast
            browser.syncMediaToPage()
        case (.sequenceEndBehavior, .string(let raw)):
            let browser = try await requireBrowser()
            guard let behavior = SequenceEndBehavior(rawValue: raw) ?? SequenceEndBehavior.allCases.first(where: { $0.jsValue == raw }) else {
                throw QACommandError.invalidPayload("Unknown sequence end behavior \(raw)")
            }
            browser.endBehavior = behavior
            browser.syncMediaToPage()
        case (.audioPolicy, .string(let raw)):
            guard MediaAudioPolicy(rawValue: raw) != nil else { throw QACommandError.invalidPayload("Unknown audio policy \(raw)") }
        case (.diagnosticsVerbosity, .string(let raw)):
            guard ["standard", "verbose", "trace"].contains(raw) else { throw QACommandError.invalidPayload("Unknown diagnostics verbosity \(raw)") }
        case (.rawSampleMode, .string(let raw)):
            guard MediaRawSampleModeKind(rawValue: raw) != nil else { throw QACommandError.invalidPayload("Unknown raw sample mode \(raw)") }
        case (.rawSampleInterval, .integer(let interval)):
            guard interval > 0 else { throw QACommandError.invalidPayload("rawSampleInterval must be greater than zero") }
        case (.cameraPromptBehavior, .string(let raw)):
            switch raw {
            case "automatic", "off":
                CameraPromptStore.shared.setEnabled(false)
            case "askEveryRequest":
                CameraPromptStore.shared.update {
                    $0.isEnabled = true
                    $0.askForLiveCamera = true
                    $0.askForNativeCamera = true
                    $0.askForFilePick = true
                }
            case "serveNext", "block", "realCamera":
                guard let action = CameraRequestAction(rawValue: raw) else { throw QACommandError.invalidPayload("Unknown camera prompt action \(raw)") }
                CameraPromptStore.shared.update {
                    $0.isEnabled = true
                    $0.askForLiveCamera = true
                    $0.askForNativeCamera = true
                    $0.askForFilePick = true
                    $0.defaultAction = action
                }
            default:
                throw QACommandError.invalidPayload("Unknown camera prompt behavior \(raw)")
            }
        case (.networkRewriteEnabled, .bool(let enabled)):
            let browser = try await requireBrowser()
            browser.setRewriteProxyEnabled(enabled)
        default:
            throw QACommandError.invalidPayload("Feature \(key.rawValue) received \(value.typeName)")
        }
        return ["feature": .string(key.rawValue), "valueType": .string(value.typeName)]
    }

    func navigateTab(_ raw: String) throws {
        guard let tabSelector else { throw QACommandError.rootUnavailable }
        let tab = raw.lowercased()
        let valid = ["preview", "browser", "eyedeekit", "media", "diagnostics", "profile"]
        guard valid.contains(tab) else { throw QACommandError.invalidPayload("Unknown tab \(raw)") }
        tabSelector(tab)
    }

    func loadURL(_ raw: String) async throws {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw QACommandError.invalidPayload("url must be an absolute http or https URL")
        }
        try navigateTab("browser")
        let browser = try await requireBrowser()
        browser.navigateTo(url.absoluteString)
    }

    func selectProfile(id: UUID?, name: String?) throws {
        guard let profileManager else { throw QACommandError.rootUnavailable }
        let profile = profileManager.profiles.first { profile in
            if let id, profile.id == id { return true }
            if let name, profile.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
        guard let profile else { throw QACommandError.profileNotFound }
        profileManager.selectProfile(profile)
        onboardingSetter?(true)
    }

    func loadSequence(id: UUID?, name: String?) async throws {
        let browser = try await requireBrowser()
        let record = browser.sequenceLibrary.saved.first { sequence in
            if let id, sequence.id == id { return true }
            if let name, sequence.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
        guard let record else { throw QACommandError.sequenceNotFound }
        browser.loadSaved(record)
    }

    func enableMedia() async throws {
        let browser = try await requireBrowser()
        browser.enableMedia()
    }

    func startNativeWebRTC(
        audio: Bool,
        video: Bool,
        audioPolicy: String,
        rawSampleMode: String,
        rawSampleInterval: Int
    ) async throws -> [String: QAValue] {
        guard video else { throw QACommandError.invalidPayload("native WebRTC requires video=true") }
        let browser = try await requireBrowser()
        guard let webView = browser.webView else { throw QACommandError.browserUnavailable }
        let body = """
        var api=window.__fslNativeRTCStep1;
        if(!api||typeof api.start!=='function')throw new Error('native-webrtc-client-unavailable');
        if(window.__fslQANativeStream){try{window.__fslQANativeStream.getTracks().forEach(function(track){track.stop();});}catch(e){}}
        var stream=await api.start({video:wantsVideo?{facingMode:'user',width:320,height:240,frameRate:15}:false,audio:wantsAudio,audioPolicy:requestedAudioPolicy,rawSampleMode:sampleMode,rawSampleInterval:sampleInterval,timeoutMs:12000});
        window.__fslQANativeStream=stream;
        return JSON.stringify({requestID:String(stream.__fslNativeRequestId||''),videoTracks:stream.getVideoTracks().length,audioTracks:stream.getAudioTracks().length,audioOutcome:String(stream.__fslAudioOutcome&&stream.__fslAudioOutcome.kind||'')});
        """
        let raw = try await webView.callAsyncJavaScript(
            body,
            arguments: [
                "wantsAudio": audio,
                "wantsVideo": video,
                "requestedAudioPolicy": audioPolicy,
                "sampleMode": rawSampleMode,
                "sampleInterval": max(1, rawSampleInterval)
            ],
            contentWorld: .page
        )
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QACommandError.commandFailed("Native WebRTC returned an unreadable result.")
        }
        return [
            "requestID": .string(object["requestID"] as? String ?? ""),
            "videoTracks": .integer((object["videoTracks"] as? NSNumber)?.intValue ?? 0),
            "audioTracks": .integer((object["audioTracks"] as? NSNumber)?.intValue ?? 0),
            "audioOutcome": .string(object["audioOutcome"] as? String ?? "")
        ]
    }

    func stopMedia() async throws {
        let browser = try await requireBrowser()
        try await stopNativeWebRTC()
        browser.disableMedia()
    }

    private func stopNativeWebRTC() async throws {
        guard let webView = browser?.webView else { return }
        let body = """
        var api=window.__fslNativeRTCStep1,ids=api&&api.activeRequestIDs?api.activeRequestIDs():[];
        if(window.__fslQANativeStream){try{window.__fslQANativeStream.getTracks().forEach(function(track){track.stop();});}catch(e){}window.__fslQANativeStream=null;}
        if(api&&typeof api.stop==='function'){for(var i=0;i<ids.length;i++){try{await api.stop(ids[i]);}catch(e){}}}
        return ids.length;
        """
        _ = try? await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }

    func runDiagnostics() async throws -> [String: QAValue] {
        try navigateTab("diagnostics")
        let harness = try await requireDiagnosticsHarness()
        guard let profileManager, let verificationStore else { throw QACommandError.rootUnavailable }
        await harness.runFullTest(profileManager: profileManager, verificationStore: verificationStore)
        if !harness.lastError.isEmpty { throw QACommandError.commandFailed(harness.lastError) }
        return [
            "summary": .string(harness.latestReport?.summaryLine ?? ""),
            "progress": .double(harness.progress)
        ]
    }

    func exportEvidence() async throws -> [String] {
        var artifacts: [String] = []
        let telemetryURL = try await MediaDeliveryTelemetryStore.shared.exportEventSnapshot()
        artifacts.append(telemetryURL.path)
        if let connectionURL = ConnectionLogService.shared.exportToFile() {
            artifacts.append(connectionURL.path)
        }
        if let report = diagnosticsHarness?.latestReport {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-diagnostics-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            artifacts.append(url.path)
        }
        return artifacts
    }

    func clearState() async throws {
        if let browser {
            try? await stopMedia()
            browser.clearSequence()
            browser.goHome()
        }
        await MediaDeliveryTelemetryStore.shared.removeAllDiagnostics()
        terminationRequested = false
    }

    func simulateMemoryWarning() {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
    }

    func terminateSession() async {
        if browser != nil { try? await stopMedia() }
        terminationRequested = true
    }

    private func requireBrowser() async throws -> BrowserViewModel {
        if let browser { return browser }
        try navigateTab("browser")
        for _ in 0..<150 {
            if let browser { return browser }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QACommandError.browserUnavailable
    }

    private func requireDiagnosticsHarness() async throws -> DiagnosticsTestHarness {
        if let diagnosticsHarness { return diagnosticsHarness }
        for _ in 0..<150 {
            if let diagnosticsHarness { return diagnosticsHarness }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QACommandError.diagnosticsUnavailable
    }
}
#endif
