import Foundation
import XCTest

struct QAUITestLaunchConfiguration {
    enum RunMode: String {
        case simulator
        case cable

        static var current: RunMode {
            if let explicit = ProcessInfo.processInfo.environment["QA_RUN_MODE"], let mode = RunMode(rawValue: explicit) {
                return mode
            }
#if targetEnvironment(simulator)
            return .simulator
#else
            return .cable
#endif
        }
    }

    let runID: UUID
    let runMode: RunMode
    let sessionTraceID: UUID
    let jobID: String?
    let jobOperationTraceID: String?
    let jobSpanID: String?
    let jobTraceparent: String?
    var activeTab: String = "browser"
    var targetURL: URL?
    var includeProfileFixture = true
    var includeMediaSequenceFixture = true
    var additionalFeatures: [QAUITestFeatureKey: QAUITestValue] = [:]

    init(runID: UUID = UUID(), runMode: RunMode = .current) {
        let environment = ProcessInfo.processInfo.environment
        self.runID = runID
        self.runMode = runMode
        self.sessionTraceID = environment["FACESWAP_QA_SESSION_TRACE_ID"]
            .flatMap(UUID.init(uuidString:)) ?? runID
        self.jobID = environment["FACESWAP_QA_JOB_ID"]
        self.jobOperationTraceID = environment["FACESWAP_QA_OPERATION_TRACE_ID"]
        self.jobSpanID = environment["FACESWAP_QA_SPAN_ID"]
        self.jobTraceparent = environment["FACESWAP_QA_TRACEPARENT"]
    }

    func manifestBase64() throws -> String {
        var features: [QAUITestFeatureKey: QAUITestValue] = [
            .onboardingComplete: .bool(true),
            .activeTab: .string(activeTab),
            .mediaEnabled: .bool(false),
            .injectionProfile: .string("canvasPipeline"),
            .sdkWrappersEnabled: .bool(true),
            .nativeWebRTCEnabled: .bool(true),
            .sensorSimulationEnabled: .bool(false),
            .sequenceLoopEnabled: .bool(false),
            .sequenceEndBehavior: .string("holdLast"),
            .audioPolicy: .string("compatibilitySilentFallback"),
            .diagnosticsVerbosity: .string("standard"),
            .rawSampleMode: .string("off"),
            .rawSampleInterval: .integer(30),
            .networkRewriteEnabled: .bool(false),
            .cameraPromptBehavior: .string("automatic")
        ]
        additionalFeatures.forEach { features[$0.key] = $0.value }

        var fixtures: [QAUITestFixtureReference] = []
        if includeProfileFixture {
            fixtures.append(
                QAUITestFixtureReference(
                    id: "qa-profile",
                    kind: .profile,
                    location: "builtin://qa-device-profile-v1",
                    metadata: ["name": "QA Deterministic iPhone"]
                )
            )
        }
        if includeMediaSequenceFixture {
            fixtures.append(
                QAUITestFixtureReference(
                    id: "qa-photo-sequence",
                    kind: .mediaSequence,
                    location: "builtin://qa-photo-sequence-v1",
                    metadata: ["name": "QA Deterministic Photo Sequence"]
                )
            )
        }

        let manifest = QAUITestSessionManifest(
            version: 1,
            runID: runID,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60 * 60),
            targetURL: targetURL,
            featureOverrides: features,
            fixtures: fixtures,
            evidence: QAUITestEvidencePolicy(),
            cleanup: QAUITestCleanupPolicy(),
            labels: [
                "runMode": runMode.rawValue,
                "suite": "xcuitest-scenarios",
                "sessionTraceID": sessionTraceID.uuidString.lowercased(),
                "jobID": jobID ?? "direct-xctest"
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest).base64EncodedString()
    }
}

enum QAUITestFeatureKey: String, Codable, Hashable {
    case onboardingComplete
    case activeTab
    case targetURL
    case activeProfileID
    case mediaEnabled
    case injectionProfile
    case sdkWrappersEnabled
    case nativeWebRTCEnabled
    case sensorSimulationEnabled
    case sequenceLoopEnabled
    case sequenceEndBehavior
    case audioPolicy
    case diagnosticsVerbosity
    case rawSampleMode
    case rawSampleInterval
    case networkRewriteEnabled
    case cameraPromptBehavior
}

