import Foundation
import WebKit
import UIKit

nonisolated enum DeviceTestPhase: Sendable {
    case idle
    case loadingReal
    case capturingRealDescriptors
    case loadingProcessed
    case capturingProcessedDescriptors
    case comparing
    case diagnosticsSweep
    case complete
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .loadingReal: return "Loading Loom media test (real)…"
        case .capturingRealDescriptors: return "Capturing real descriptors…"
        case .loadingProcessed: return "Loading Loom media test (processed)…"
        case .capturingProcessedDescriptors: return "Capturing processed descriptors…"
        case .comparing: return "Comparing original vs processed…"
        case .diagnosticsSweep: return "Running full method sweep…"
        case .complete: return "Test complete"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}

nonisolated struct UnifiedDeviceTestResult: Codable, Sendable {
    var identityBaseline: MediaTestResult?
    var environment: DiagTestEnvironment?
    var methodResults: [DiagMethodResult] = []
    var passthroughResult: DiagPassthroughResult?
    var blockResult: DiagBlockResult?
    var recommendedMethod: InjectionMethodKind?
    var recommendedAdjustments: [String] = []
    var summaryLine: String = ""
    var liveValidation: Bool?
}

@MainActor
final class DeviceTestEngine {
    
    /// Minimal local HTML page for media descriptor capture. Replaces the external
    /// Loom.com dependency with an always-available local page that provides a valid
    /// secure context (via https:// baseURL) where navigator.mediaDevices exists.
    static let localCaptureHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>FSL Media Capture</title>
    <style>
      html,body{margin:0;padding:0;background:#0b0b0f;color:#8a8a99;font:12px -apple-system,system-ui,sans-serif;}
    </style>
    </head>
    <body>
    <div id="status">media capture page</div>
    <script>
      window.__fslHarnessReady = true;
    </script>
    </body>
    </html>
    """

    /// Bumped for every fixture push so the engine's own pointer-reset rule fires
    /// and each combination starts from a clean live and native cursor.
    private var fixtureSequenceVersion: Int = 0

    /// A real, app-generated JPEG carried entirely in the app-owned fixture.
    /// This avoids a missing scheme-handler resource masquerading as a media pass.
    private static func fixtureJPEGPayload() -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor(red: 0.06, green: 0.62, blue: 0.73, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor.white.setFill()
            context.fill(CGRect(x: 6, y: 6, width: 20, height: 12))
        }
        return image.jpegData(compressionQuality: 0.8)?.base64EncodedString() ?? ""
    }

    static let captureJS: String = """
    (async function(){
        var result = {};
        var md = navigator.mediaDevices;
        if(!md) return JSON.stringify({error:'No mediaDevices'});

        var sc = md.getSupportedConstraints ? md.getSupportedConstraints() : {};
        result.supportedConstraints = Object.keys(sc).filter(function(k){return sc[k];});

        var devs = await md.enumerateDevices();
        result.devices = devs.map(function(d){
            return {deviceId:d.deviceId||'',groupId:d.groupId||'',kind:d.kind||'',label:d.label||''};
        });

        try {
            var stream = await md.getUserMedia({video:true, audio:false});
            var vt = stream.getVideoTracks()[0];
            if(vt){
                result.trackLabel = vt.label || '';
                result.trackReadyState = vt.readyState || '';
                result.trackContentHint = vt.contentHint || '';
                result.trackMuted = vt.muted || false;
                result.trackEnabled = vt.enabled || true;
                result.mediaStreamId = stream.id || '';
                result.mediaStreamActive = stream.active || false;

                if(vt.getSettings){
                    var s = vt.getSettings();
                    result.trackSettings = {
                        deviceId: s.deviceId || '',
                        groupId: s.groupId || '',
                        width: s.width || 0,
                        height: s.height || 0,
                        frameRate: s.frameRate || 0,
                        facingMode: s.facingMode || '',
                        aspectRatio: s.aspectRatio || 0,
                        resizeMode: s.resizeMode || ''
                    };
                }

                if(vt.getCapabilities){
                    try{
                        var c = vt.getCapabilities();
                        result.trackCapabilities = {
                            deviceId: c.deviceId || '',
                            groupId: c.groupId || '',
                            widthMin: c.width ? (c.width.min || 0) : 0,
                            widthMax: c.width ? (c.width.max || 0) : 0,
                            heightMin: c.height ? (c.height.min || 0) : 0,
                            heightMax: c.height ? (c.height.max || 0) : 0,
                            frameRateMin: c.frameRate ? (c.frameRate.min || 0) : 0,
                            frameRateMax: c.frameRate ? (c.frameRate.max || 0) : 0,
                            facingModes: c.facingMode || [],
                            resizeModes: c.resizeMode || []
                        };
                    }catch(e){}
                }

                stream.getTracks().forEach(function(t){t.stop();});
            }
        } catch(e) {
            result.error = e.toString();
        }

        return JSON.stringify(result);
    })()
    """

    private var activeWebView: WKWebView?
    private var coordinator: LoomNavDelegate?
    
    /// Runs the browser fixture only on the web view already mounted in the
    /// Diagnostics screen. This avoids treating an off-hierarchy WebKit instance
    /// as proof of media or permission behavior.
    func runMountedFixtureTest(
        profile: DeviceProfile,
        on webView: WKWebView,
        progressCallback: @escaping (DeviceTestPhase, Double, String) -> Void
    ) async -> UnifiedDeviceTestResult? {
        var result = UnifiedDeviceTestResult()
        progressCallback(.diagnosticsSweep, 0.05, "Preparing the mounted offline fixture…")

        let ready = await waitForReady(webView)
        var environment = await readEnvironment(webView)
        environment.deviceProfileName = profile.name
        environment.profileResolution = DiagnosticsTestHarness.resolutionLabel(profile)
        result.environment = environment
        guard ready, environment.secureContext, environment.hasMediaDevices else {
            result.summaryLine = "Inconclusive: the mounted offline fixture did not reach a secure camera context."
            progressCallback(.failed("Offline fixture unavailable"), 1.0, result.summaryLine)
            return result
        }

        webView.evaluateJavaScript(
            StyleSheetProvider.profileApplyScript(from: profile, method: .canvasPipeline),
            completionHandler: nil
        )

        let methods = InjectionMethodKind.deliveryMethods
        var rows: [DiagMethodResult] = []
        let total = max(methods.count + 2, 1)
        var index = 0
        for method in methods {
            index += 1
            let pct = 0.08 + (Double(index) / Double(total) * 0.78)
            progressCallback(.diagnosticsSweep, pct, "Testing \(method.label) with the built-in image fixture…")
            rows.append(await runCombination(webView, method: method, media: "photo"))
        }

        index += 1
        progressCallback(.diagnosticsSweep, 0.90, "Checking pass-through behavior…")
        result.passthroughResult = await runPassthrough(webView)
        index += 1
        progressCallback(.diagnosticsSweep, 0.96, "Checking the block step…")
        result.blockResult = await runBlock(webView)
        result.methodResults = rows

        let candidate = DiagnosticsTestHarness.recommendMethod(from: rows)
        let candidateRows = candidate.map { method in rows.filter { $0.methodRaw == method.rawValue } } ?? []
        // A warning-only method is useful diagnostic information, not enough to
        // become a persistent recommendation.
        result.recommendedMethod = candidateRows.isEmpty || candidateRows.contains(where: { $0.overall != .pass })
            ? nil
            : candidate
        result.summaryLine = DiagnosticsTestHarness.summaryLine(
            results: rows,
            recommended: result.recommendedMethod
        )
        progressCallback(.complete, 1.0, "Done — \(result.summaryLine)")
        return result
    }

    // MARK: - Phase A Details
    private func captureFromLoom(processed: Bool, profile: DeviceProfile?) async -> MediaSnapshot? {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if processed, let profile {
            let styleScript = WKUserScript(
                source: StyleSheetProvider.patchScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(styleScript)

            let profileJS = StyleSheetProvider.profileApplyScript(from: profile)
            config.userContentController.addUserScript(WKUserScript(
                source: profileJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))

            let activateJS = """
            (function(){
            var s=window[Symbol.for('fsl')];
            if(!s)return;
            s.a=true;
            s.ra=true;
            s.is='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
            s.vs=null;
            try{navigator.mediaDevices.dispatchEvent(new Event('devicechange'));}catch(e){}
            })();
            """
            config.userContentController.addUserScript(WKUserScript(
                source: activateJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = StyleSheetProvider.safariUserAgent
        self.activeWebView = wv

        let didLoad = await loadLocalPage(in: wv)

        guard didLoad else {
            self.activeWebView = nil
            return nil
        }

        try? await Task.sleep(for: .seconds(1))

        let snapshot = await executeCapture(in: wv)
        self.activeWebView = nil
        return snapshot
    }

    private func loadLocalPage(in webView: WKWebView) async -> Bool {
        return await withCheckedContinuation { continuation in
            var didResume = false
            let lock = NSLock()

            func safeResume(_ value: Bool) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(returning: value)
            }

            let coord = LoomNavDelegate(
                onPageLoaded: { safeResume(true) },
                onPageFailed: { safeResume(false) }
            )
            self.coordinator = coord
            webView.navigationDelegate = coord

            webView.loadHTMLString(
                Self.localCaptureHTML,
                baseURL: URL(string: "https://fsl.diagnostics.local/camera-test")!
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.coordinator = nil
                safeResume(false)
            }
        }
    }

    private func executeCapture(in webView: WKWebView) async -> MediaSnapshot? {
        do {
            let result = try await webView.callAsyncJavaScript(
                Self.captureJS,
                arguments: [:],
                contentWorld: .page
            )

            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return parseSnapshot(dict)
        } catch {
            return nil
        }
    }

    func parseSnapshot(_ dict: [String: Any]) -> MediaSnapshot {
        func intVal(_ v: Any?) -> Int {
            if let n = v as? Int { return n }
            if let d = v as? Double { return Int(d) }
            return 0
        }
        func doubleVal(_ v: Any?) -> Double {
            if let d = v as? Double { return d }
            if let n = v as? Int { return Double(n) }
            return 0
        }

        let sc = dict["supportedConstraints"] as? [String] ?? []
        var devices: [MediaDeviceEntry] = []
        if let devs = dict["devices"] as? [[String: Any]] {
            for d in devs {
                devices.append(MediaDeviceEntry(
                    deviceId: d["deviceId"] as? String ?? "",
                    groupId: d["groupId"] as? String ?? "",
                    kind: d["kind"] as? String ?? "",
                    label: d["label"] as? String ?? ""
                ))
            }
        }

        var trackSettings: MediaTrackSettings?
        if let ts = dict["trackSettings"] as? [String: Any] {
            trackSettings = MediaTrackSettings(
                deviceId: ts["deviceId"] as? String ?? "",
                groupId: ts["groupId"] as? String ?? "",
                width: intVal(ts["width"]),
                height: intVal(ts["height"]),
                frameRate: doubleVal(ts["frameRate"]),
                facingMode: ts["facingMode"] as? String ?? "",
                aspectRatio: doubleVal(ts["aspectRatio"]),
                resizeMode: ts["resizeMode"] as? String ?? ""
            )
        }

        var trackCapabilities: MediaTrackCapabilities?
        if let tc = dict["trackCapabilities"] as? [String: Any] {
            trackCapabilities = MediaTrackCapabilities(
                deviceId: tc["deviceId"] as? String ?? "",
                groupId: tc["groupId"] as? String ?? "",
                widthMin: intVal(tc["widthMin"]),
                widthMax: intVal(tc["widthMax"]),
                heightMin: intVal(tc["heightMin"]),
                heightMax: intVal(tc["heightMax"]),
                frameRateMin: doubleVal(tc["frameRateMin"]),
                frameRateMax: doubleVal(tc["frameRateMax"]),
                facingModes: tc["facingModes"] as? [String] ?? [],
                resizeModes: tc["resizeModes"] as? [String] ?? []
            )
        }

        return MediaSnapshot(
            devices: devices,
            trackSettings: trackSettings,
            trackCapabilities: trackCapabilities,
            trackLabel: dict["trackLabel"] as? String ?? "",
            trackReadyState: dict["trackReadyState"] as? String ?? "",
            trackContentHint: dict["trackContentHint"] as? String ?? "",
            trackMuted: dict["trackMuted"] as? Bool ?? false,
            trackEnabled: dict["trackEnabled"] as? Bool ?? true,
            supportedConstraints: sc,
            mediaStreamId: dict["mediaStreamId"] as? String ?? "",
            mediaStreamActive: dict["mediaStreamActive"] as? Bool ?? false
        )
    }

    func buildComparisons(real: MediaSnapshot?, processed: MediaSnapshot?) -> [MediaComparisonResult] {
        guard let real = real, let processed = processed else { return [] }

        var comps: [MediaComparisonResult] = []
        func add(_ field: String, _ a: String, _ b: String) {
            comps.append(MediaComparisonResult(field: field, realValue: a, processedValue: b, matches: a == b))
        }

        add("supportedConstraints", real.supportedConstraints.joined(separator: ","), processed.supportedConstraints.joined(separator: ","))
        add("track.label", real.trackLabel, processed.trackLabel)
        add("track.readyState", real.trackReadyState, processed.trackReadyState)

        if let rs = real.trackSettings, let ps = processed.trackSettings {
            add("track.settings.width", "\(rs.width)", "\(ps.width)")
            add("track.settings.height", "\(rs.height)", "\(ps.height)")
            add("track.settings.frameRate", "\(rs.frameRate)", "\(ps.frameRate)")
            add("track.settings.facingMode", rs.facingMode, ps.facingMode)
        }

        return comps
    }

    // MARK: - Phase B Details

    private func createDiagnosticsWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let handler = LocalResourceHandler()
        config.setURLSchemeHandler(handler, forURLScheme: "fslvideo")
        config.setURLSchemeHandler(handler, forURLScheme: "fslimage")
        
        let styleScript = WKUserScript(
            source: StyleSheetProvider.patchScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(styleScript)
        // The app's OWN test page: diagnostics behaviour that must never touch
        // real browsing is gated on this flag.
        config.userContentController.addUserScript(WKUserScript(
            source: StyleSheetProvider.harnessMarkScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = StyleSheetProvider.safariUserAgent
        return wv
    }
    
    private func waitForReady(_ webView: WKWebView) async -> Bool {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let ready = try? await webView.evaluateJavaScript("!!(window.__fslHarnessReady && window.__fslRuntimeStateReady)") as? Bool, ready {
                return true
            }
        }
        return false
    }

    private func readEnvironment(_ webView: WKWebView) async -> DiagTestEnvironment {
        let js = """
        ({
            hasMediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
            userAgent: navigator.userAgent,
            isSecureContext: window.isSecureContext,
            hasWorker: (typeof Worker !== 'undefined'),
            hasVideoFrame: (typeof VideoFrame !== 'undefined'),
            hasVTG: (typeof VideoTrackGenerator !== 'undefined')
        })
        """
        guard let dict = try? await webView.evaluateJavaScript(js) as? [String: Any] else {
            return DiagTestEnvironment()
        }
        return DiagTestEnvironment(
            userAgent: dict["userAgent"] as? String ?? "",
            iosVersion: UIDevice.current.systemVersion,
            secureContext: dict["isSecureContext"] as? Bool ?? false,
            hasMediaDevices: dict["hasMediaDevices"] as? Bool ?? false,
            hasWorker: dict["hasWorker"] as? Bool ?? false,
            hasVideoFrame: dict["hasVideoFrame"] as? Bool ?? false,
            hasVideoTrackGenerator: dict["hasVTG"] as? Bool ?? false
        )
    }

    private func runCombination(_ webView: WKWebView, method: InjectionMethodKind, media: String) async -> DiagMethodResult {
        pushSequence(webView, method: method, media: media)
        try? await Task.sleep(for: .milliseconds(160))

        guard let raw = await callProbe(webView, body: DiagnosticsHarnessScripts.fullTestProbeBody) else {
            return DiagMethodResult(
                methodRaw: method.rawValue,
                mediaKind: media,
                overall: .fail,
                notes: "The page blocked the probe before it could finish."
            )
        }

        func boolVal(_ v: Any?) -> Bool { v as? Bool ?? false }
        func intVal(_ v: Any?) -> Int { v as? Int ?? 0 }
        func doubleVal(_ v: Any?) -> Double { v as? Double ?? 0 }

        var r = DiagMethodResult(
            methodRaw: method.rawValue,
            mediaKind: media,
            armed: boolVal(raw["armed"]),
            armError: raw["armError"] as? String ?? "",
            gumSucceeded: boolVal(raw["gumOK"]),
            gumError: raw["gumError"] as? String ?? "",
            width: intVal(raw["width"]),
            height: intVal(raw["height"]),
            claimedFps: doubleVal(raw["fps"]),
            feed: raw["feed"] as? String ?? "",
            lane: raw["lane"] as? String ?? "",
            downgraded: boolVal(raw["downgraded"]),
            reason: raw["reason"] as? String ?? "",
            framesFlowing: boolVal(raw["framesFlowing"]),
            measuredFps: doubleVal(raw["measuredFps"]),
            frameCount: intVal(raw["frameCount"]),
            srRealism: boolVal(raw["srRealism"]),
            srCanvas: boolVal(raw["srCanvas"]),
            pickerReturnedMedia: boolVal(raw["pickerOK"]),
            pickerFileType: raw["pickerType"] as? String ?? "",
            pickerFileSize: intVal(raw["pickerSize"]),
            captureReturnedMedia: boolVal(raw["captureOK"]),
            captureFileType: raw["captureType"] as? String ?? "",
            captureFileSize: intVal(raw["captureSize"]),
            captureFileName: raw["captureName"] as? String ?? ""
        )

        if let detRaw = await callProbe(webView, body: StyleSheetProvider.detectorSelfTestBody) {
            r.detectorScore = intVal(detRaw["score"])
            r.detectorChecks = DiagnosticsTestHarness.parseDetectorChecks(detRaw["checks"])
        }

        r.overall = DiagnosticsTestHarness.overall(for: r)
        r.notes = DiagnosticsTestHarness.notes(for: r)
        return r
    }

    private func runPassthrough(_ webView: WKWebView) async -> DiagPassthroughResult {
        pushSequence(webView, method: .passthrough, media: "photo")
        try? await Task.sleep(for: .milliseconds(140))
        guard let raw = await callProbe(webView, body: DiagnosticsHarnessScripts.simpleGumProbeBody) else {
            return DiagPassthroughResult(status: .skip, note: "Probe did not complete.")
        }
        func boolVal(_ v: Any?) -> Bool { v as? Bool ?? false }
        
        let feed = raw["feed"] as? String ?? ""
        let gumOK = boolVal(raw["gumOK"])
        let virtualEngaged = (feed == "vtg" || feed == "canvas")
        let status: DiagTestStatus = virtualEngaged ? .fail : .pass
        let note: String
        if virtualEngaged {
            note = "A virtual feed engaged under Passthrough — injection should have been bypassed."
        } else if gumOK {
            note = "Request passed to the real camera (no virtual feed). Correct."
        } else {
            note = "Request passed through to the real camera path (rejected here because the simulator has no camera). Correct on device."
        }
        return DiagPassthroughResult(virtualFeedEngaged: virtualEngaged, gumSucceeded: gumOK, status: status, note: note)
    }

    private func runBlock(_ webView: WKWebView) async -> DiagBlockResult {
        pushSequence(webView, method: .canvasPipeline, media: "block")
        try? await Task.sleep(for: .milliseconds(140))
        guard let raw = await callProbe(webView, body: DiagnosticsHarnessScripts.simpleGumProbeBody) else {
            return DiagBlockResult(status: .skip, note: "Probe did not complete.")
        }
        func boolVal(_ v: Any?) -> Bool { v as? Bool ?? false }
        let gumOK = boolVal(raw["gumOK"])
        let err = raw["gumError"] as? String ?? ""
        let refused = !gumOK
        return DiagBlockResult(
            refused: refused,
            gumError: err,
            status: refused ? .pass : .fail,
            note: refused ? "Block step correctly refused the live camera request." : "Block step did NOT refuse the request — the feed was served."
        )
    }

    private func callProbe(_ webView: WKWebView, body: String) async -> [String: Any]? {
        let call = """
        (async function(){
            \(body)
        })()
        """
        do {
            let res = try await webView.callAsyncJavaScript(call, arguments: [:], in: nil, contentWorld: .page)
            if let str = res as? String, let data = str.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Pushes a fixture step using exactly the field names and payload map the
    /// live engine reads, so the test drives the real delivery path instead of a
    /// look-alike shape the engine would silently ignore.
    private func pushSequence(_ webView: WKWebView, method: InjectionMethodKind, media: String) {
        let stepJSON: String
        var payloadJSON: String = "{}"
        switch media {
        case "video":
            stepJSON = SequenceScriptBuilder.stepObjectJS(SequenceStepScript(
                id: "fixture-video",
                kindJS: SequenceStepKind.video.jsValue,
                blockJS: SequenceBlockMode.once.jsValue,
                liveJS: LiveCameraMode.serveLive.jsValue,
                surfaceJS: RequestSurface.either.jsValue,
                img: nil,
                vid: "fslvideo://step/fixture-video",
                empty: false
            ))
        case "block":
            stepJSON = SequenceScriptBuilder.stepObjectJS(SequenceStepScript(
                id: "fixture-block",
                kindJS: SequenceStepKind.webRTCBlock.jsValue,
                blockJS: SequenceBlockMode.once.jsValue,
                liveJS: LiveCameraMode.serveLive.jsValue,
                surfaceJS: RequestSurface.either.jsValue,
                img: nil,
                vid: nil,
                empty: false
            ))
        default:
            let jpeg = Self.fixtureJPEGPayload()
            // `b64` answers an ordinary file pick and `sb64` is the
            // metadata-stripped re-encode a camera-style capture must receive.
            // Supplying both is what genuinely exercises the capture branch.
            payloadJSON = "{\"fixture-photo\":{\"b64\":\"\(jpeg)\",\"sb64\":\"\(jpeg)\",\"mime\":\"image/jpeg\"}}"
            stepJSON = SequenceScriptBuilder.stepObjectJS(SequenceStepScript(
                id: "fixture-photo",
                kindJS: SequenceStepKind.photo.jsValue,
                blockJS: SequenceBlockMode.once.jsValue,
                liveJS: LiveCameraMode.serveLive.jsValue,
                surfaceJS: RequestSurface.either.jsValue,
                img: "data:image/jpeg;base64,\(jpeg)",
                vid: nil,
                empty: false
            ))
        }

        // A fresh sequence version makes the engine run its own pointer reset, so
        // each combination starts from a clean live and native cursor.
        fixtureSequenceVersion += 1
        let stateFields = SequenceScriptBuilder.stateFieldsJS(
            mode: "advance",
            end: "hold",
            method: method.jsValue,
            active: true
        )
        let pointerReset = SequenceScriptBuilder.pointerResetJS(seqVersion: fixtureSequenceVersion)
        let js = """
        (function(){
            var s = window[Symbol.for('fsl')];
            if(!s) return;
            s.seq = [\(stepJSON)];
            s.payloads = \(payloadJSON);
            s._payloadV = \(fixtureSequenceVersion);
            \(stateFields)
            \(pointerReset)
            s._pkBusy = false;
            s._pkLast = 0;
            s._askPick = null;
            try{navigator.mediaDevices.dispatchEvent(new Event('devicechange'));}catch(e){}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
}

/// Lightweight navigation delegate used while loading the Loom media-test page.
/// Resolves once the page finishes or fails so the capture step can proceed.
final class LoomNavDelegate: NSObject, WKNavigationDelegate {
    private let onPageLoaded: () -> Void
    private let onPageFailed: () -> Void

    init(onPageLoaded: @escaping () -> Void, onPageFailed: @escaping () -> Void) {
        self.onPageLoaded = onPageLoaded
        self.onPageFailed = onPageFailed
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onPageFailed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onPageFailed()
    }
}
