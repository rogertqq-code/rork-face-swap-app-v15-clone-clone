import SwiftUI

private enum AppRootTab: String, CaseIterable {
    case preview
    case browser
    case eyedeekit
    case media
    case diagnostics
    case profile
}

struct ContentView: View {
    @State private var profileManager = DeviceProfileManager()
    @State private var videoLibrary = VideoLibraryService()
    @State private var hasSelectedProfile: Bool = false
    @State private var verificationStore = OfflineVerificationStore()
    @State private var selectedTab: AppRootTab = .preview
#if QA_AUTOMATION
    @EnvironmentObject private var qaRuntime: QAAutomationRuntime
#endif

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
#if QA_AUTOMATION
            qaRuntime.applicationAdapter.attachRoot(
                profileManager: profileManager,
                verificationStore: verificationStore,
                activeTab: { selectedTab.rawValue },
                selectTab: { raw in
                    if let tab = AppRootTab(rawValue: raw) { selectedTab = tab }
                },
                setOnboardingComplete: { hasSelectedProfile = $0 }
            )
            Task { await qaRuntime.synchronizeManifestFeatures() }
#endif
        }
#if QA_AUTOMATION
        .onChange(of: qaRuntime.runID) { _, _ in
            Task { await qaRuntime.synchronizeManifestFeatures() }
        }
#endif
    }

    private func requiresVerification(for profile: DeviceProfile) -> Bool {
#if QA_AUTOMATION
        if qaRuntime.state?.featureValues[.onboardingComplete] == .bool(true) {
            return false
        }
#endif
        switch verificationStore.status(for: profile) {
        case .notStarted, .outdated:
            true
        case .verified, .needsAttention, .inconclusive, .skipped:
            false
        }
    }

    private var mainAppView: some View {
        TabView(selection: $selectedTab) {
            LivePreviewView()
                .accessibilityIdentifier("tab.content.preview")
                .tabItem {
                    Label("Preview", systemImage: "photo.fill")
                        .accessibilityIdentifier("tab.preview")
                }
                .tag(AppRootTab.preview)

            BrowserContentView(profileManager: profileManager, videoLibrary: videoLibrary)
                .accessibilityIdentifier("tab.content.browser")
                .tabItem {
                    Label("Browser", systemImage: "globe")
                        .accessibilityIdentifier("tab.browser")
                }
                .tag(AppRootTab.browser)

            EyedeekitView()
                .accessibilityIdentifier("tab.content.eyedeekit")
                .tabItem {
                    Label("eyedeekit", systemImage: "checkmark.shield.fill")
                        .accessibilityIdentifier("tab.eyedeekit")
                }
                .tag(AppRootTab.eyedeekit)

            MyVideosView(videoLibrary: videoLibrary)
                .accessibilityIdentifier("tab.content.media")
                .tabItem {
                    Label("My Media", systemImage: "photo.stack")
                        .accessibilityIdentifier("tab.media")
                }
                .tag(AppRootTab.media)

            DiagnosticsView()
                .accessibilityIdentifier("tab.content.diagnostics")
                .tabItem {
                    Label("Diagnostics", systemImage: "waveform.badge.magnifyingglass")
                        .accessibilityIdentifier("tab.diagnostics")
                }
                .tag(AppRootTab.diagnostics)

            ProfileSelectionView(profileManager: profileManager) {
                hasSelectedProfile = true
            }
            .accessibilityIdentifier("tab.content.profile")
            .tabItem {
                Label("Profile", systemImage: "iphone.gen3")
                    .accessibilityIdentifier("tab.profile")
            }
            .tag(AppRootTab.profile)
        }
        .accessibilityIdentifier("app.tabView")
        .environment(profileManager)
        .environment(videoLibrary)
    }
}
