import Foundation
import WebKit

/// Persisted on/off switch for the optional SDK / bridge-transport wrapping layer.
/// When enabled, the injection engine explicitly wraps vendor SDK launchers
/// (Onfido, Veriff, iProov, FaceTec, etc.), Cordova/Capacitor camera APIs,
/// and bridge transports (ReactNativeWebView, dsBridge, custom-scheme navigation).
/// Known browser-visible plugin calls are adapted to the queued media pipeline;
/// host-defined bridge commands are observed and their native navigation paths
/// are guarded without inventing an incompatible response schema.
///
/// Off by default — standard browser APIs are already intercepted. This is an
/// optional hardening layer for known plugin calls and diagnostics around
/// SDK-level constraint shaping or custom bridge routing.
@Observable
@MainActor
final class SdkInterceptionStore {
    static let shared = SdkInterceptionStore()

    private let key = "fsl.sdkWrap.enabled.v1"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: key)
            pushToActiveWebView()
        }
    }

    private init() {
        // Default OFF when nothing has been stored yet.
        if UserDefaults.standard.object(forKey: key) == nil {
            isEnabled = false
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: key)
        }
    }

    /// Pushes the current value into the live browser page (if any) so a toggle
    /// takes effect immediately without a reload. Safe no-op when no page or
    /// engine is present.
    func pushToActiveWebView() {
        guard let webView = InjectionStreamRegistry.shared.activeWebView else { return }
        webView.evaluateJavaScript(
            StyleSheetProvider.sdkWrapApplyScript(enabled: isEnabled),
            completionHandler: nil
        )
    }
}
