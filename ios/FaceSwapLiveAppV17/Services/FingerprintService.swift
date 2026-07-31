import Foundation
import WebKit
import UIKit

@Observable
@MainActor
final class FingerprintService {

    // MARK: - Public Properties

    var baseline: FingerprintBaselineSpec?
    var consistencyResults: [FingerprintConsistencyResult] = []
    var isCapturing: Bool = false
    var isTesting: Bool = false
    var testPassed: Bool?

    // MARK: - Private Properties

    private var webView: WKWebView?
    private var navDelegate: NavigationDelegate?

    // MARK: - JavaScript Helpers

    private static let djb2Function = """
        function djb2(s){var h=5381;for(var i=0;i<s.length;i++){h=((h<<5)+h)+s.charCodeAt(i);h=h&h;}return(h>>>0).toString(16);}
        """

    /// Body for `callAsyncJavaScript`. The routine is async (it renders audio),
    /// so it MUST be awaited — `evaluateJavaScript` cannot resolve the returned
    /// Promise and silently yields nothing. `callAsyncJavaScript` wraps this in an
    /// async function, so top-level `await`/`return` are valid here.
    private static let fingerprintBody: String = """
            \(djb2Function)

            // Hardware concurrency
            var hardwareConcurrency = navigator.hardwareConcurrency || 0;

            // Screen dimensions
            var screenWidth = screen.width || 0;
            var screenHeight = screen.height || 0;

            // Screen frame — capture every edge so we can lock them all
            var screenFrameTop = window.screenY || window.screenTop || 0;
            var screenFrameLeft = window.screenLeft || window.screenX || 0;
            var screenFrameBottom = (typeof screen.availTop === 'number' && typeof screen.availHeight === 'number')
                ? (screen.availTop + screen.availHeight)
                : 0;
            var screenFrameRight = (typeof screen.availLeft === 'number' && typeof screen.availWidth === 'number')
                ? (screen.availLeft + screen.availWidth)
                : 0;
            var availTop = typeof screen.availTop === 'number' ? screen.availTop : 0;
            var availLeft = typeof screen.availLeft === 'number' ? screen.availLeft : 0;

            // Audio fingerprint
            var audioFingerprint = 0;
            try {
                var actx = new OfflineAudioContext(1, 44100, 44100);
                var osc = actx.createOscillator();
                osc.type = 'triangle';
                osc.frequency.setValueAtTime(10000, actx.currentTime);
                var comp = actx.createDynamicsCompressor();
                comp.threshold.setValueAtTime(-50, actx.currentTime);
                comp.knee.setValueAtTime(40, actx.currentTime);
                comp.ratio.setValueAtTime(12, actx.currentTime);
                comp.attack.setValueAtTime(0, actx.currentTime);
                comp.release.setValueAtTime(0.25, actx.currentTime);
                osc.connect(comp);
                comp.connect(actx.destination);
                osc.start(0);
                var buf = await actx.startRendering();
                var d = buf.getChannelData(0);
                var sum = 0;
                for(var i=4500;i<5000;i++) sum += Math.abs(d[i]);
                audioFingerprint = sum;
            } catch(e) {}

            // Canvas fingerprint
            var canvasHash = '';
            try {
                var canvas = document.createElement('canvas');
                canvas.width = 240;
                canvas.height = 60;
                var ctx = canvas.getContext('2d');
                ctx.fillStyle = '#f60';
                ctx.fillRect(0, 0, 240, 60);
                ctx.fillStyle = '#069';
                ctx.font = '14px Arial';
                ctx.fillText('FingerprintJS', 2, 15);
                ctx.fillStyle = 'rgba(102,204,0,0.7)';
                ctx.font = '18px Times New Roman';
                ctx.fillText('FingerprintJS', 4, 45);
                canvasHash = djb2(canvas.toDataURL());
            } catch(e) {}

            // WebGL fingerprint
            var webglHash = '';
            try {
                var glCanvas = document.createElement('canvas');
                var gl = glCanvas.getContext('webgl');
                if (gl) {
                    var debugExt = gl.getExtension('WEBGL_debug_renderer_info');
                    var renderer = debugExt ? gl.getParameter(debugExt.UNMASKED_RENDERER_WEBGL) : '';
                    var vendor = debugExt ? gl.getParameter(debugExt.UNMASKED_VENDOR_WEBGL) : '';
                    var version = gl.getParameter(gl.VERSION) || '';
                    var extensions = gl.getSupportedExtensions() || [];
                    extensions = extensions.slice().sort();
                    var webglStr = renderer + '~' + vendor + '~' + version + '~' + extensions.join(',');
                    webglHash = djb2(webglStr);
                }
            } catch(e) {}

            return JSON.stringify({
                hardwareConcurrency: hardwareConcurrency,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                screenFrameTop: screenFrameTop,
                screenFrameBottom: screenFrameBottom,
                screenFrameLeft: screenFrameLeft,
                screenFrameRight: screenFrameRight,
                availTop: availTop,
                availLeft: availLeft,
                audioFingerprint: audioFingerprint,
                canvasHash: canvasHash,
                webglHash: webglHash
            });
        """