enum QAUITestValue: Codable, Hashable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case strings([String])

    private enum CodingKeys: String, CodingKey { case type, bool, integer, double, string, strings }
    private enum ValueType: String, Codable { case bool, integer, double, string, strings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
        case .double: self = .double(try container.decode(Double.self, forKey: .double))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .strings: self = .strings(try container.decode([String].self, forKey: .strings))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .double)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case .strings(let value):
            try container.encode(ValueType.strings, forKey: .type)
            try container.encode(value, forKey: .strings)
        }
    }

    var jsonObject: [String: Any] {
        switch self {
        case .bool(let value): return ["type": "bool", "bool": value]
        case .integer(let value): return ["type": "integer", "integer": value]
        case .double(let value): return ["type": "double", "double": value]
        case .string(let value): return ["type": "string", "string": value]
        case .strings(let value): return ["type": "strings", "strings": value]
        }
    }
}

private enum QAUITestFixtureKind: String, Codable {
    case stillImage
    case video
    case audio
    case mediaSequence
    case browserPage
    case profile
}

private struct QAUITestFixtureReference: Codable {
    let id: String
    let kind: QAUITestFixtureKind
    let location: String
    let metadata: [String: String]
}

private struct QAUITestEvidencePolicy: Codable {
    var screenshotsOnFailure = true
    var screenRecording = false
    var deviceLogs = true
    var webKitTranscript = true
    var diagnosticsBundle = true
    var rawMediaSamples = false
    var maximumArtifactBytes = 512 * 1_024 * 1_024
    var retentionHours = 72
}

private struct QAUITestCleanupPolicy: Codable {
    var stopMedia = true
    var clearQAState = true
    var removeFixtures = true
    var terminateApplication = false
}

private struct QAUITestSessionManifest: Codable {
    let version: Int
    let runID: UUID
    let createdAt: Date
    let expiresAt: Date?
    let targetURL: URL?
    let featureOverrides: [QAUITestFeatureKey: QAUITestValue]
    let fixtures: [QAUITestFixtureReference]
    let evidence: QAUITestEvidencePolicy
    let cleanup: QAUITestCleanupPolicy
    let labels: [String: String]
}

struct QAUITestCommand {
    let name: String
    var payload: [String: Any] = ["labels": [String: String]()]
    var version = 2

    static func navigate(tab: String) -> Self {
        .init(name: "navigateTab", payload: ["tab": tab, "labels": [String: String]()])
    }

    static func loadURL(_ url: String) -> Self {
        .init(name: "loadURL", payload: ["url": url, "labels": [String: String]()])
    }

    static func setFeature(_ key: QAUITestFeatureKey, _ value: QAUITestValue) -> Self {
        .init(
            name: "setFeature",
            payload: ["featureKey": key.rawValue, "featureValue": value.jsonObject, "labels": [String: String]()]
        )
    }

    static func loadSequence(named name: String) -> Self {
        .init(name: "loadSequence", payload: ["sequenceName": name, "labels": [String: String]()])
    }

    static var getCapabilities: Self { .init(name: "getCapabilities") }
    static var getState: Self { .init(name: "getState") }
    static var enableMedia: Self { .init(name: "enableMedia") }
    static var startNativeWebRTC: Self {
        .init(
            name: "startNativeWebRTC",
            payload: [
                "audio": true,
                "video": true,
                "audioPolicy": "compatibilitySilentFallback",
                "rawSampleMode": "off",
                "rawSampleInterval": 30,
                "labels": [String: String]()
            ]
        )
    }
    static var stopMedia: Self { .init(name: "stopMedia") }
    static var runDiagnostics: Self { .init(name: "runDiagnostics") }
    static var exportEvidence: Self { .init(name: "exportEvidence") }
    static var clearState: Self { .init(name: "clearState") }
    static var simulateMemoryWarning: Self { .init(name: "simulateMemoryWarning") }
}

@MainActor
final class QAUITestHarness {
    let app: XCUIApplication
    let configuration: QAUITestLaunchConfiguration

    var runID: UUID { configuration.runID }
    var runMode: QAUITestLaunchConfiguration.RunMode { configuration.runMode }
    var sessionTraceID: UUID { configuration.sessionTraceID }

    init(configuration: QAUITestLaunchConfiguration = QAUITestLaunchConfiguration()) {
        self.configuration = configuration
        app = XCUIApplication()
    }

