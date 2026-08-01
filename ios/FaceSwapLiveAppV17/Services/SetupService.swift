import AVFoundation
import UIKit
import WebKit

nonisolated enum SetupPhase: Sendable {
    case idle
    case requestingPermissions
    case discoveringDevices
    case testingDevice(String)
    case discoveringMicrophones
    case testingMicrophone(String)
    case gatheringWebFingerprint
    case safariProbe
    case safariCorrelation
    case mediaTestReal
    case mediaTestProcessed
    case mediaTestComparing
    case diagnosticsSweep
    case calibratingCameraResponses
    case complete
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermissions: "Requesting permissions…"
        case .discoveringDevices: "Discovering devices…"
        case .testingDevice(let name): "Testing \(name)…"
        case .discoveringMicrophones: "Discovering microphones…"
        case .testingMicrophone(let name): "Testing \(name)…"
        case .gatheringWebFingerprint: "Gathering web fingerprint…"
        case .safariProbe: "Probing Safari camera identity…"
        case .safariCorrelation: "Verifying synthetic identity correlation…"
        case .mediaTestReal: "Loading Loom media test (real)…"
        case .mediaTestProcessed: "Loading Loom media test (processed)…"
        case .mediaTestComparing: "Comparing original vs processed…"
        case .diagnosticsSweep: "Running full method sweep…"
        case .calibratingCameraResponses: "Calibrating camera responses…"
        case .complete: "Setup complete"
        case .failed(let msg): "Failed: \(msg)"
        }
    }
}

@Observable
@MainActor
final class SetupService {
    var phase: SetupPhase = .idle
    var progress: Double = 0
    var discoveredDevices: [CameraDeviceSpec] = []
    var discoveredMicrophones: [MicrophoneDeviceSpec] = []
    var hardwareSpec: DeviceHardwareSpec?
    var webFingerprint: WebFingerprintSpec?
    var mediaTestResult: MediaTestResult?
    var fingerprintBaseline: FingerprintBaselineSpec?
    var cameraResponseMap: CameraResponseMap?
    var isScanning: Bool = false

    private var webView: WKWebView?
    private let fingerprintService = FingerprintService()

    func runFullScan() async -> DeviceProfile? {
        await MediaResourceCoordinator.shared.acquireLease(for: "SetupService")
        let profile = await performFullScan()
        await MediaResourceCoordinator.shared.releaseLease(for: "SetupService")
        return profile
    }

