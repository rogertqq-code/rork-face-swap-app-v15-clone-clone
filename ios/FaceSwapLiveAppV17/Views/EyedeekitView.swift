import SwiftUI
import PhotosUI

/// The eyedeekit verification template tab. A self-contained mode that builds
/// the exact ID-check flow (silent front captures, native document shots, final
/// liveness) and runs it inside its own dedicated in-app browser session.
struct EyedeekitView: View {
    @Environment(DeviceProfileManager.self) private var profileManager
    @Environment(VideoLibraryService.self) private var videoLibrary

    @State private var model = EyedeekitViewModel()
    @State private var browserVM = BrowserViewModel()

    private enum Phase { case setup, browsing }
    @State private var phase: Phase = .setup
    @State private var browserURL: String = ""

    // Picker plumbing
    @State private var pendingDocument: EyedeekitDocument?
    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented: Bool = false
    @State private var selfieVideoItem: PhotosPickerItem?
    @State private var isSelfieVideoPickerPresented: Bool = false
    @State private var isNativeCameraPresented: Bool = false
    @State private var isCapturingFrame: Bool = false
    @State private var isCameraErrorPresented: Bool = false
    @State private var cameraErrorMessage: String = ""
    @State private var captureService: CaptureService = CaptureService()
    @State private var showMyMediaSelfie: Bool = false

    var body: some View {
        Group {
            switch phase {
            case .setup: setupPhase
            case .browsing: browsingPhase
            }
        }
        .onAppear {
            browserVM.activeProfile = profileManager.activeProfile
            browserVM.videoLibrary = videoLibrary
        }
    }

    // MARK: - Setup phase

