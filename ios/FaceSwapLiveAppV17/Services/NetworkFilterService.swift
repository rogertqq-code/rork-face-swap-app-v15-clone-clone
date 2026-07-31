import Foundation
import WebKit

/// Compiles and caches the content-blocking rule list used by the optional
/// Network Backend switch. The rule list starves known detection, anti-bot, and
/// fingerprinting script loads before they can run, while the selected camera
/// delivery method stays unchanged.
///
/// This is the substantive, review-safe filtering an installed app can perform:
/// `WKContentRuleList` blocks the script network requests at the WebKit layer.
/// It requires a page reload to take effect and can break sites that genuinely
/// depend on the blocked scripts — both surfaced to the user in the UI.
@MainActor
final class NetworkFilterService {
    static let shared = NetworkFilterService()

    private let identifier = "fsl_network_filter_v1"
    private var compiled: WKContentRuleList?
    private var compileTask: Task<WKContentRuleList?, Never>?

    private init() {}

    /// Host fragments matched against script URLs. Drawn from the same vendor
    /// markers the site scanner recognizes, plus common fingerprint CDNs.
    private static let blockedHostFragments: [String] = [
        // Liveness / identity verification
        "onfido", "jumio", "veriff", "iproov", "idnow", "sumsub", "sum-sub",
        "facetec", "au10tix", "incode", "socure", "sensity", "regula", "mitek",
        // Anti-bot / fingerprint / consistency
        "fingerprintjs", "fpjs", "fpcdn.io", "datadome", "perimeterx", "px-cdn",
        "pxchk", "captcha.px", "arkoselabs", "funcaptcha", "arkose", "castle.io",
        "kasada", "imperva", "incapsula", "shapesecurity", "distilnetworks",
        // Generic fingerprint / device-intelligence services
        "deviceatlas", "iovation", "threatmetrix", "seon.io", "sift.com",
        "iesnare", "augur.io", "clientjs", "fpnpmcdn",
        "geetest", "maxmind.com"
    ]

    /// Returns the compiled rule list, compiling (and caching) it on first use.
    /// Falls back to `nil` if compilation fails so callers can degrade safely.
    func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        if let compileTask { return await compileTask.value }

        let task = Task<WKContentRuleList?, Never> { [identifier] in
            let store = WKContentRuleListStore.default()
            let json = Self.rulesJSON()
            let list: WKContentRuleList? = await withCheckedContinuation { continuation in
                store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                    continuation.resume(returning: list)
                }
            }
            return list
        }
        compileTask = task
        let result = await task.value
        compiled = result
        compileTask = nil
        return result
    }

    /// Builds the content-blocking JSON: block `script` resource loads whose URL
    /// contains any known detection/fingerprint host fragment.
    private static func rulesJSON() -> String {
        let rules: [[String: Any]] = blockedHostFragments.map { fragment in
            [
                "trigger": [
                    "url-filter": ".*\(escapeForURLFilter(fragment)).*",
                    "resource-type": ["script"]
                ],
                "action": ["type": "block"]
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Escapes regex metacharacters that appear in host fragments (e.g. dots) so
    /// the url-filter matches literally.
    private static func escapeForURLFilter(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if ".?*+()[]{}|^$\\".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