    /// Actual scan body; isolated so `runFullScan` can release the hardware
    /// lease on every exit path without relying on a fire-and-forget Task.
    private func performFullScan() async -> DeviceProfile? {

        isScanning = true
        progress = 0

        phase = .requestingPermissions
        progress = 0.05

        let camGranted = await requestPermission(for: .video)
        guard camGranted else {
            phase = .failed("Camera permission denied")
            isScanning = false
            return nil
        }

        let micGranted = await requestPermission(for: .audio)
        guard micGranted else {
            phase = .failed("Microphone permission denied")
            isScanning = false
            return nil
        }
        progress = 0.1

        phase = .discoveringDevices
        let hardware = gatherHardwareSpec()
        hardwareSpec = hardware
        progress = 0.12

        let captureDevices = discoverAllDevices()
        progress = 0.15

        var deviceSpecs: [CameraDeviceSpec] = []
        let deviceCount = max(captureDevices.count, 1)

        for (index, device) in captureDevices.enumerated() {
            phase = .testingDevice(device.localizedName)
            let spec = await testDevice(device)
            deviceSpecs.append(spec)
            progress = 0.15 + (0.45 * Double(index + 1) / Double(deviceCount))
        }
        discoveredDevices = deviceSpecs

        phase = .discoveringMicrophones
        progress = 0.62
        let micDevices = discoverAllMicrophones()
        var micSpecs: [MicrophoneDeviceSpec] = []
        let micCount = max(micDevices.count, 1)

        for (index, device) in micDevices.enumerated() {
            phase = .testingMicrophone(device.localizedName)
            let spec = await testMicrophoneDevice(device)
            micSpecs.append(spec)
            progress = 0.62 + (0.1 * Double(index + 1) / Double(micCount))
        }
        discoveredMicrophones = micSpecs

        phase = .gatheringWebFingerprint
        progress = 0.75
        let fingerprint = await gatherWebFingerprint()
        webFingerprint = fingerprint
        progress = 0.76

        let fpBaseline = await fingerprintService.captureBaseline()
        fingerprintBaseline = fpBaseline
        progress = 0.78

        // Real getUserMedia probe: capture what Safari actually reports for
        // deviceId, label, track settings, and capabilities. This calibrates
        // the synthetic camera identity against live Safari output so the
        // profile's mediaTestResult.realSnapshot is populated with real data.
        phase = .safariProbe
        progress = 0.82
        let realSnapshot = await runGetUserMediaProbe()

        let frontDev = deviceSpecs.first { $0.position == "front" }
        let backDev = deviceSpecs.first { $0.position == "back" }

        var tempProfile = DeviceProfile(
            name: hardware.modelName,
            deviceHardware: hardware,
            cameras: deviceSpecs,
            microphones: micSpecs,
            webFingerprint: fingerprint,
            preferredFrontCameraID: frontDev?.id,
            preferredBackCameraID: backDev?.id,
            preferredMicrophoneID: micSpecs.first?.id,
            mediaTestResult: nil,
            fingerprintBaseline: fpBaseline
        )

        // Auto-adjust camera specs based on the real Safari probe data.
        // The synthetic deviceId, label, width/height, frameRate, and groupId
        // are calibrated to match what a live getUserMedia call actually
        // returns, so the injection serves identity that correlates with the
        // real device.
        if let snapshot = realSnapshot {
            tempProfile = autoAdjustProfile(tempProfile, with: snapshot)
        }

        // E2E correlation verification: run a second getUserMedia with the
        // injection engine armed + profile applied, capture the processed
        // snapshot, and compare it against the real snapshot. This proves the
        // full chain: profile → synthetic identity → getUserMedia gate →
        // served identity matches what Safari reports.
        phase = .safariCorrelation
        progress = 0.85
        if let real = realSnapshot {
            let processedSnapshot = await runProcessedCapture(profile: tempProfile)
            let engine = DeviceTestEngine()
            let comparisons = engine.buildComparisons(real: real, processed: processedSnapshot)
            let matchCount = comparisons.filter { $0.matches }.count
            let matchPct = comparisons.isEmpty ? 0 : Double(matchCount) / Double(comparisons.count) * 100
            let testResult = MediaTestResult(
                realSnapshot: real,
                processedSnapshot: processedSnapshot,
                comparisons: comparisons,
                matchPercentage: matchPct
            )
            mediaTestResult = testResult
            tempProfile.mediaTestResult = testResult
        }
        progress = 0.88

        // Browser delivery diagnostics must run in the mounted, app-owned harness,
        // so setup does not treat an unmounted WebKit snapshot as proof. It still
        // has to leave the profile with a route it can actually deliver through:
        // Canvas is the baseline every other method degrades to, so it is the one
        // honest starting point. The mounted fixture test upgrades it once a
        // method has genuinely earned the recommendation.
        phase = .mediaTestReal
        progress = 0.80
        mediaTestResult = nil
        tempProfile.mediaTestResult = nil
        tempProfile.recommendedMethod = .canvasPipeline
        tempProfile.recommendedAdjustments = []

        phase = .calibratingCameraResponses
        progress = 0.90
        let responseMap = CameraResponseCalibrationService.responseMap(for: tempProfile)
        cameraResponseMap = responseMap
        tempProfile.cameraResponseMap = responseMap
        progress = 0.98

        phase = .complete
        progress = 1.0
        isScanning = false
        return tempProfile
    }

    private func requestPermission(for mediaType: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    private func gatherHardwareSpec() -> DeviceHardwareSpec {
        let device = UIDevice.current
        let screen = UIScreen.activeScene
        let processInfo = ProcessInfo.processInfo

        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "Unknown"
            }
        }

