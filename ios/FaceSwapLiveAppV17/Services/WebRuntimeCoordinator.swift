import WebKit

/// `@unchecked Sendable` wrapper for `Any?` results from `evaluateJavaScript`,
/// which are not `Sendable` by default but are safe to transfer once obtained.
nonisolated private struct SendableJSResult: @unchecked Sendable {
    let value: Any?
}

/// Serializes all evaluateJavaScript calls to prevent race conditions
/// from concurrent script evaluations on the same WKWebView.
@MainActor
final class WebRuntimeCoordinator {
    private weak var webView: WKWebView?
    private var pendingEvaluations: [(script: String, completion: (@Sendable @MainActor (Any?, Error?) -> Void)?)] = []
    private var isEvaluating = false
    
    init(webView: WKWebView? = nil) {
        self.webView = webView
    }
    
    func setWebView(_ webView: WKWebView?) {
        self.webView = webView
    }
    
    func evaluate(_ script: String, completion: (@Sendable @MainActor (Any?, Error?) -> Void)? = nil) {
        pendingEvaluations.append((script, completion))
        drainQueue()
    }
    
    func evaluate(_ script: String) async throws -> Any? {
        let boxed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableJSResult, any Error>) in
            evaluate(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: SendableJSResult(value: result)) }
            }
        }
        return boxed.value
    }
    
    private func drainQueue() {
        guard !isEvaluating, let webView, !pendingEvaluations.isEmpty else { return }
        isEvaluating = true
        let next = pendingEvaluations.removeFirst()
        webView.evaluateJavaScript(next.script) { [weak self] result, error in
            next.completion?(result, error)
            self?.isEvaluating = false
            self?.drainQueue()
        }
    }
}
