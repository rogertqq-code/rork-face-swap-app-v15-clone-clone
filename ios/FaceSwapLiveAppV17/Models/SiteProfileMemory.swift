import Foundation

/// Whether a profile is known to have worked on a site. Drives the thumbs UI
/// and the learning recommendations.
nonisolated enum SiteOutcome: String, Codable, Sendable, CaseIterable, Identifiable {
    case untested
    case worked
    case failed

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .untested: "Untested"
        case .worked: "Worked"
        case .failed: "Failed"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .untested: "questionmark.circle"
        case .worked: "hand.thumbsup.fill"
        case .failed: "hand.thumbsdown.fill"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .untested: "gray"
        case .worked: "green"
        case .failed: "red"
        }
    }
}

/// A single per-site memory record: which profile was last used on a host,
/// how it turned out, and what the scanner detected at the time. Persisted so
/// recommendations get smarter over time.
nonisolated struct SiteProfileRecord: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var host: String
    var profile: InjectionMethodKind
    var networkBackend: NetworkBackendOptions
    var outcome: SiteOutcome
    /// True when `outcome` was auto-guessed from page signals rather than set by
    /// the user. A user verdict (thumbs up/down) clears this and is never
    /// overwritten by later auto-guesses.
    var autoGuessed: Bool
    var detectedCategory: DetectedSystemCategory?
    var detectedSystemName: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        host: String,
        profile: InjectionMethodKind,
        networkBackend: NetworkBackendOptions = .off,
        outcome: SiteOutcome = .untested,
        autoGuessed: Bool = false,
        detectedCategory: DetectedSystemCategory? = nil,
        detectedSystemName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.profile = profile.migratedCameraMethod
        self.networkBackend = profile.migratedNetworkBackend ?? networkBackend
        self.outcome = outcome
        self.autoGuessed = autoGuessed
        self.detectedCategory = detectedCategory
        self.detectedSystemName = detectedSystemName
        self.updatedAt = updatedAt
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case host
        case profile
        case networkBackend
        case outcome
        case autoGuessed
        case detectedCategory
        case detectedSystemName
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try container.decode(String.self, forKey: .host)
        let decodedProfile = try container.decode(InjectionMethodKind.self, forKey: .profile)
        profile = decodedProfile.migratedCameraMethod
        let decodedBackend = try container.decodeIfPresent(NetworkBackendOptions.self, forKey: .networkBackend) ?? .off
        networkBackend = decodedProfile.migratedNetworkBackend ?? decodedBackend
        outcome = try container.decodeIfPresent(SiteOutcome.self, forKey: .outcome) ?? .untested
        autoGuessed = try container.decodeIfPresent(Bool.self, forKey: .autoGuessed) ?? false
        detectedCategory = try container.decodeIfPresent(DetectedSystemCategory.self, forKey: .detectedCategory)
        detectedSystemName = try container.decodeIfPresent(String.self, forKey: .detectedSystemName)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(host, forKey: .host)
        try container.encode(profile.migratedCameraMethod, forKey: .profile)
        try container.encode(networkBackend, forKey: .networkBackend)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(autoGuessed, forKey: .autoGuessed)
        try container.encodeIfPresent(detectedCategory, forKey: .detectedCategory)
        try container.encodeIfPresent(detectedSystemName, forKey: .detectedSystemName)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