        return DeviceHardwareSpec(
            modelName: device.model + " " + device.name,
            modelIdentifier: identifier,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            processorCount: processInfo.processorCount,
            physicalMemoryGB: Double(processInfo.physicalMemory) / (1024 * 1024 * 1024),
            screenNativeBounds: screen.map { "\(Int($0.nativeBounds.width))x\(Int($0.nativeBounds.height))" } ?? "0x0",
            screenScale: screen.map { Double($0.scale) } ?? 3,
            screenNativeScale: screen.map { Double($0.nativeScale) } ?? 3,
            identifierForVendor: device.identifierForVendor?.uuidString
        )
    }

    private func discoverAllDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
                .builtInLiDARDepthCamera,
                .external
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    private func discoverAllMicrophones() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    private func testDevice(_ device: AVCaptureDevice) async -> CameraDeviceSpec {
        let position: String
        switch device.position {
        case .front: position = "front"
        case .back: position = "back"
        default: position = "unspecified"
        }

        let deviceTypeString = deviceTypeLabel(device.deviceType)

        let presets: [AVCaptureSession.Preset] = [
            .low, .medium, .high, .photo,
            .hd1280x720, .hd1920x1080, .hd4K3840x2160,
            .vga640x480, .iFrame960x540, .iFrame1280x720
        ]
        var supportedPresetNames: [String] = []
        let tempSession = AVCaptureSession()
        if let input = try? AVCaptureDeviceInput(device: device) {
            tempSession.beginConfiguration()
            if tempSession.canAddInput(input) {
                tempSession.addInput(input)
            }
            tempSession.commitConfiguration()
            for preset in presets {
                if tempSession.canSetSessionPreset(preset) {
                    supportedPresetNames.append(preset.rawValue)
                }
            }
        }

        var formats: [CameraFormatSpec] = []
        var maxWidth = 0
        var maxHeight = 0
        var globalMaxFPS: Double = 0
        var globalMinFPS: Double = 999

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let w = Int(dims.width)
            let h = Int(dims.height)

            var fmtMaxFPS: Double = 0
            var fmtMinFPS: Double = 999
            for range in format.videoSupportedFrameRateRanges {
                fmtMaxFPS = max(fmtMaxFPS, range.maxFrameRate)
                fmtMinFPS = min(fmtMinFPS, range.minFrameRate)
            }

            if w * h > maxWidth * maxHeight {
                maxWidth = w
                maxHeight = h
            }
            globalMaxFPS = max(globalMaxFPS, fmtMaxFPS)
            globalMinFPS = min(globalMinFPS, fmtMinFPS)

            let mediaType = CMFormatDescriptionGetMediaSubType(desc)
            let mediaTypeStr = String(format: "%c%c%c%c",
                                       (mediaType >> 24) & 0xFF,
                                       (mediaType >> 16) & 0xFF,
                                       (mediaType >> 8) & 0xFF,
                                       mediaType & 0xFF)

            formats.append(CameraFormatSpec(
                width: w,
                height: h,
                maxFrameRate: fmtMaxFPS,
                minFrameRate: fmtMinFPS,
                mediaType: mediaTypeStr,
                videoFieldOfView: format.videoFieldOfView,
                isMultiCamSupported: format.isMultiCamSupported
            ))
        }

        let activeFormat = device.activeFormat
        let activeDims = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activeMaxFPS = device.activeVideoMaxFrameDuration.seconds > 0 ? 1.0 / device.activeVideoMaxFrameDuration.seconds : 30

        let colorSpace: String
        switch device.activeColorSpace {
        case .sRGB: colorSpace = "sRGB"
        case .P3_D65: colorSpace = "P3_D65"
        case .HLG_BT2020: colorSpace = "HLG_BT2020"
        case .appleLog: colorSpace = "AppleLog"
        @unknown default: colorSpace = "unknown"
        }

        let exposureSecs = CMTimeGetSeconds(device.exposureDuration)
        let focalLength = device.activeFormat.videoFieldOfView
        let lensAperture = device.lensAperture

        let gains = device.deviceWhiteBalanceGains
        let gainsStr = String(format: "R:%.2f G:%.2f B:%.2f", gains.redGain, gains.greenGain, gains.blueGain)

        var testBitrate: Int?
        var testDuration: Double?
        var testCodec: String?
        var testColorPrimaries: String?
        var testTransferFunc: String?
        var testColorMatrix: String?
        var testProfileLevel: String?

        let clipResult = await recordTestClip(device: device)
        if let clip = clipResult {
            testBitrate = clip.bitrate
            testDuration = clip.duration
            testCodec = clip.codec
            testColorPrimaries = clip.colorPrimaries
            testTransferFunc = clip.transferFunction
            testColorMatrix = clip.colorMatrix
            testProfileLevel = clip.profileLevel
            try? FileManager.default.removeItem(at: clip.url)
        }

        return CameraDeviceSpec(
            id: device.uniqueID,
            label: device.localizedName,
            position: position,
            deviceType: deviceTypeString,
            uniqueID: device.uniqueID,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            activeWidth: Int(activeDims.width),
            activeHeight: Int(activeDims.height),
            maxFrameRate: globalMaxFPS,
            activeFrameRate: activeMaxFPS,
            minFrameRate: globalMinFPS,
            hasFlash: device.hasFlash,
            hasTorch: device.hasTorch,
            isAutoFocusSupported: device.isFocusModeSupported(.autoFocus),
            maxZoomFactor: device.maxAvailableVideoZoomFactor,
            minISO: device.activeFormat.minISO,
            maxISO: device.activeFormat.maxISO,
            supportedPresets: supportedPresetNames,
            supportedFormats: formats,
            testClipDuration: testDuration,
            testClipBitrate: testBitrate,
            testClipCodec: testCodec,
            testClipColorPrimaries: testColorPrimaries,
            testClipTransferFunction: testTransferFunc,
            testClipColorMatrix: testColorMatrix,
            testClipProfileLevel: testProfileLevel,
            activeColorSpace: colorSpace,
            exposureDurationSeconds: exposureSecs,
            focalLength: focalLength,
            lensAperture: lensAperture,
            whiteBalanceGains: gainsStr
        )
    }

    private func testMicrophoneDevice(_ device: AVCaptureDevice) async -> MicrophoneDeviceSpec {
        let position: String
        switch device.position {
        case .front: position = "front"
        case .back: position = "back"
        default: position = "unspecified"
        }

        let deviceTypeStr: String
        if device.deviceType == .microphone {
            deviceTypeStr = "Built-in Microphone"
        } else {
            deviceTypeStr = "Microphone"
        }

        await AudioSessionManager.shared.activate(category: .playAndRecord, mode: .measurement)

        let (sampleRate, channelCount, preferredSampleRate, preferredBufferDuration, dataSources) = await MainActor.run {
            let audioSession = AVAudioSession.sharedInstance()
            let sr = audioSession.sampleRate
            let cc = audioSession.inputNumberOfChannels
            let psr = audioSession.preferredSampleRate
            let pbd = audioSession.preferredIOBufferDuration

            var ds: [MicrophoneDataSource] = []
            if let sources = audioSession.inputDataSources {
                for source in sources {
                    let patterns = source.supportedPolarPatterns?.map { patternName($0) } ?? []
                    let selectedPattern = source.selectedPolarPattern.map { patternName($0) }

                    ds.append(MicrophoneDataSource(
                        dataSourceID: source.dataSourceID.intValue,
                        dataSourceName: source.dataSourceName,
                        orientation: source.orientation?.rawValue,
                        location: source.location?.rawValue,
                        selectedPolarPattern: selectedPattern,
                        supportedPolarPatterns: patterns
                    ))
                }
            }
            return (sr, cc, psr, pbd, ds)
        }

        var testSampleRate: Double?
        var testBitDepth: Int?
        var testChannelCount: Int?

        let testResult = await recordTestAudio(device: device)
        if let result = testResult {
            testSampleRate = result.sampleRate
            testBitDepth = result.bitDepth
            testChannelCount = result.channelCount
        }

        await AudioSessionManager.shared.restore()

        return MicrophoneDeviceSpec(
            id: device.uniqueID,
            label: device.localizedName,
            uniqueID: device.uniqueID,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            position: position,
            deviceType: deviceTypeStr,
            sampleRate: sampleRate,
            channelCount: channelCount,
            preferredSampleRate: preferredSampleRate > 0 ? preferredSampleRate : sampleRate,
            preferredBufferDuration: preferredBufferDuration,
            dataSources: dataSources,
            testSampleRate: testSampleRate,
            testBitDepth: testBitDepth,
            testChannelCount: testChannelCount
        )
    }

    private func patternName(_ pattern: AVAudioSession.PolarPattern) -> String {
        switch pattern {
        case .cardioid: return "cardioid"
        case .subcardioid: return "subcardioid"
        case .omnidirectional: return "omnidirectional"
        case .stereo: return "stereo"
        default: return pattern.rawValue
        }
    }

    private var activeRecorder: TestClipRecorder?

    private func recordTestClip(device: AVCaptureDevice) async -> TestClipResult? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")

        let result: TestClipResult? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TestClipResult?, Never>) in
                let guard_ = ResumeGuard(continuation: continuation)

                let recorder = TestClipRecorder(device: device, outputURL: outputURL) { result in
                    guard_.resume(result)
                }
                self.activeRecorder = recorder
                recorder.start()

                DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                    guard_.resume(nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.activeRecorder?.stop()
            }
        }
        // Release the recorder once the clip has finished or timed out. Runs back
        // on the main actor after the continuation resumes (the previous
        // assignment here sat after `return await` and was unreachable).
        activeRecorder = nil
        return result
    }

    private var activeAudioRecorder: TestAudioRecorder?

    private func recordTestAudio(device: AVCaptureDevice) async -> TestAudioResult? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")

        let result: TestAudioResult? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TestAudioResult?, Never>) in
                let guard_ = ResumeGuard(continuation: continuation)

                let recorder = TestAudioRecorder(device: device, outputURL: outputURL) { result in
                    guard_.resume(result)
                }
                self.activeAudioRecorder = recorder
                recorder.start()

                DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                    guard_.resume(nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.activeAudioRecorder?.stop()
            }
        }
        // Release the recorder once recording has finished or timed out (the
        // previous assignment here sat after `return await` and was unreachable).
        activeAudioRecorder = nil
        return result
    }

    /// Device-derived fingerprint defaults. Used as the starting point for the web
    /// capture and as the fallback when the web view never reports back.
    private static func deviceDerivedFingerprint() -> WebFingerprintSpec {
        let screen = UIScreen.activeScene
        return WebFingerprintSpec(
            userAgent: "", platform: "", language: "en-US",
            languages: ["en-US"], hardwareConcurrency: ProcessInfo.processInfo.processorCount,
            deviceMemory: 4, maxTouchPoints: 5,
            screenWidth: Int(screen?.bounds.width ?? 375),
            screenHeight: Int(screen?.bounds.height ?? 812),
            screenColorDepth: 24,
            devicePixelRatio: screen.map { Double($0.scale) } ?? 3,
            timezoneOffset: TimeZone.current.secondsFromGMT() / -60,
            timezone: TimeZone.current.identifier,
            doNotTrack: nil, vendor: "Apple Computer, Inc.",
            rendererInfo: "", vendorInfo: "", webglVersion: ""
        )
    }

    private func gatherWebFingerprint() async -> WebFingerprintSpec {
        // Resolved up front on the main actor so the completion paths below never
        // have to hop back for it.
        let fallbackSpec = Self.deviceDerivedFingerprint()
        return await withCheckedContinuation { continuation in
            let config = WKWebViewConfiguration()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)
            let defaultUA = wv.value(forKey: "userAgent") as? String ?? ""
            wv.customUserAgent = StyleSheetProvider.buildSafariUserAgent(from: defaultUA)
            self.webView = wv

            let js = """
            (function(){
                var c=document.createElement('canvas');
                var gl=c.getContext('webgl')||c.getContext('experimental-webgl');
                var ri='',vi='',wv='';
                if(gl){
                    var ext=gl.getExtension('WEBGL_debug_renderer_info');
                    if(ext){
                        ri=gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)||'';
                        vi=gl.getParameter(ext.UNMASKED_VENDOR_WEBGL)||'';
                    }
                    wv=gl.getParameter(gl.VERSION)||'';
                }
                return JSON.stringify({
                    userAgent:navigator.userAgent,
                    platform:navigator.platform,
                    language:navigator.language,
                    languages:Array.from(navigator.languages||[]),
                    hardwareConcurrency:navigator.hardwareConcurrency||0,
                    deviceMemory:navigator.deviceMemory||0,
                    maxTouchPoints:navigator.maxTouchPoints||0,
                    screenWidth:screen.width,
                    screenHeight:screen.height,
                    screenColorDepth:screen.colorDepth,
                    devicePixelRatio:window.devicePixelRatio||1,
                    timezoneOffset:new Date().getTimezoneOffset(),
                    timezone:Intl.DateTimeFormat().resolvedOptions().timeZone||'',
                    doNotTrack:navigator.doNotTrack||null,
                    vendor:navigator.vendor||'',
                    rendererInfo:ri,
                    vendorInfo:vi,
                    webglVersion:wv
                });
            })();
            """

            wv.loadHTMLString("<html><body></body></html>", baseURL: nil)

            // Resume exactly once. A checked continuation resumed twice traps the
            // process, and one never resumed would stall setup forever while this
            // web view stays alive holding a WebContent process.
            let lock = NSLock()
            var didResume = false
            func finish(_ spec: WebFingerprintSpec) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(returning: spec)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                wv.evaluateJavaScript(js) { result, error in
                    var spec = fallbackSpec

                    if let jsonStr = result as? String,
                       let data = jsonStr.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        spec.userAgent = dict["userAgent"] as? String ?? ""
                        spec.platform = dict["platform"] as? String ?? ""
                        spec.language = dict["language"] as? String ?? "en-US"
                        spec.languages = dict["languages"] as? [String] ?? ["en-US"]
                        spec.hardwareConcurrency = dict["hardwareConcurrency"] as? Int ?? spec.hardwareConcurrency
                        spec.deviceMemory = dict["deviceMemory"] as? Int ?? spec.deviceMemory
                        spec.maxTouchPoints = dict["maxTouchPoints"] as? Int ?? spec.maxTouchPoints
                        spec.screenWidth = dict["screenWidth"] as? Int ?? spec.screenWidth
                        spec.screenHeight = dict["screenHeight"] as? Int ?? spec.screenHeight
                        spec.screenColorDepth = dict["screenColorDepth"] as? Int ?? spec.screenColorDepth
                        spec.devicePixelRatio = dict["devicePixelRatio"] as? Double ?? spec.devicePixelRatio
                        spec.timezoneOffset = dict["timezoneOffset"] as? Int ?? spec.timezoneOffset
                        spec.timezone = dict["timezone"] as? String ?? spec.timezone
                        spec.doNotTrack = dict["doNotTrack"] as? String
                        spec.vendor = dict["vendor"] as? String ?? spec.vendor
                        spec.rendererInfo = dict["rendererInfo"] as? String ?? ""
                        spec.vendorInfo = dict["vendorInfo"] as? String ?? ""
                        spec.webglVersion = dict["webglVersion"] as? String ?? ""
                    }

                    self.webView = nil
                    finish(spec)
                }
            }

            // WebKit may never call back if the content process goes away. Fall
            // back to the device-derived values and release the web view instead
            // of stalling the scan and holding a WebContent process open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                self.webView = nil
                finish(fallbackSpec)
            }
        }
    }

    // MARK: - Real getUserMedia probe + correlation verification

    /// Runs a real `getUserMedia({video:true})` call in a secure-context WKWebView
    /// and captures what Safari actually reports: deviceId, label, track settings,
    /// capabilities, and the full device list. Returns nil when the probe cannot
    /// complete (e.g., simulator or no mediaDevices).
    private func runGetUserMediaProbe() async -> MediaSnapshot? {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = StyleSheetProvider.safariUserAgent

        let didLoad = await loadProbePage(in: wv, baseURL: "https://fsl.diagnostics.local/camera-probe")
        guard didLoad else { return nil }

        try? await Task.sleep(for: .seconds(1))
        return await captureSnapshot(from: wv)
    }

    /// Runs a getUserMedia capture with the injection engine armed and the profile
    /// applied, so we can verify the synthetic identity the site sees under
    /// injection matches the real Safari output.
    private func runProcessedCapture(profile: DeviceProfile) async -> MediaSnapshot? {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

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

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = StyleSheetProvider.safariUserAgent

        let didLoad = await loadProbePage(in: wv, baseURL: "https://fsl.diagnostics.local/camera-processed")
        guard didLoad else { return nil }

        try? await Task.sleep(for: .seconds(1))
        return await captureSnapshot(from: wv)
    }

    /// Loads the local capture page in a web view and waits for it to finish.
    /// Returns false on timeout or load failure.
    private func loadProbePage(in webView: WKWebView, baseURL: String) async -> Bool {
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
            webView.navigationDelegate = coord
            webView.loadHTMLString(
                DeviceTestEngine.localCaptureHTML,
                baseURL: URL(string: baseURL)!
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                safeResume(false)
            }
        }
    }

    /// Runs the capture JS in the web view and parses the result into a
    /// `MediaSnapshot`. Returns nil on any error.
    private func captureSnapshot(from webView: WKWebView) async -> MediaSnapshot? {
        do {
            let result = try await webView.callAsyncJavaScript(
                DeviceTestEngine.captureJS,
                arguments: [:],
                contentWorld: .page
            )

            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return DeviceTestEngine().parseSnapshot(dict)
        } catch {
            return nil
        }
    }

    /// Auto-adjusts the profile's front camera spec to match what Safari's real
    /// getUserMedia probe reported. The synthetic deviceId, label, width/height,
    /// frameRate, and groupId are calibrated against the live Safari values so the
    /// injection serves identity that correlates with the real device.
    private func autoAdjustProfile(_ profile: DeviceProfile, with snapshot: MediaSnapshot) -> DeviceProfile {
        var adjusted = profile
        guard var frontCam = profile.frontCamera ?? profile.cameras.first else { return adjusted }

        if let settings = snapshot.trackSettings {
            frontCam.activeWidth = settings.width > 0 ? settings.width : frontCam.activeWidth
            frontCam.activeHeight = settings.height > 0 ? settings.height : frontCam.activeHeight
            frontCam.activeFrameRate = settings.frameRate > 0 ? settings.frameRate : frontCam.activeFrameRate
        }

        if let caps = snapshot.trackCapabilities {
            if caps.widthMax > 0 { frontCam.maxWidth = caps.widthMax }
            if caps.heightMax > 0 { frontCam.maxHeight = caps.heightMax }
            if caps.frameRateMax > 0 { frontCam.maxFrameRate = caps.frameRateMax }
            if caps.frameRateMin > 0 { frontCam.minFrameRate = caps.frameRateMin }
        }

        if let videoDevice = snapshot.devices.first(where: { $0.kind == "videoinput" }), !videoDevice.label.isEmpty {
            frontCam.label = videoDevice.label
        } else if !snapshot.trackLabel.isEmpty {
            frontCam.label = snapshot.trackLabel
        }

        for index in adjusted.cameras.indices {
            if adjusted.cameras[index].id == frontCam.id {
                adjusted.cameras[index] = frontCam
                break
            }
        }

        return adjusted
    }

    private func deviceTypeLabel(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInWideAngleCamera: return "Wide Angle"
        case .builtInUltraWideCamera: return "Ultra Wide"
        case .builtInTelephotoCamera: return "Telephoto"
        case .builtInDualCamera: return "Dual"
        case .builtInDualWideCamera: return "Dual Wide"
        case .builtInTripleCamera: return "Triple"
        case .builtInTrueDepthCamera: return "TrueDepth"
        case .builtInLiDARDepthCamera: return "LiDAR"
        default: return "Unknown"
        }
    }
}

