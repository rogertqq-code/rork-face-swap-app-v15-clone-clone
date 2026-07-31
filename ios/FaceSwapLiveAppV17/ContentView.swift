import SwiftUI

struct ContentView: View {
    @State private var profileManager = DeviceProfileManager()
    @State private var videoLibrary = VideoLibraryService()
    @State private var hasSelectedProfile: Bool = false
    @State private var verificationStore = OfflineVerificationStore()

    var body: some View {
        Group {
            if profileManager.hasActiveProfile && hasSelectedProfile {
                if let profile = profileManager.activeProfile, requiresVerification(for: profile) {
                    OfflineVerificationFlowView(profile: profile) { report in
                        verificationStore.append(report)
                        hasSelectedProfile = true
                    }
                } else {
                    mainAppView
                }
            } else {
                ProfileSelectionView(profileManager: profileManager, isOnboarding: true) {
                    withAnimation(.spring(duration: 0.4)) {
                        hasSelectedProfile = true
                    }
                }
            }
        }
        .environment(verificationStore)
        .preferredColorScheme(.dark)
        .onAppear {
            hasSelectedProfile = profileManager.hasActiveProfile
        }
    }

    private func requiresVerification(for profile: DeviceProfile) -> Bool {
        switch verificationStore.status(for: profile) {
        case .notStarted, .outdated:
            true
        case .verified, .needsAttention, .inconclusive, .skipped:
            false
        }
    }

    private var mainAppView: some View {
        TabView {
            Tab("Preview", systemImage: "photo.fill") {
                LivePreviewView()
            }
            Tab("Browser", systemImage: "globe") {
                BrowserContentView(profileManager: profileManager, videoLibrary: videoLibrary)
            }
            Tab("eyedeekit", systemImage: "checkmark.shield.fill") {
                EyedeekitView()
            }
            Tab("My Media", systemImage: "photo.stack") {
                MyVideosView(videoLibrary: videoLibrary)
            }
            Tab("Diagnostics", systemImage: "waveform.badge.magnifyingglass") {
                DiagnosticsView()
            }
            Tab("Profile", systemImage: "iphone.gen3") {
                ProfileSelectionView(profileManager: profileManager) {
                    hasSelectedProfile = true
                }
            }
        }
        .environment(profileManager)
        .environment(videoLibrary)
    }
}
