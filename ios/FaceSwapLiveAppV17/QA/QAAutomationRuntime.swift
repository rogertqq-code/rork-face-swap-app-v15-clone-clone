#if QA_AUTOMATION
import SwiftUI

@MainActor
final class QAAutomationRuntime: ObservableObject {
    enum Status: Equatable {
        case idle
        case active(UUID)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var state: QASessionState?
    @Published private(set) var lastCommandResult: QACommandResult?
    @Published private(set) var lastCommandJSON: String = ""
    @Published private(set) var currentSnapshot: QAApplicationSnapshot?
    @Published private(set) var lastSynchronizationError: String = ""
    @Published private(set) var manifestSynchronized = false
    @Published var isControlSurfacePresented = false

    private var snapshotTask: Task<Void, Never>?

    let applicationAdapter: QAApplicationAdapter
    let commandRouter: QACommandRouter

    init() {
        let applicationAdapter = QAApplicationAdapter()
        self.applicationAdapter = applicationAdapter
        commandRouter = QACommandRouter(application: applicationAdapter)
    }

    func bootstrap() async {
        do {
            if ProcessInfo.processInfo.arguments.contains("-qaResetState") {
                state = await QAFeatureRegistry.shared.reset()
            }
            guard let manifest = try QASessionManifestLoader.load() else {
                status = .failed("manifest unavailable")
                return
            }
            state = try await QAFeatureRegistry.shared.activate(manifest)
            status = .active(manifest.runID)
            startSnapshotPolling()
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func synchronizeManifestFeatures() async {
        guard let manifest = state?.manifest else { return }
        manifestSynchronized = false
        lastSynchronizationError = ""
        do {
            try applicationAdapter.installFixtures(manifest.fixtures)
        } catch {
            lastSynchronizationError = error.localizedDescription
            return
        }

        let orderedKeys: [QAFeatureKey] = [
            .onboardingComplete,
            .activeProfileID,
            .activeTab,
            .injectionProfile,
            .sdkWrappersEnabled,
            .nativeWebRTCEnabled,
            .sensorSimulationEnabled,
            .sequenceLoopEnabled,
            .sequenceEndBehavior,
            .audioPolicy,
            .diagnosticsVerbosity,
            .rawSampleMode,
            .rawSampleInterval,
            .networkRewriteEnabled,
            .cameraPromptBehavior,
            .targetURL,
            .mediaEnabled
        ]
        for key in orderedKeys {
            guard let value = manifest.featureOverrides[key] else { continue }
            do {
                _ = try await applicationAdapter.applyFeature(key, value: value)
            } catch {
                lastSynchronizationError = error.localizedDescription
                return
            }
        }

        do {
            _ = try await applicationAdapter.installBrowserFixtures(manifest.fixtures)
            manifestSynchronized = true
        } catch {
            lastSynchronizationError = error.localizedDescription
        }
    }

    func execute(_ envelope: QACommandEnvelope) async -> QACommandResult {
        let result = await commandRouter.execute(envelope)
        lastCommandResult = result
        lastCommandJSON = encode(result) ?? ""
        state = await QAFeatureRegistry.shared.snapshot()
        currentSnapshot = result.after
        return result
    }

    func execute(_ name: QACommandName, payload: QACommandPayload = QACommandPayload()) async -> QACommandResult? {
        guard let runID else { return nil }
        return await execute(QACommandEnvelope(runID: runID, name: name, payload: payload))
    }

    func executeJSON(_ source: String) async throws -> QACommandResult {
        guard let data = source.data(using: .utf8) else { throw QAManifestError.invalidEncoding }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(QACommandEnvelope.self, from: data)
        return await execute(envelope)
    }

    func refreshSnapshot() async {
        currentSnapshot = await applicationAdapter.snapshot()
        state = await QAFeatureRegistry.shared.snapshot()
    }

    func toggleControlSurface() {
        isControlSurfacePresented.toggle()
    }

    var runID: UUID? { state?.runID }

    private func startSnapshotPolling() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func encode(_ result: QACommandResult) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var bannerDetail: String {
        switch status {
        case .idle: return "STARTING"
        case .active(let runID): return String(runID.uuidString.prefix(8)).uppercased()
        case .failed: return "MANIFEST ERROR"
        }
    }
}

struct QAAutomationBanner: View {
    @ObservedObject var runtime: QAAutomationRuntime

    var body: some View {
        Button {
            runtime.toggleControlSurface()
        } label: {
            HStack(spacing: 8) {
                Text("QA AUTOMATION")
                    .fontWeight(.black)
                Text(runtime.bannerDetail)
                    .fontDesign(.monospaced)
                Image(systemName: "slider.horizontal.3")
            }
            .font(.caption)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.yellow)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("qa.banner")
        .accessibilityLabel("QA AUTOMATION")
        .accessibilityValue(runtime.bannerDetail)
        .accessibilityHint("Opens the QA control surface")
    }
}
#endif