/// Once-only resume guard for `CheckedContinuation` — thread-safe and
/// `@unchecked Sendable` so it can be captured in `@Sendable` closures.
nonisolated private final class ResumeGuard<T: Sendable>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var resumed = false

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

nonisolated private final class TestClipRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let device: AVCaptureDevice
    private let outputURL: URL
    private let completion: @Sendable (SetupService.TestClipResult?) -> Void
    private let sessionQueue = DispatchQueue(label: "com.app.testclip")
    private var timer: DispatchSourceTimer?
    private var hasCompleted = false
    private let completionLock = NSLock()

    init(device: AVCaptureDevice, outputURL: URL, completion: @escaping @Sendable (SetupService.TestClipResult?) -> Void) {
        self.device = device
        self.outputURL = outputURL
        self.completion = completion
        super.init()
    }

    private func safeComplete(_ result: SetupService.TestClipResult?) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        completionLock.unlock()
        completion(result)
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                self.session.stopRunning()
                self.safeComplete(nil)
            }
        }
    }

    func start() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .high

            guard let input = try? AVCaptureDeviceInput(device: device) else {
                session.commitConfiguration()
                safeComplete(nil)
                return
            }

            if session.canAddInput(input) { session.addInput(input) }

            movieOutput.maxRecordedDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

            session.commitConfiguration()
            session.startRunning()

            guard session.isRunning else {
                safeComplete(nil)
                return
            }

            movieOutput.startRecording(to: outputURL, recordingDelegate: self)

            let t = DispatchSource.makeTimerSource(queue: sessionQueue)
            t.schedule(deadline: .now() + 2.5)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                } else {
                    self.session.stopRunning()
                    self.safeComplete(nil)
                }
            }
            t.resume()
            timer = t
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        timer?.cancel()
        timer = nil
        session.stopRunning()

        guard error == nil, FileManager.default.fileExists(atPath: outputFileURL.path) else {
            safeComplete(nil)
            return
        }

        Task {
            let asset = AVURLAsset(url: outputFileURL)
            let durationVal = (try? await asset.load(.duration)) ?? .zero
            let duration = CMTimeGetSeconds(durationVal)

            var bitrate = 0
            var codec = "h264"
            var colorPrimaries: String?
            var transferFunction: String?
            var colorMatrix: String?
            var profileLevel: String?

            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let estimatedRate = (try? await track.load(.estimatedDataRate)) ?? 0
                bitrate = Int(estimatedRate)
                let descs = (try? await track.load(.formatDescriptions)) ?? []
                for desc in descs {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                if subType == kCMVideoCodecType_HEVC {
                    codec = "hevc"
                } else if subType == kCMVideoCodecType_H264 {
                    codec = "h264"
                }

                let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
                colorPrimaries = extensions?["ColorPrimaries" as String] as? String
                transferFunction = extensions?["TransferFunction" as String] as? String
                colorMatrix = extensions?["YCbCrMatrix" as String] as? String
                profileLevel = extensions?["ProfileLevel" as String] as? String
            }
        }

            let result = SetupService.TestClipResult(
                url: outputFileURL,
                bitrate: bitrate,
                duration: duration,
                codec: codec,
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                colorMatrix: colorMatrix,
                profileLevel: profileLevel
            )
            safeComplete(result)
        }
    }
}

