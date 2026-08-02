import SwiftUI

struct BrowserContentView: View {
    let profileManager: DeviceProfileManager
    let videoLibrary: VideoLibraryService
    @State private var viewModel = BrowserViewModel()
    @FocusState private var isURLBarFocused: Bool
    @Environment(OfflineVerificationStore.self) private var verificationStore
    @Environment(\.scenePhase) private var scenePhase
#if QA_AUTOMATION
    @EnvironmentObject private var qaRuntime: QAAutomationRuntime
#endif

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            progressBar
            if viewModel.isMediaActive || viewModel.mediaDeliveryStatus == .needsAttention {
                MediaDeliveryStatusStrip(viewModel: viewModel)
            }
            browserContent
            bottomToolbar
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("browser.screen")
        .sheet(isPresented: $viewModel.showOverlayPanel) {
            OverlayControlSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAnalyzeSite) {
            AnalyzeSiteView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingCameraRequest) { request in
            CameraRequestPromptSheet(
                request: request,
                queuedStepCount: viewModel.servableSteps(for: request.kind).count,
                rememberAvailable: viewModel.cameraPrompt.settings.rememberPerSite,
                pickableSteps: viewModel.servableSteps(for: request.kind)
            ) { action, remember, stepID in
                viewModel.resolveCameraRequest(
                    token: request.id,
                    action: action,
                    rememberForSite: remember,
                    stepID: stepID
                )
            }
        }
        .confirmationDialog(
            "Burn All Data",
            isPresented: $viewModel.showBurnConfirmation,
            titleVisibility: .visible
        ) {
            Button("Burn Everything", role: .destructive) {
                Task {
                    await viewModel.burnEverything()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently destroy all browsing history, cookies, cache, website data, bookmarks, and loaded media. This cannot be undone.")
        }
        .confirmationDialog(
            "Passthrough uses the real camera",
            isPresented: $viewModel.showPassthroughWarning,
            titleVisibility: .visible
        ) {
            Button("Switch to Auto \u{2014} serve queued media") {
                viewModel.switchToAutoAndActivate()
            }
            Button("Use real camera anyway") {
                viewModel.confirmPassthroughActivation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current method is Passthrough, which means the real camera is always used. Enable Media won\u{2019}t serve queued photos or videos. Switch to Auto to start serving your media sequence, or continue with the real camera.")
        }
        .overlay {
            if viewModel.isNativeCaptureActive {
                NativeCaptureOverlay(
                    isActive: viewModel.isNativeCaptureActive,
                    didFire: viewModel.nativeCaptureDidFire
                )
                .allowsHitTesting(true)
                .zIndex(2)
            }
        }
        .overlay(alignment: .top) {
            // One banner for both surfaces. A gate that stops a request must never
            // be silent — that is what made a working engine look broken.
            if !viewModel.nativeCaptureFailure.isEmpty {
                requestNoticeBanner(viewModel.nativeCaptureFailure, label: "Dismiss hand-off message") {
                    viewModel.dismissNativeCaptureFailure()
                }
            } else if !viewModel.liveRequestNotice.isEmpty {
                requestNoticeBanner(viewModel.liveRequestNotice, label: "Dismiss camera request message") {
                    viewModel.dismissLiveRequestNotice()
                }
            }
        }
        .animation(.spring(duration: 0.28), value: viewModel.nativeCaptureFailure)
        .animation(.spring(duration: 0.28), value: viewModel.liveRequestNotice)
        .overlay {
            if viewModel.isBurning {
                ZStack {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                            .symbolEffect(.bounce.byLayer, options: .repeating)
                        Text("Burning all data...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                .allowsHitTesting(true)
            }
        }
        .onAppear {
            viewModel.videoLibrary = videoLibrary
            viewModel.verificationStore = verificationStore
            viewModel.activeProfile = profileManager.activeProfile
            viewModel.onActiveProfileUpdated = { updatedProfile in
                profileManager.updateProfile(updatedProfile)
            }
#if QA_AUTOMATION
            qaRuntime.applicationAdapter.attachBrowser(viewModel)
#endif
        }
        .onDisappear {
#if QA_AUTOMATION
            qaRuntime.applicationAdapter.detachBrowser(viewModel)
#endif
        }
        .onChange(of: profileManager.activeProfileID) { _, _ in
            viewModel.activeProfile = profileManager.activeProfile
        }
        .onChange(of: profileManager.activeProfile?.fingerprintBaseline?.capturedAt) { _, _ in
            // Pick up a fingerprint baseline captured in Diagnostics so live
            // injection uses it without needing a profile switch.
            viewModel.activeProfile = profileManager.activeProfile
        }
        .onChange(of: profileManager.activeProfile?.recommendedMethod) { _, _ in
            viewModel.activeProfile = profileManager.activeProfile
            viewModel.applyRecommendedMethodIfNoSiteMemory()
        }
        .onChange(of: scenePhase) { _, nextPhase in
            viewModel.handleScenePhase(nextPhase)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Image(systemName: viewModel.isLoading ? "arrow.clockwise" : (viewModel.isMediaActive ? "video.fill" : "magnifyingglass"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(viewModel.isMediaActive ? Color.green : .secondary)
                    .frame(width: 28)

                TextField("Search or enter URL", text: $viewModel.urlText)
                    .font(.system(size: 15))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .focused($isURLBarFocused)
                    .onSubmit {
                        viewModel.navigateTo(viewModel.urlText)
                        isURLBarFocused = false
                    }
                    .accessibilityIdentifier("browser.urlField")
                    .accessibilityValue(viewModel.currentURL?.absoluteString ?? viewModel.urlText)

                if !viewModel.urlText.isEmpty && isURLBarFocused {
                    Button {
                        viewModel.urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityIdentifier("browser.urlClear")
                    .padding(.trailing, 4)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .background(Color(.tertiarySystemFill))
            .clipShape(.rect(cornerRadius: 10))

            if isURLBarFocused {
                Button("Cancel") {
                    isURLBarFocused = false
                    if let url = viewModel.currentURL {
                        viewModel.urlText = url.absoluteString
                    }
                }
                .font(.system(size: 15))
                .accessibilityIdentifier("browser.urlCancel")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.spring(duration: 0.25), value: isURLBarFocused)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            if viewModel.isLoading {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * viewModel.estimatedProgress, height: 2)
                    .animation(.linear(duration: 0.2), value: viewModel.estimatedProgress)
            }
        }
        .frame(height: 2)
        .accessibilityIdentifier("browser.progress")
        .accessibilityValue(String(viewModel.estimatedProgress))
    }

    private var browserContent: some View {
        ZStack {
            if viewModel.currentURL != nil {
                BrowserWebContainer(viewModel: viewModel)
            } else {
                startPage
            }

            if viewModel.isOverlayActive {
                overlayLayer
            }
        }
        .accessibilityIdentifier("browser.webContent")
        .accessibilityValue(viewModel.currentURL?.absoluteString ?? "startPage")
    }

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.tertiary)

                    Text("Browser")
                        .font(.title2.weight(.semibold))

                    Text("Browse any site with media support")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(AppVersion.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.top, 60)

                if viewModel.isMediaActive {
                    mediaBanner
                }

                if !viewModel.bookmarks.isEmpty {
                    bookmarksGrid
                }

                quickLinks
            }
            .padding(.horizontal)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var mediaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Media Active")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Label("\(viewModel.sequence.count) step\(viewModel.sequence.count == 1 ? "" : "s")", systemImage: "rectangle.stack.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.1), in: .rect(cornerRadius: 10))
        .accessibilityIdentifier("browser.media.banner")
        .accessibilityValue("active=true;sequenceCount=\(viewModel.sequence.count)")
    }

    private var bookmarksGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarks")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 72), spacing: 16)
            ], spacing: 16) {
                ForEach(viewModel.bookmarks.prefix(8)) { bookmark in
                    Button {
                        viewModel.urlText = bookmark.urlString
                        viewModel.navigateTo(bookmark.urlString)
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.tertiarySystemFill))
                                    .frame(width: 56, height: 56)
                                Text(String(bookmark.title.prefix(2)).uppercased())
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Text(bookmark.displayHost)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var quickLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Links")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                quickLinkRow(icon: "video.badge.checkmark", title: "Webcam Test", subtitle: "webcamtests.com", url: "https://webcamtests.com/check", tint: .green)
                Divider().padding(.leading, 52)
                quickLinkRow(icon: "video.fill", title: "Google Meet", subtitle: "meet.google.com", url: "https://meet.google.com", tint: .blue)
                Divider().padding(.leading, 52)
                quickLinkRow(icon: "bubble.left.and.bubble.right.fill", title: "Discord", subtitle: "discord.com", url: "https://discord.com", tint: .indigo)
                Divider().padding(.leading, 52)
                quickLinkRow(icon: "play.rectangle.fill", title: "YouTube", subtitle: "youtube.com", url: "https://youtube.com", tint: .red)
                Divider().padding(.leading, 52)
                quickLinkRow(icon: "gamecontroller.fill", title: "Twitch", subtitle: "twitch.tv", url: "https://twitch.tv", tint: .purple)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    private func quickLinkRow(icon: String, title: String, subtitle: String, url: String, tint: Color = .accentColor) -> some View {
        Button {
            viewModel.urlText = url
            viewModel.navigateTo(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint, in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("browser.quickLink.\(subtitle.replacingOccurrences(of: ".", with: "_"))")
    }

    private var overlayLayer: some View {
        Group {
            if let image = viewModel.overlayPreviewImage {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .opacity(viewModel.overlayOpacity)
            } else if let videoURL = viewModel.overlayPreviewVideoURL {
                LoopingVideoPlayer(url: videoURL)
                    .opacity(viewModel.overlayOpacity)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// One compact row with every action visible. Each slot takes an equal share
    /// of the width so all six fit comfortably on a small screen without
    /// crowding, and every icon keeps a full-height tap target.
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarSlot {
                Button {
                    if viewModel.canGoBack {
                        viewModel.goBack()
                    } else {
                        viewModel.goHome()
                    }
                } label: {
                    toolbarIcon("chevron.backward")
                }
                .disabled(viewModel.currentURL == nil)
                .accessibilityIdentifier("browser.back")
            }

            toolbarSlot {
                Button { viewModel.goForward() } label: {
                    toolbarIcon("chevron.forward")
                }
                .disabled(!viewModel.canGoForward)
                .accessibilityIdentifier("browser.forward")
            }

            toolbarSlot { serveMediaToggle }

            toolbarSlot {
                Button { viewModel.showOverlayPanel = true } label: {
                    ZStack(alignment: .topTrailing) {
                        toolbarIcon("photo.stack")
                        if viewModel.hasServableStep {
                            Text("\(viewModel.sequence.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(DS.accent, in: .capsule)
                                .offset(x: 6, y: 4)
                        }
                    }
                }
                .accessibilityIdentifier("browser.media.list")
                .accessibilityLabel("Media list")
                .accessibilityValue("count=\(viewModel.sequence.count)")
            }

            toolbarSlot { nextMediaButton }

            toolbarSlot { moreMenu }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(.bar)
    }

    /// Serving media on and off, straight from the bar. A pill-shaped toggle
    /// with a live armed-status dot: green when armed and serving, amber when
    /// preparing, red when a request was blocked. The dot makes the toggle a
    /// status indicator, not just a switch.
    private var serveMediaToggle: some View {
        let isActive = viewModel.isMediaActive
        let isArmed = viewModel.engineArmChecked && viewModel.engineArmed
        let isPreparing = isActive && (!viewModel.engineArmChecked || !viewModel.engineArmed)
        let isBlocked = viewModel.mediaDeliveryStatus == .blocked || viewModel.mediaDeliveryStatus == .needsAttention
        let dotColor: Color = isBlocked ? DS.blocked : (isArmed ? DS.good : (isPreparing ? DS.caution : .clear))
        let iconName = isActive ? "web.camera.fill" : "web.camera"
        let label_ = isActive ? "Media" : "Off"

        return Button {
            if !viewModel.toggleMediaServing() {
                viewModel.showOverlayPanel = true
            }
            Haptics.selection()
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: iconName)
                        .font(.system(size: 18))
                        .foregroundStyle(isActive ? DS.good : .primary)
                        .frame(width: 28, height: 22)
                    if isActive {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                            .overlay {
                                if isPreparing {
                                    Circle()
                                        .fill(dotColor.opacity(0.4))
                                        .frame(width: 11, height: 11)
                                        .symbolEffect(.pulse, options: .repeating)
                                }
                            }
                            .offset(x: 2, y: -2)
                    }
                }
                Text(label_)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? DS.good : .secondary)
            }
            .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("browser.media.toggle")
        .accessibilityLabel("Serve media")
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityHint(isPreparing ? "Preparing the camera engine" : (isBlocked ? "A request was blocked" : ""))
    }

    private func toolbarSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity)
    }

    /// Manual "Next Media" button — advances the injected sequence to the next
    /// servable step. Replaces the old Site Check slot (moved into the More
    /// menu). Only visible when media is active and the sequence has >1 item.
    private var nextMediaButton: some View {
        let canAdvance = viewModel.isMediaActive && viewModel.sequence.count > 1
        let iconName = canAdvance ? "forward.end.fill" : "forward.end"
        let tint = canAdvance ? DS.accent : .secondary
        return Button {
            if viewModel.advanceSequence() {
                Haptics.selection()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 22)
                Text("Next")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
        }
        .disabled(!canAdvance)
        .accessibilityIdentifier("browser.media.next")
        .accessibilityLabel("Next Media")
        .accessibilityValue("pointer=\(viewModel.pointer);count=\(viewModel.sequence.count)")
        .accessibilityHint("Advance to the next media item in the sequence")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.analyzeSite()
            } label: {
                Label("Site Check", systemImage: "scope")
            }
            .disabled(viewModel.currentURL == nil)
            .accessibilityIdentifier("browser.siteCheck")

            Divider()

            Button(role: .destructive) {
                viewModel.showBurnConfirmation = true
            } label: {
                Label("Burn All Data", systemImage: "flame.fill")
            }
            .accessibilityIdentifier("browser.clearAllData")
        } label: {
            ZStack {
                toolbarIcon("ellipsis.circle")
                if viewModel.isAnalyzingSite {
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 11, y: -11)
                }
            }
        }
        .accessibilityIdentifier("browser.moreMenu")
    }

    private func requestNoticeBanner(
        _ message: String,
        label: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(label)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(3)
        .accessibilityIdentifier("browser.requestNotice")
        .accessibilityValue(message)
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
    }
}