    // MARK: - Navigation Delegate Helper

    /// Reports navigation completion exactly once. A checked continuation that is
    /// resumed twice traps the process, and one that is never resumed strands the
    /// caller forever — which would also skip tearing down a web view that is
    /// parented to the key window.
    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var hasCompleted = false

        func setContinuation(_ continuation: CheckedContinuation<Void, Never>) {
            if hasCompleted {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }

        /// Safe to call repeatedly and from any path, including a caller watchdog.
        func complete() {
            hasCompleted = true
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            complete()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            complete()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            complete()
        }
    }

    // MARK: - Capture Baseline

    func captureBaseline() async -> FingerprintBaselineSpec? {
        isCapturing = true
        defer { isCapturing = false }

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        webView = wv
        // Attach to the key window (effectively invisible) so the content process
        // is never throttled and canvas/WebGL actually render to a real surface.
        attachOffscreen(wv)

        let delegate = NavigationDelegate()
        navDelegate = delegate
        wv.navigationDelegate = delegate

        // This web view is parented to the key window, so EVERY exit path must
        // detach it. A stranded one keeps a live WebContent process alive for the
        // rest of the session, and repeated captures stack them up until the
        // system kills the app.
        defer {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.removeFromSuperview()
            webView = nil
            navDelegate = nil
        }

        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)