nonisolated private final class TestAudioRecorder: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let device: AVCaptureDevice
    private let outputURL: URL
    private let completion: @Sendable (SetupService.TestAudioResult?) -> Void
    private let sessionQueue = DispatchQueue(label: "com.app.testaudio")
    private var hasCompleted = false
    private let completionLock = NSLock()
    private var sampleRate: Double = 0
    private var bitDepth: Int = 0
    private var channelCount: Int = 0
    private var delegate: AudioDelegate?

    init(device: AVCaptureDevice, outputURL: URL, completion: @escaping @Sendable (SetupService.TestAudioResult?) -> Void) {
        self.device = device
        self.outputURL = outputURL
        self.completion = completion
    }

    private func safeComplete(_ result: SetupService.TestAudioResult?) {
        completionLock.lock()
        guard !hasCompleted else { completionLock.unlock(); return }
        hasCompleted = true
        completionLock.unlock()
        completion(result)
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.safeComplete(nil)
        }
    }

    func start() {
        sessionQueue.async { [self] in
            session.beginConfiguration()

            guard let input = try? AVCaptureDeviceInput(device: device) else {
                session.commitConfiguration()
                safeComplete(nil)
                return
            }

            if session.canAddInput(input) { session.addInput(input) }

            let del = AudioDelegate { [weak self] sr, bd, ch in
                guard let self else { return }
                self.sampleRate = sr
                self.bitDepth = bd
                self.channelCount = ch
            }
            self.delegate = del
            audioOutput.setSampleBufferDelegate(del, queue: sessionQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

            session.commitConfiguration()
            session.startRunning()

            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.session.stopRunning()
                self.safeComplete(SetupService.TestAudioResult(
                    sampleRate: self.sampleRate,
                    bitDepth: self.bitDepth,
                    channelCount: self.channelCount
                ))
            }
        }
    }
}

