import Foundation
import WebKit

/// Persisted on/off switch for the Round 2 sensor-realism layer (capture-clock
/// timing + grain / PRNU on the clean feed). It is the single source of truth
/// shared by the Browser (which bakes it into the profile-apply script) and
/// Diagnostics (which exposes the toggle and records it in the export log).
///
/// On by default and remembered. Flipping it pushes the new value straight into
/// the live page so it takes effect on the next frame with no reload.
@Observable
@MainActor
final class SensorRealismStore {
    static let shared = SensorRealismStore()

    private let key = "fsl.sensorRealism.enabled.v1"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: key)
            pushToActiveWebView()
        }
    }

    private init() {
        // Default ON when nothing has been stored yet.
        if UserDefaults.standard.object(forKey: key) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: key)
        }
    }

    /// Pushes the current value into the live browser page (if any) so a toggle
    /// takes effect on the next frame without a reload. Safe no-op when no page
    /// or engine is present.
    func pushToActiveWebView() {
        guard let webView = InjectionStreamRegistry.shared.activeWebView else { return }
        webView.evaluateJavaScript(
            StyleSheetProvider.sensorRealismApplyScript(enabled: isEnabled),
            completionHandler: nil
        )
    }
}
