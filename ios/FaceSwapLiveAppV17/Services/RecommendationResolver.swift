import Foundation

nonisolated enum RecommendationResolver {
    
    /// Resolves the final recommended profile using the established precedence chain.
    ///
    /// The chain is:
    /// 1. Per-site confirmed "worked" memory (wins outright)
    /// 2. Per-site confirmed "failed" memory (steers away from the failed profile)
    /// 3. Category winner (if present and differing from the fallback)
    /// 4. Device default (reserved for future use, currently nil)
    /// 5. Scanner default
    ///
    /// - Parameters:
    ///   - siteRecord: The per-site memory record, if any.
    ///   - categoryWinner: The best profile for the detected category, if any.
    ///   - deviceDefault: The recommended profile for the device hardware.
    ///   - scannerDefault: The ultimate fallback profile.
    /// - Returns: A tuple containing the final `InjectionMethodKind` to use, and a boolean
    ///   indicating whether this recommendation was informed by site-specific memory.
    static func resolve(
        siteRecord: SiteProfileRecord?,
        categoryWinner: InjectionMethodKind?,
        deviceDefault: InjectionMethodKind? = nil,
        scannerDefault: InjectionMethodKind
    ) -> (profile: InjectionMethodKind, memoryInformed: Bool) {
        
        if let record = siteRecord {
            if record.outcome == .worked {
                return (record.profile, true)
            }
            if record.outcome == .failed {
                let candidates = [categoryWinner, deviceDefault, scannerDefault].compactMap { $0 }
                for candidate in candidates {
                    if candidate != record.profile {
                        return (candidate, true)
                    }
                }
                
                if let alt = InjectionMethodKind.deliveryMethods.first(where: { $0 != record.profile }) {
                    return (alt, true)
                }
            }
        }
        
        let candidates = [categoryWinner, deviceDefault, scannerDefault].compactMap { $0 }
        if let first = candidates.first, first != scannerDefault {
            return (first, false)
        }
        
        return (scannerDefault, false)
    }
}