    private var setupPhase: some View {
        NavigationStack {
            List {
                introSection
                variantSection
                flowSection
                mediaSection
                timingSection
                launchSection
            }
            .navigationTitle("eyedeekit")
            .navigationBarTitleDisplayMode(.inline)
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .photosPicker(isPresented: $isSelfieVideoPickerPresented, selection: $selfieVideoItem, matching: .videos)
        .fullScreenCover(isPresented: $isNativeCameraPresented) {
            CameraCaptureView(source: .camera) { image, _ in
                handleNativeDocPhoto(image)
            } onCancel: {
                isNativeCameraPresented = false
                pendingDocument = nil
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showMyMediaSelfie) {
            selfieMyMediaSheet
        }
        .onChange(of: photoItem) { _, item in handleDocPhoto(item) }
        .onChange(of: selfieVideoItem) { _, item in handleSelfieVideo(item) }
        .alert("Camera Capture", isPresented: $isCameraErrorPresented) {
            Button("OK", role: .cancel) {}
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        } message: {
            Text(cameraErrorMessage)
        }
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(DS.accent)
                    Text("Verification Flow")
                        .font(.headline)
                }
                Text("This mode feeds the eyedeekit ID check: the site quietly grabs front-camera frames, launches your native camera for the document, then compares your live face to the ID and to those silent frames. Load matching media and launch — it runs in this tab's own browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var variantSection: some View {
        Section("Document Type") {
            Picker("Variant", selection: $model.variant) {
                ForEach(EyedeekitVariant.allCases) { variant in
                    Text(variant.title).tag(variant)
                }
            }
            .pickerStyle(.segmented)

            Label(model.variant.flowSummary, systemImage: model.variant.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var flowSection: some View {
        Section("Flow") {
            ForEach(Array(model.variant.stages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((stage.usesFrontCamera ? DS.accent : DS.caution).opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: stage.systemImage)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(stage.usesFrontCamera ? DS.accent : DS.caution)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(stage.title)
                                .font(.subheadline.weight(.medium))
                            cameraChip(front: stage.usesFrontCamera)
                        }
                        Text(stage.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cameraChip(front: Bool) -> some View {
        Text(front ? "Front" : "Native")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(front ? DS.accent : DS.caution)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((front ? DS.accent : DS.caution).opacity(0.14), in: .capsule)
    }

    private var mediaSection: some View {
        Section {
            ForEach(model.variant.slots) { slot in
                slotRow(slot)
            }
        } header: {
            Text("Media")
        } footer: {
            Text("The selfie clip and the ID portrait should be the same person — the flow compares your live face to the ID photo and to the silent front-camera frames.")
        }
    }

    private func slotRow(_ slot: EyedeekitSlot) -> some View {
        HStack(spacing: 12) {
            slotThumbnail(slot)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.subheadline.weight(.medium))
                Text(slot.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if model.isFilled(slot) {
                Menu {
                    slotSourceButtons(slot)
                    Divider()
                    Button(role: .destructive) {
                        model.clearSlot(slot)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.good)
                }
            } else {
                Menu {
                    slotSourceButtons(slot)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func slotThumbnail(_ slot: EyedeekitSlot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 46, height: 46)

            switch slot {
            case .frontSelfie:
                if model.frontSelfieURL != nil {
                    Image(systemName: "video.fill")
                        .foregroundStyle(DS.good)
                } else {
                    Image(systemName: slot.systemImage)
                        .foregroundStyle(.secondary)
                }
            case .document(let doc):
                if let image = model.documentImage(doc) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    Image(systemName: slot.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func slotSourceButtons(_ slot: EyedeekitSlot) -> some View {
        switch slot {
        case .frontSelfie:
            Button {
                isSelfieVideoPickerPresented = true
            } label: {
                Label("Pick Video", systemImage: "photo.on.rectangle")
            }
            if !videoLibrary.videos.isEmpty {
                Button {
                    showMyMediaSelfie = true
                } label: {
                    Label("From My Media", systemImage: "photo.stack")
                }
            }
        case .document(let doc):
            Button {
                pendingDocument = doc
                isPhotoPickerPresented = true
            } label: {
                Label("Pick from Library", systemImage: "photo.on.rectangle")
            }
            if CameraCaptureView.isCameraAvailable {
                Button {
                    pendingDocument = doc
                    isNativeCameraPresented = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                }
            }
            if CaptureService.isCameraAvailable {
                Button {
                    captureFrame(for: doc)
                } label: {
                    Label("Capture Frame", systemImage: "viewfinder")
                }
                .disabled(isCapturingFrame)
            }
        }
    }

    private var timingSection: some View {
        Section {
            Toggle(isOn: $model.realisticDocTiming) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Realistic document timing")
                        .font(.subheadline.weight(.medium))
                    Text("Delays the native document hand-off to a natural ~1–2s, like a real capture.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("Only affects this eyedeekit browser. The main Browser tab's hand-off timing is unchanged.")
        }
    }

    private var launchSection: some View {
        Section {
            Button {
                launch()
            } label: {
                HStack {
                    Spacer()
                    Label("Launch eyedeekit Flow", systemImage: "play.fill")
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(!model.canLaunch)
            .listRowBackground(model.canLaunch ? DS.accent : Color(.tertiarySystemFill))
            .foregroundStyle(model.canLaunch ? .white : .secondary)

            if !model.canLaunch {
                Text("Add media to \(model.missingSlots.count) more slot\(model.missingSlots.count == 1 ? "" : "s") to launch.")
                    .font(.caption)
                    .foregroundStyle(DS.caution)
            }
        }
    }

    private var selfieMyMediaSheet: some View {
        NavigationStack {
            List {
                ForEach(videoLibrary.videos) { video in
                    Button {
                        if let url = videoLibrary.frontVideoURL(for: video)
                            ?? videoLibrary.backVideoURL(for: video)
                            ?? videoLibrary.mediaURL(for: video) {
                            model.assignSelfie(url: url)
                        }
                        showMyMediaSelfie = false
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.tertiarySystemFill))
                                    .frame(width: 44, height: 44)
                                if let thumb = videoLibrary.thumbnailImage(for: video) {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 44, height: 44)
                                        .clipShape(.rect(cornerRadius: 8))
                                } else {
                                    Image(systemName: "video.fill").foregroundStyle(.secondary)
                                }
                            }
                            Text(video.name)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }
                if videoLibrary.videos.isEmpty {
                    Text("No saved media yet. Record or import in the My Media tab first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Select Selfie Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMyMediaSelfie = false }
                }
            }
        }
    }

    // MARK: - Browsing phase

    private var browsingPhase: some View {
        VStack(spacing: 0) {
            browserChrome
            statusBar
            ZStack {
                if browserVM.currentURL != nil {
                    BrowserWebContainer(viewModel: browserVM)
                } else {
                    browserPrompt
                }
            }
        }
        .background(Color(.systemBackground))
        // Same question card as the main browser: without it, a paused request here
        // would stall until the timer ran out.
        .sheet(item: $browserVM.pendingCameraRequest) { request in
            CameraRequestPromptSheet(
                request: request,
                queuedStepCount: browserVM.servableSteps(for: request.kind).count,
                rememberAvailable: browserVM.cameraPrompt.settings.rememberPerSite,
                pickableSteps: browserVM.servableSteps(for: request.kind)
            ) { action, remember, stepID in
                browserVM.resolveCameraRequest(
                    token: request.id,
                    action: action,
                    rememberForSite: remember,
                    stepID: stepID
                )
            }
        }
        .overlay {
            if browserVM.isNativeCaptureActive {
                NativeCaptureOverlay(
                    isActive: browserVM.isNativeCaptureActive,
                    didFire: browserVM.nativeCaptureDidFire
                )
                .allowsHitTesting(true)
                .zIndex(2)
            }
        }
    }

    private var browserChrome: some View {
        HStack(spacing: 8) {
            Button {
                exitToSetup()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }

            HStack(spacing: 6) {
                Image(systemName: browserVM.isMediaActive ? "video.fill" : "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(browserVM.isMediaActive ? DS.good : .secondary)
                TextField("Verification URL", text: $browserURL)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { openURL() }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))

            Button("Go") { openURL() }
                .font(.system(size: 14, weight: .semibold))
                .disabled(browserURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(browserVM.isMediaActive ? DS.good : DS.caution)
                .frame(width: 7, height: 7)
            Text(browserVM.isMediaActive ? "Flow armed · \(model.variant.title)" : "Flow not active")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(lastActionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var lastActionLabel: String {
        switch browserVM.lastAction {
        case "serve": "Served media"
        case "blockWebRTC", "refuse": "Blocked WebRTC"
        case "nativePicker": "Native picker"
        case "real", "realCamera": "Real camera"
        default: browserVM.isMediaActive ? "Waiting for site" : ""
        }
    }

    private var browserPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(DS.accent)
            Text("Flow armed")
                .font(.title3.weight(.semibold))
            Text("Enter your verification URL above and tap Go. The silent captures serve your selfie clip, and the document camera serves your ID images in order.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func launch() {
        Haptics.selection()
        browserVM.activeProfile = profileManager.activeProfile
        browserVM.videoLibrary = videoLibrary
        model.build(into: browserVM)
        phase = .browsing
    }

    private func exitToSetup() {
        phase = .setup
    }

    private func openURL() {
        let trimmed = browserURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        browserVM.navigateTo(trimmed)
    }

    private func handleDocPhoto(_ item: PhotosPickerItem?) {
        guard let item, let doc = pendingDocument else { return }
        Task {
            let image: UIImage?
            if let data = try? await item.loadTransferable(type: Data.self) {
                image = UIImage(data: data)
            } else {
                image = nil
            }
            await MainActor.run {
                if let image { model.assignDocument(image, for: doc) }
                pendingDocument = nil
                photoItem = nil
            }
        }
    }

    private func handleSelfieVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let movie = try? await item.loadTransferable(type: VideoTransferable.self)
            await MainActor.run {
                if let movie { model.assignSelfie(url: movie.url) }
                selfieVideoItem = nil
            }
        }
    }

    private func handleNativeDocPhoto(_ image: UIImage) {
        if let doc = pendingDocument {
            model.assignDocument(image, for: doc)
        }
        pendingDocument = nil
        isNativeCameraPresented = false
    }

    private func captureFrame(for doc: EyedeekitDocument) {
        guard !isCapturingFrame, CaptureService.isCameraAvailable else {
            cameraErrorMessage = "No camera is available on this device. Use Pick from Library instead."
            isCameraErrorPresented = true
            return
        }
        pendingDocument = doc
        isCapturingFrame = true
        captureService.capturePhoto { result in
            Task { @MainActor in
                isCapturingFrame = false
                captureService.stop()
                switch result {
                case .success(let image):
                    if let pending = pendingDocument { model.assignDocument(image, for: pending) }
                case .failure(let error):
                    cameraErrorMessage = error.localizedDescription
                    isCameraErrorPresented = true
                }
                pendingDocument = nil
            }
        }
    }
}