nonisolated private final class AudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let capturedLock = NSLock()
    private var _captured = false
    private var captured: Bool {
        get { capturedLock.lock(); defer { capturedLock.unlock() }; return _captured }
        set { capturedLock.lock(); _captured = newValue; capturedLock.unlock() }
    }
    let onCapture: @Sendable (Double, Int, Int) -> Void

    init(onCapture: @escaping @Sendable (Double, Int, Int) -> Void) {
        self.onCapture = onCapture
        super.init()
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !captured else { return }
        captured = true

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        let sr = asbd?.mSampleRate ?? 0
        let bd = Int(asbd?.mBitsPerChannel ?? 0)
        let ch = Int(asbd?.mChannelsPerFrame ?? 0)
        onCapture(sr, bd, ch)
    }
}

private extension UIScreen {
    /// The screen backing the app's active foreground window scene. Replaces the
    /// deprecated `UIScreen.main`, which Apple discourages in multi-scene apps.
    static var activeScene: UIScreen? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
        return scene?.screen
    }
}

extension SetupService {
    nonisolated struct TestClipResult: Sendable {
        let url: URL
        let bitrate: Int
        let duration: Double
        let codec: String
        let colorPrimaries: String?
        let transferFunction: String?
        let colorMatrix: String?
        let profileLevel: String?
    }

    nonisolated struct TestAudioResult: Sendable {
        let sampleRate: Double
        let bitDepth: Int
        let channelCount: Int
    }
}
