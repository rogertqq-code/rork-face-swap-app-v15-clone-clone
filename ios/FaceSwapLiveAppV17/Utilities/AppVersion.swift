import Foundation

/// Single source of truth for the user-facing app version shown across the UI.
/// Keep `marketing` in sync with `MARKETING_VERSION` in the Xcode project.
nonisolated enum AppVersion {
    /// Full marketing version string (matches `MARKETING_VERSION`).
    static let marketing = "6.1.0"

    /// Short, user-facing label shown in headers and panels.
    static let shortLabel = "v6.1"
}
