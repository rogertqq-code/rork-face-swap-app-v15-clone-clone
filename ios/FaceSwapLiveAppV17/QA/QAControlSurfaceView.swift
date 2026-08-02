#if QA_AUTOMATION
import SwiftUI

struct QAControlSurfaceView: View {
    @ObservedObject var runtime: QAAutomationRuntime

    @State private var commandJSON = ""
    @State private var commandError = ""
    @State private var urlText = "https://example.com"
    @State private var profileText = ""
    @State private var sequenceText = ""
    @State private var selectedTab = "browser"
    @State private var selectedFeature: QAFeatureKey = .onboardingComplete
    @State private var featureValueText = "true"
    @State private var isExecuting = false
    @FocusState private var commandEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                sessionSection
                liveStateSection
                navigationSection
                featureSection
                mediaSection
                diagnosticsSection
                jsonCommandSection
                resultSection
            }
            .navigationTitle("QA Control")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { runtime.isControlSurfacePresented = false }
                        .accessibilityIdentifier("qa.control.close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { commandEditorFocused = false }
                        .accessibilityIdentifier("qa.command.keyboardDone")
                }
            }
            .task { await runtime.refreshSnapshot() }
        }
        .interactiveDismissDisabled(false)
        .accessibilityIdentifier("qa.control.surface")
    }

    private var sessionSection: some View {
        Section("Session") {
            LabeledContent("Run ID", value: runtime.runID?.uuidString ?? "unavailable")
                .accessibilityIdentifier("qa.control.runID")
            LabeledContent("Build", value: "QA_AUTOMATION")
            LabeledContent("Snapshot", value: runtime.currentSnapshot?.capturedAt.formatted(date: .omitted, time: .standard) ?? "pending")
            Button("Refresh State") { Task { await runtime.refreshSnapshot() } }
                .accessibilityIdentifier("qa.command.refreshState")
            Button("Get Capabilities") { submit(.getCapabilities) }
                .accessibilityIdentifier("qa.command.getCapabilities")
            Button("Get State") { submit(.getState) }
                .accessibilityIdentifier("qa.command.getState")
        }
    }

    private var liveStateSection: some View {
        Section("Live State") {
            stateRow("Tab", runtime.currentSnapshot?.activeTab ?? "")
            stateRow("URL", runtime.currentSnapshot?.currentURL ?? "")
            stateRow("Profile", runtime.currentSnapshot?.activeProfileName ?? "")
            stateRow("Sequence", sequenceValue)
            stateRow("Media", captureValue)
            stateRow("Injection", runtime.currentSnapshot?.injectionProfile ?? "")
            stateRow("Diagnostics", diagnosticsValue)
        }
    }

    private var navigationSection: some View {
        Section("Navigation and Fixtures") {
            Picker("Tab", selection: $selectedTab) {
                ForEach(["preview", "browser", "eyedeekit", "media", "diagnostics", "profile"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            .accessibilityIdentifier("qa.command.tabPicker")

            Button("Navigate Tab") { submit(.navigateTab, payload: QACommandPayload(tab: selectedTab)) }
                .accessibilityIdentifier("qa.command.navigateTab")

            TextField("HTTPS URL", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("qa.command.urlInput")
            Button("Load URL") { submit(.loadURL, payload: QACommandPayload(url: urlText)) }
                .accessibilityIdentifier("qa.command.loadURL")

            TextField("Profile UUID or name", text: $profileText)
                .accessibilityIdentifier("qa.command.profileInput")
            Button("Select Profile") {
                let id = UUID(uuidString: profileText)
                submit(.selectProfile, payload: QACommandPayload(profileID: id, profileName: id == nil ? profileText : nil))
            }
            .accessibilityIdentifier("qa.command.selectProfile")

            TextField("Sequence UUID or name", text: $sequenceText)
                .accessibilityIdentifier("qa.command.sequenceInput")
            Button("Load Sequence") {
                let id = UUID(uuidString: sequenceText)
                submit(.loadSequence, payload: QACommandPayload(sequenceID: id, sequenceName: id == nil ? sequenceText : nil))
            }
            .accessibilityIdentifier("qa.command.loadSequence")
        }
    }

    private var featureSection: some View {
        Section("Feature Registry") {
            Picker("Feature", selection: $selectedFeature) {
                ForEach(QAFeatureKey.allCases, id: \.self) { key in
                    Text(key.rawValue).tag(key)
                }
            }
            .accessibilityIdentifier("qa.command.featurePicker")
            .onChange(of: selectedFeature) { _, key in
                featureValueText = QAFeatureRegistry.descriptors.first(where: { $0.key == key })?.defaultValue.accessibilityString ?? ""
            }

            TextField("Typed value", text: $featureValueText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("qa.command.featureValueInput")

            Button("Apply Feature") {
                do {
                    let value = try featureValue(for: selectedFeature, source: featureValueText)
                    submit(.setFeature, payload: QACommandPayload(featureKey: selectedFeature, featureValue: value))
                } catch {
                    commandError = error.localizedDescription
                }
            }
            .accessibilityIdentifier("qa.command.setFeature")
        }
    }

    private var mediaSection: some View {
        Section("Media") {
            Button("Enable Media") { submit(.enableMedia) }
                .accessibilityIdentifier("qa.command.enableMedia")
            Button("Start Native WebRTC") {
                submit(.startNativeWebRTC, payload: QACommandPayload(audio: true, video: true))
            }
            .accessibilityIdentifier("qa.command.startNativeWebRTC")
            Button("Stop Media") { submit(.stopMedia) }
                .accessibilityIdentifier("qa.command.stopMedia")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics and Lifecycle") {
            Button("Run Diagnostics") { submit(.runDiagnostics) }
                .accessibilityIdentifier("qa.command.runDiagnostics")
            Button("Export Evidence") { submit(.exportEvidence) }
                .accessibilityIdentifier("qa.command.exportEvidence")
            Button("Simulate Memory Warning") { submit(.simulateMemoryWarning) }
                .accessibilityIdentifier("qa.command.simulateMemoryWarning")
            Button("Clear QA State") { submit(.clearState) }
                .accessibilityIdentifier("qa.command.clearState")
            Button("Terminate Session") { submit(.terminateSession) }
                .accessibilityIdentifier("qa.command.terminateSession")
        }
    }

    private var jsonCommandSection: some View {
        Section("JSON Command") {
            TextEditor(text: $commandJSON)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .frame(minHeight: 140)
                .focused($commandEditorFocused)
                .accessibilityIdentifier("qa.command.jsonInput")
            Button(isExecuting ? "Executing…" : "Execute JSON") {
                executeJSON()
            }
            .disabled(isExecuting || commandJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("qa.command.executeJSON")
        }
    }

    private var resultSection: some View {
        Section("Last Result") {
            if !commandError.isEmpty {
                Text(commandError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("qa.command.error")
            }
            Text(runtime.lastCommandJSON.isEmpty ? "No command has completed." : runtime.lastCommandJSON)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("qa.command.resultJSON")
                .accessibilityValue(runtime.lastCommandJSON)
        }
    }

    private func stateRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value.isEmpty ? "—" : value)
    }

    private func submit(_ name: QACommandName, payload: QACommandPayload = QACommandPayload()) {
        isExecuting = true
        commandError = ""
        Task {
            let result = await runtime.execute(name, payload: payload)
            if let failure = result?.failure { commandError = failure.message }
            isExecuting = false
        }
    }

    private func executeJSON() {
        isExecuting = true
        commandError = ""
        Task {
            do {
                let result = try await runtime.executeJSON(commandJSON)
                if let failure = result.failure { commandError = failure.message }
            } catch {
                commandError = error.localizedDescription
            }
            commandEditorFocused = false
            commandJSON = ""
            isExecuting = false
        }
    }

    private func featureValue(for key: QAFeatureKey, source: String) throws -> QAValue {
        guard let descriptor = QAFeatureRegistry.descriptors.first(where: { $0.key == key }) else {
            throw QACommandError.invalidPayload("Unknown feature")
        }
        switch descriptor.defaultValue {
        case .bool:
            guard let value = Bool(source.lowercased()) else { throw QACommandError.invalidPayload("Expected true or false") }
            return .bool(value)
        case .integer:
            guard let value = Int(source) else { throw QACommandError.invalidPayload("Expected an integer") }
            return .integer(value)
        case .double:
            guard let value = Double(source) else { throw QACommandError.invalidPayload("Expected a number") }
            return .double(value)
        case .string:
            return .string(source)
        case .strings:
            return .strings(source.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
    }

    private var sequenceValue: String {
        guard let snapshot = runtime.currentSnapshot else { return "unavailable" }
        return "\(snapshot.sequencePointer)/\(snapshot.sequenceCount)"
    }

    private var captureValue: String {
        guard let snapshot = runtime.currentSnapshot else { return "unavailable" }
        return "\(snapshot.mediaActive ? "active" : "inactive"):\(snapshot.mediaDeliveryStatus)"
    }

    private var diagnosticsValue: String {
        guard let snapshot = runtime.currentSnapshot else { return "unavailable" }
        return snapshot.diagnosticsRunning ? "running:\(snapshot.diagnosticsProgress)" : (snapshot.diagnosticsSummary.isEmpty ? "idle" : snapshot.diagnosticsSummary)
    }
}

struct QAAutomationProbeView: View {
    @ObservedObject var runtime: QAAutomationRuntime

    var body: some View {
        VStack(spacing: 0) {
            probe("qa.value.manifestState", value: runtime.manifestSynchronized ? "synchronized" : "pending")
            probe("qa.value.currentURL", value: runtime.currentSnapshot?.currentURL ?? "")
            probe("qa.value.featureMatrix", value: featureMatrix)
            probe("qa.value.captureState", value: captureState)
            probe("qa.value.webRTCState", value: webRTCState)
            probe("qa.value.sequenceStep", value: sequenceStep)
            probe("qa.value.audioOutcome", value: audioOutcome)
            probe("qa.value.lastError", value: lastError)
            probe("qa.value.lastCommand", value: runtime.lastCommandResult?.command.rawValue ?? "")
            probe("qa.value.lastCommandStatus", value: runtime.lastCommandResult?.status.rawValue ?? "")
            probe("qa.value.sessionTraceID", value: runtime.lastCommandResult?.rootTraceID ?? "")
            probe("qa.value.lastOperationTraceID", value: runtime.lastCommandResult?.traceID ?? "")
            probe("qa.value.lastSpanID", value: runtime.lastCommandResult?.spanID ?? "")
            probe("qa.value.lastTraceparent", value: runtime.lastCommandResult?.traceparent ?? "")
        }
        .frame(width: 1, height: 1)
        .opacity(0.02)
        .allowsHitTesting(false)
    }

    private func probe(_ identifier: String, value: String) -> some View {
        Text(value.isEmpty ? "none" : value)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(identifier)
            .accessibilityValue(value.isEmpty ? "none" : value)
    }

    private var featureMatrix: String {
        guard let values = runtime.state?.featureValues else { return "" }
        return values.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue)=\(values[$0]?.accessibilityString ?? "")" }
            .joined(separator: ";")
    }

    private var captureState: String {
        guard let snapshot = runtime.currentSnapshot else { return "" }
        return "\(snapshot.mediaActive ? "active" : "inactive"):\(snapshot.mediaDeliveryStatus)"
    }

    private var webRTCState: String {
        guard runtime.lastCommandResult?.command == .startNativeWebRTC else { return "idle" }
        return runtime.lastCommandResult?.values["requestID"]?.accessibilityString ?? "starting"
    }

    private var sequenceStep: String {
        guard let snapshot = runtime.currentSnapshot else { return "" }
        return "\(snapshot.sequencePointer)/\(snapshot.sequenceCount)"
    }

    private var audioOutcome: String {
        runtime.lastCommandResult?.values["audioOutcome"]?.accessibilityString ?? ""
    }

    private var lastError: String {
        if let message = runtime.lastCommandResult?.failure?.message, !message.isEmpty { return message }
        if !runtime.lastSynchronizationError.isEmpty { return runtime.lastSynchronizationError }
        if let message = runtime.currentSnapshot?.diagnosticsError, !message.isEmpty { return message }
        return ""
    }
}

private extension QAValue {
    nonisolated var accessibilityString: String {
        switch self {
        case .bool(let value): return String(value)
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .strings(let value): return value.joined(separator: ",")
        }
    }
}
#endif