    func launch(file: StaticString = #filePath, line: UInt = #line) throws {
        app.launchArguments = ["-qaAutomation", "-qaResetState"]
        app.launchEnvironment["QA_AUTOMATION"] = "1"
        app.launchEnvironment["QA_RUN_MODE"] = runMode.rawValue
        app.launchEnvironment["QA_RUN_ID"] = runID.uuidString
        app.launchEnvironment["QA_SESSION_MANIFEST_BASE64"] = try configuration.manifestBase64()
        app.launchEnvironment["FACESWAP_QA_SESSION_TRACE_ID"] = sessionTraceID.uuidString.lowercased()
        if let value = configuration.jobID {
            app.launchEnvironment["FACESWAP_QA_JOB_ID"] = value
        }
        if let value = configuration.jobOperationTraceID {
            app.launchEnvironment["FACESWAP_QA_OPERATION_TRACE_ID"] = value
        }
        if let value = configuration.jobSpanID {
            app.launchEnvironment["FACESWAP_QA_SPAN_ID"] = value
        }
        if let value = configuration.jobTraceparent {
            app.launchEnvironment["FACESWAP_QA_TRACEPARENT"] = value
        }
        app.launch()

        let banner = element("qa.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "QA banner did not appear", file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                let value = self.stringValue(of: banner)
                return value.contains(String(self.runID.uuidString.prefix(8)).uppercased())
            },
            "QA run identifier was not published; banner value was \(stringValue(of: banner))",
            file: file,
            line: line
        )
        let root = element("app.tabView")
        let configuredScreen = element(Self.screenIdentifier(for: configuration.activeTab))
        XCTAssertTrue(
            waitUntil(timeout: 20) { root.exists || configuredScreen.exists },
            "Main tab view did not mount for \(configuration.activeTab)",
            file: file,
            line: line
        )
        waitForProbe("qa.value.manifestState", contains: "synchronized", timeout: 30, file: file, line: line)
        XCTAssertEqual(probeValue("qa.value.lastError"), "none", "QA launch synchronization failed", file: file, line: line)
    }

    func installPermissionHandlers(testCase: XCTestCase) {
        testCase.addUIInterruptionMonitor(withDescription: "Camera, microphone, and photo permissions") { alert in
            let labels = [
                "Allow Full Access",
                "Allow While Using App",
                "Allow",
                "OK",
                "Continue"
            ]
            for label in labels where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    @discardableResult
    func execute(
        _ command: QAUITestCommand,
        expectedStatus: String = "succeeded",
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        openControlSurface(file: file, line: line)
        let input = element("qa.command.jsonInput")
        scrollToHittable(input)
        XCTAssertTrue(input.isHittable, "JSON command input is not hittable", file: file, line: line)

        let commandID = UUID()
        let source = try commandJSON(command, commandID: commandID)
        input.tap()
        input.typeText(source)
        let keyboardDone = element("qa.command.keyboardDone")
        if keyboardDone.waitForExistence(timeout: 3), keyboardDone.isHittable {
            keyboardDone.tap()
        } else if app.keyboards.buttons["Done"].exists {
            app.keyboards.buttons["Done"].tap()
        }

        let executeButton = element("qa.command.executeJSON")
        scrollToHittable(executeButton)
        XCTAssertTrue(executeButton.isHittable, "Execute JSON button is not hittable", file: file, line: line)
        executeButton.tap()

        let resultElement = element("qa.command.resultJSON")
        XCTAssertTrue(
            waitUntil(timeout: timeout) {
                let result = self.stringValue(of: resultElement)
                return result.contains(commandID.uuidString)
                    && result.contains("\"status\" : \"\(expectedStatus)\"")
            },
            "Command \(command.name) did not publish an in-sheet \(expectedStatus) result",
            file: file,
            line: line
        )

        let result = stringValue(of: resultElement)
        XCTAssertEqual(
            topLevelString("rootTraceID", in: result),
            sessionTraceID.uuidString.lowercased(),
            "Command result root trace did not match the queued or live session root",
            file: file,
            line: line
        )
        XCTAssertEqual(
            topLevelString("traceID", in: result),
            commandID.uuidString.lowercased(),
            "Command result operation trace did not match the command identity",
            file: file,
            line: line
        )
        closeControlSurface(file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                self.probeValue("qa.value.lastCommand") == command.name
                    && self.probeValue("qa.value.lastCommandStatus") == expectedStatus
                    && self.probeValue("qa.value.sessionTraceID") == self.sessionTraceID.uuidString.lowercased()
                    && self.probeValue("qa.value.lastOperationTraceID") == commandID.uuidString.lowercased()
            },
            "Command \(command.name) probes did not settle; command=\(probeValue("qa.value.lastCommand")) status=\(probeValue("qa.value.lastCommandStatus")) error=\(probeValue("qa.value.lastError"))",
            file: file,
            line: line
        )
        return result
    }

    func openControlSurface(file: StaticString = #filePath, line: UInt = #line) {
        if element("qa.control.surface").exists { return }
        let banner = element("qa.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "QA banner unavailable", file: file, line: line)
        banner.tap()
        XCTAssertTrue(element("qa.control.surface").waitForExistence(timeout: 10), "QA control surface did not open", file: file, line: line)
    }

    func closeControlSurface(file: StaticString = #filePath, line: UInt = #line) {
        guard element("qa.control.surface").exists else { return }
        let close = element("qa.control.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "QA control close button unavailable", file: file, line: line)
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("qa.control.surface").exists }, "QA control surface did not close", file: file, line: line)
    }

    func waitForElement(
        _ identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing element \(identifier)", file: file, line: line)
        return target
    }

    func waitForElementValue(
        _ identifier: String,
        contains expected: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.stringValue(of: self.element(identifier)).contains(expected) },
            "Element \(identifier) did not contain \(expected); value was \(stringValue(of: element(identifier)))",
            file: file,
            line: line
        )
    }

    func waitForProbe(
        _ identifier: String,
        contains expected: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.probeValue(identifier).contains(expected) },
            "Probe \(identifier) did not contain \(expected); value was \(probeValue(identifier))",
            file: file,
            line: line
        )
    }

    func probeValue(_ identifier: String) -> String {
        stringValue(of: element(identifier))
    }

    func topLevelString(_ key: String, in resultJSON: String) -> String? {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    func resultValue(_ key: String, in resultJSON: String) -> Any? {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["values"] as? [String: Any],
              let encoded = values[key] as? [String: Any],
              let type = encoded["type"] as? String else {
            return nil
        }
        return encoded[type]
    }

    func attachFailureEvidence(to testCase: XCTestCase, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        testCase.add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        testCase.add(hierarchy)

        let probes = [
            "runID=\(runID.uuidString)",
            "runMode=\(runMode.rawValue)",
            "sessionTraceID=\(sessionTraceID.uuidString.lowercased())",
            "jobID=\(configuration.jobID ?? "direct-xctest")",
            "jobOperationTraceID=\(configuration.jobOperationTraceID ?? "none")",
            "jobTraceparent=\(configuration.jobTraceparent ?? "none")",
            "manifestState=\(probeValue("qa.value.manifestState"))",
            "currentURL=\(probeValue("qa.value.currentURL"))",
            "features=\(probeValue("qa.value.featureMatrix"))",
            "capture=\(probeValue("qa.value.captureState"))",
            "webrtc=\(probeValue("qa.value.webRTCState"))",
            "sequence=\(probeValue("qa.value.sequenceStep"))",
            "audio=\(probeValue("qa.value.audioOutcome"))",
            "lastError=\(probeValue("qa.value.lastError"))",
            "lastCommand=\(probeValue("qa.value.lastCommand"))",
            "lastStatus=\(probeValue("qa.value.lastCommandStatus"))",
            "publishedSessionTraceID=\(probeValue("qa.value.sessionTraceID"))",
            "publishedOperationTraceID=\(probeValue("qa.value.lastOperationTraceID"))",
            "publishedSpanID=\(probeValue("qa.value.lastSpanID"))",
            "publishedTraceparent=\(probeValue("qa.value.lastTraceparent"))"
        ].joined(separator: "\n")
        let state = XCTAttachment(string: probes)
        state.name = "\(name)-qa-probes"
        state.lifetime = .keepAlways
        testCase.add(state)
    }

    func terminate() {
        if app.state != .notRunning { app.terminate() }
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private static func screenIdentifier(for tab: String) -> String {
        switch tab {
        case "preview": return "preview.screen"
        case "browser": return "browser.screen"
        case "eyedeekit": return "eyedeekit.screen"
        case "media": return "media.screen"
        case "diagnostics": return "diagnostics.screen"
        case "profile": return "profile.screen"
        default: return "app.tabView"
        }
    }

    private func commandJSON(_ command: QAUITestCommand, commandID: UUID) throws -> String {
        let root = sessionTraceID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanCandidate = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanID = String(spanCandidate.prefix(16))
        let envelope: [String: Any] = [
            "version": command.version,
            "runID": runID.uuidString,
            "id": commandID.uuidString,
            "issuedAt": ISO8601DateFormatter().string(from: Date()),
            "name": command.name,
            "payload": command.payload,
            "traceID": commandID.uuidString.lowercased(),
            "rootTraceID": sessionTraceID.uuidString.lowercased(),
            "spanID": spanID,
            "traceparent": "00-\(root)-\(spanID)-01"
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let source = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "QAUITestHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command JSON encoding failed"])
        }
        return source
    }

    private func scrollToHittable(_ target: XCUIElement) {
        for _ in 0..<10 where !target.isHittable {
            app.swipeUp()
        }
        for _ in 0..<3 where !target.isHittable {
            app.swipeDown()
        }
    }

    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        if !element.label.isEmpty { return element.label }
        return ""
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.2, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }
}