        // WebKit does not guarantee a navigation callback, so the wait is bounded.
        let navigationWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            delegate.complete()
        }
        await withCheckedContinuation { continuation in
            delegate.setContinuation(continuation)
        }
        navigationWatchdog.cancel()

        // Use callAsyncJavaScript so the async fingerprint Promise is awaited and
        // the resolved JSON string is returned. evaluateJavaScript returns an
        // unsupported-type error for a Promise, which is the silent-failure bug.
        let evaluation = try? await wv.callAsyncJavaScript(
            Self.fingerprintBody,
            arguments: [:],
            contentWorld: .page
        )

        guard let jsonString = evaluation as? String,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }

        struct RawFingerprint: Decodable {
            let hardwareConcurrency: Int
            let screenWidth: Int
            let screenHeight: Int
            let screenFrameTop: Int
            let screenFrameBottom: Int
            let screenFrameLeft: Int
            let screenFrameRight: Int
            let availTop: Int
            let availLeft: Int
            let audioFingerprint: Double
            let canvasHash: String
            let webglHash: String
        }

        guard let raw = try? JSONDecoder().decode(RawFingerprint.self, from: data) else {
            return nil
        }

        let spec = FingerprintBaselineSpec(
            audioFingerprint: raw.audioFingerprint,
            canvasHash: raw.canvasHash,
            webglHash: raw.webglHash,
            screenWidth: raw.screenWidth,
            screenHeight: raw.screenHeight,
            screenFrameTop: raw.screenFrameTop,
            screenFrameBottom: raw.screenFrameBottom,
            screenFrameLeft: raw.screenFrameLeft,
            screenFrameRight: raw.screenFrameRight,
            hardwareConcurrency: raw.hardwareConcurrency,
            capturedAt: Date()
        )

        baseline = spec
        return spec
    }

    /// Adds the probe web view to the foreground window at near-zero opacity so
    /// rendering APIs work without being visible to the user.
    private func attachOffscreen(_ webView: WKWebView) {
        webView.alpha = 0.012
        webView.isUserInteractionEnabled = false
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        window?.addSubview(webView)
    }

    // MARK: - Suspect Score Evaluation

    /// Evaluates heuristics fingerprint.com would use and returns a score
    /// (0 = clean Safari profile, higher = more suspect signals).
    func evaluateSuspectScore(baseline spec: FingerprintBaselineSpec) -> Int {
        var score = 0

        // Screen frame: [0,0,0,0] is a dead giveaway for WKWebView
        if spec.screenFrameTop == 0 && spec.screenFrameLeft == 0 &&
           spec.screenFrameBottom == 0 && spec.screenFrameRight == 0 {
            score += 35
        }

        // Audio fingerprint should be non-zero and consistent
        if spec.audioFingerprint == nil || spec.audioFingerprint == 0 {
            score += 15
        }

        // Canvas hash must be present
        if spec.canvasHash == nil || spec.canvasHash?.isEmpty == true {
            score += 10
        }

        // WebGL hash must be present
        if spec.webglHash == nil || spec.webglHash?.isEmpty == true {
            score += 10
        }

        // Hardware concurrency should be > 0
        if spec.hardwareConcurrency <= 0 {
            score += 10
        }

        return score
    }

    var suspectScoreText: String {
        guard let spec = baseline else { return "No baseline captured" }
        let score = evaluateSuspectScore(baseline: spec)
        switch score {
        case 0: return "0 — Clean Safari Profile"
        case 1...10: return "\(score) — Minor Signal"
        case 11...25: return "\(score) — Moderate Suspect"
        default: return "\(score) — High Suspect"
        }
    }

    var suspectScoreBadge: (label: String, color: String) {
        guard let spec = baseline else { return ("No Data", "gray") }
        let score = evaluateSuspectScore(baseline: spec)
        switch score {
        case 0: return ("Clean", "green")
        case 1...10: return ("Low", "yellow")
        case 11...25: return ("Moderate", "orange")
        default: return ("High", "red")
        }
    }

    // MARK: - Consistency Test

    func runConsistencyTest(iterations: Int = 5) async {
        isTesting = true
        consistencyResults = []

        var captures: [FingerprintBaselineSpec] = []
        for _ in 0..<iterations {
            if let result = await captureBaseline() {
                captures.append(result)
            }
        }

        guard captures.count == iterations else {
            consistencyResults = []
            testPassed = false
            isTesting = false
            return
        }

        let fields: [(String, (FingerprintBaselineSpec) -> String)] = [
            ("hardwareConcurrency", { String($0.hardwareConcurrency) }),
            ("screenWidth", { String($0.screenWidth) }),
            ("screenHeight", { String($0.screenHeight) }),
            ("audioFingerprint", { String($0.audioFingerprint ?? 0) }),
            ("canvasHash", { $0.canvasHash ?? "" }),
            ("webglHash", { $0.webglHash ?? "" })
        ]

        var results: [FingerprintConsistencyResult] = []
        for (name, extractor) in fields {
            let values = captures.map { extractor($0) }
            let allSame = Set(values).count <= 1
            results.append(FingerprintConsistencyResult(
                field: name,
                values: values,
                isConsistent: allSame
            ))
        }

        consistencyResults = results
        testPassed = results.allSatisfy { $0.isConsistent }
        isTesting = false
    }
}
