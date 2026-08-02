import SwiftUI
import PhotosUI

struct OverlayControlSheet: View {
    @Bindable var viewModel: BrowserViewModel

    @State private var pendingPhotoStepID: UUID?
    @State private var pendingVideoStepID: UUID?
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isVideoPickerPresented: Bool = false
    @State private var isNativeCameraPresented: Bool = false
    @State private var isCapturingFrame: Bool = false
    @State private var isCameraErrorPresented: Bool = false
    @State private var cameraErrorMessage: String = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var captureService: CaptureService = CaptureService()

    @State private var showMyVideos: Bool = false
    @State private var showSaveSequencePrompt: Bool = false
    @State private var showSaveTemplatePrompt: Bool = false
    @State private var saveName: String = ""
    @State private var showAnalyze: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var didReset: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                profileSection
                analyzeSection
                advanceModeSection
                sequenceSection
                activationSection
                sdkInterceptionSection
                librarySection
                visualOverlaySection
                resetSection
                versionSection
            }
            .navigationTitle("Media Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.sequence.isEmpty {
                        EditButton()
                            .accessibilityIdentifier("browser.controls.sequence.edit")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("browser.controls.close")
                }
            }
        }
        .accessibilityIdentifier("browser.controls.sheet")
        .accessibilityValue("sequenceCount=\(viewModel.sequence.count);pointer=\(viewModel.pointer);media=\(viewModel.isMediaActive);method=\(viewModel.activeInjectionProfile.rawValue)")
        .sheet(isPresented: $showAnalyze) {
            AnalyzeSiteView(viewModel: viewModel)
        }
        .confirmationDialog(
            "Reset Injection Defaults",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                viewModel.resetInjectionDefaults()
                didReset = true
            }
            .accessibilityIdentifier("browser.controls.reset.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("browser.controls.reset.cancel")
        } message: {
            Text("Clears every saved per-site camera answer, turns Ask Me off, and forgets learned per-site methods. Your media list, saved sequences and bookmarks are untouched.")
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
        .photosPicker(isPresented: $isVideoPickerPresented, selection: $videoItem, matching: .videos)
        .fullScreenCover(isPresented: $isNativeCameraPresented) {
            CameraCaptureView(source: .camera) { image, _ in
                handleNativePhoto(image)
            } onCancel: {
                isNativeCameraPresented = false
                pendingPhotoStepID = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in handlePhoto(item) }
        .onChange(of: videoItem) { _, item in handleVideo(item) }
        .sheet(isPresented: $showMyVideos) {
            MyVideosSequenceSheet(videoLibrary: viewModel.videoLibrary) { media in
                viewModel.loadSavedVideoIntoSequence(media)
                showMyVideos = false
            } onAddVariant: { variant, name in
                viewModel.addMediaVariantStep(variant, mediaName: name)
                showMyVideos = false
            } onAddVideo: { url, name in
                viewModel.addLibraryVideoStep(url, name: name)
            }
        }
        .alert("Camera Capture", isPresented: $isCameraErrorPresented) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("browser.controls.cameraError.dismiss")
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .accessibilityIdentifier("browser.controls.cameraError.settings")
        } message: {
            Text(cameraErrorMessage)
        }
        .alert("Save Sequence", isPresented: $showSaveSequencePrompt) {
            TextField("Name", text: $saveName)
                .accessibilityIdentifier("browser.controls.saveSequence.name")
            Button("Save") {
                viewModel.saveCurrentSequence(name: saveName, asTemplate: false)
                saveName = ""
            }
            .accessibilityIdentifier("browser.controls.saveSequence.confirm")
            Button("Cancel", role: .cancel) { saveName = "" }
                .accessibilityIdentifier("browser.controls.saveSequence.cancel")
        } message: {
            Text("Stores the exact list with its photo and video files so you can reload it later.")
        }
        .alert("Save Template", isPresented: $showSaveTemplatePrompt) {
            TextField("Name", text: $saveName)
                .accessibilityIdentifier("browser.controls.saveTemplate.name")
            Button("Save") {
                viewModel.saveCurrentSequence(name: saveName, asTemplate: true)
                saveName = ""
            }
            .accessibilityIdentifier("browser.controls.saveTemplate.confirm")
            Button("Cancel", role: .cancel) { saveName = "" }
                .accessibilityIdentifier("browser.controls.saveTemplate.cancel")
        } message: {
            Text("Stores only the ordered placeholders — no media — as a reusable template.")
        }
    }

    // MARK: - Picker plumbing

    private func handlePhoto(_ item: PhotosPickerItem?) {
        guard let item, let stepID = pendingPhotoStepID else { return }
        viewModel.markStepImporting(stepID)
        Task {
            let loadedImage: UIImage?
            if let data = try? await item.loadTransferable(type: Data.self) {
                loadedImage = UIImage(data: data)
            } else {
                loadedImage = nil
            }

            await MainActor.run {
                if let loadedImage {
                    viewModel.setStepImage(loadedImage, for: stepID)
                    pendingPhotoStepID = nil
                } else {
                    viewModel.markStepImportFailed(stepID)
                }
                photoItem = nil
            }
        }
    }

    private func handleVideo(_ item: PhotosPickerItem?) {
        guard let item, let stepID = pendingVideoStepID else { return }
        viewModel.markStepImporting(stepID)
        Task {
            let movie = try? await item.loadTransferable(type: VideoTransferable.self)
            await MainActor.run {
                if let movie {
                    viewModel.setStepVideo(movie.url, for: stepID)
                    pendingVideoStepID = nil
                } else {
                    viewModel.markStepImportFailed(stepID)
                }
                videoItem = nil
            }
        }
    }

    private func addAndPickPhoto(surface: RequestSurface = .either) {
        if let id = viewModel.addStep(kind: .photo, requestSurface: surface) {
            choosePhoto(for: id)
        }
    }

    private func addAndTakePhoto() {
        if let id = viewModel.addStep(kind: .photo) {
            takePhoto(for: id)
        }
    }

    private func addAndCaptureFrame() {
        if let id = viewModel.addStep(kind: .photo) {
            captureFrame(for: id)
        }
    }
    private func addAndPickVideo(surface: RequestSurface = .either) {
        if let id = viewModel.addStep(kind: .video, requestSurface: surface) {
            pendingVideoStepID = id
            isVideoPickerPresented = true
        }
    }

    private func choosePhoto(for stepID: UUID) {
        pendingPhotoStepID = stepID
        isPhotoPickerPresented = true
    }

    private func takePhoto(for stepID: UUID) {
        pendingPhotoStepID = stepID
        // Prefer the system camera UI when available; otherwise fall through to
        // AVFoundation still capture so the option is never a silent no-op.
        if CameraCaptureView.isCameraAvailable {
            isNativeCameraPresented = true
        } else if CaptureService.isCameraAvailable {
            captureFrame(for: stepID)
        } else {
            cameraErrorMessage = "No camera is available on this device. Use Pick from Library instead."
            isCameraErrorPresented = true
            pendingPhotoStepID = nil
        }
    }

    private func handleNativePhoto(_ image: UIImage) {
        guard let stepID = pendingPhotoStepID else {
            isNativeCameraPresented = false
            return
        }
        viewModel.setStepImage(image, for: stepID)
        pendingPhotoStepID = nil
        isNativeCameraPresented = false
    }

    private func captureFrame(for stepID: UUID) {
        guard !isCapturingFrame else { return }
        guard CaptureService.isCameraAvailable else {
            cameraErrorMessage = "No camera is available on this device. Use Pick from Library instead."
            isCameraErrorPresented = true
            return
        }
        pendingPhotoStepID = stepID
        isCapturingFrame = true
        viewModel.markStepImporting(stepID)
        captureService.capturePhoto { result in
            Task { @MainActor in
                isCapturingFrame = false
                await captureService.stop()
                switch result {
                case .success(let image):
                    viewModel.setStepImage(image, for: stepID)
                case .failure(let error):
                    viewModel.markStepImportFailed(stepID)
                    cameraErrorMessage = error.localizedDescription
                    isCameraErrorPresented = true
                }
                pendingPhotoStepID = nil
            }
        }
    }

    private func chooseVideo(for stepID: UUID) {
        pendingVideoStepID = stepID
        isVideoPickerPresented = true
    }

    // MARK: - Camera profile & scanner

    private var profileSection: some View {
        Section {
            InjectionProfilePicker(viewModel: viewModel)
                .accessibilityIdentifier("browser.controls.injectionProfile")
                .accessibilityValue(viewModel.activeInjectionProfile.rawValue)
        } header: {
            Text("Injection Method")
        } footer: {
            Text("Choose how media is fed into the page: Canvas Pipeline (best compatibility), Raw Frame Pipe (cleanest signal), Private Lane (app-only isolation), or Passthrough (real camera). The Network backend switches below layer detection-script blocking and the rewrite proxy on top of any method; reload after changing them.")
        }
    }

    private var analyzeSection: some View {
        Section {
            Button {
                Haptics.selection()
                viewModel.refreshSiteAnalysis()
                showAnalyze = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(DS.accent.opacity(0.16))
                            .frame(width: 36, height: 36)
                        Image(systemName: "scope")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DS.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyze Site")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(analyzeSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if viewModel.isAnalyzingSite {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(viewModel.currentURL == nil)
            .accessibilityIdentifier("browser.controls.analyzeSite")
        } header: {
            Text("Site Intelligence")
        } footer: {
            Text("Identify the camera or anti-spoof system, read the injection and security report, and learn the front/back request pattern — all in one place.")
        }
    }

    private var analyzeSubtitle: String {
        if viewModel.currentURL == nil { return "Open a site in the browser to analyze it." }
        if let detected = viewModel.latestDetectedSystem { return "\(detected.systemName) · recommends \(detected.recommendedProfile.label)" }
        return "Detect the system and get a recommended method."
    }

    // MARK: - Advance mode

    private var advanceModeSection: some View {
        Section {
            Picker("Advance", selection: Binding(
                get: { viewModel.advanceMode },
                set: { viewModel.setAdvanceMode($0) }
            )) {
                ForEach(SequenceAdvanceMode.allCases) { mode in
                    Text(shortLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("browser.controls.advanceMode")
            .accessibilityValue(viewModel.advanceMode.rawValue)

            Picker("When the list ends", selection: Binding(
                get: { viewModel.endBehavior },
                set: { viewModel.setEndBehavior($0) }
            )) {
                ForEach(SequenceEndBehavior.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("browser.controls.endBehavior")
            .accessibilityValue(viewModel.endBehavior.rawValue)
        } header: {
            Text("How requests advance")
        } footer: {
            Text(advanceModeHelp)
        }
    }

    private func shortLabel(_ mode: SequenceAdvanceMode) -> String {
        switch mode {
        case .advanceEach: "Advance each request"
        case .holdCurrent: "Hold current"
        }
    }

    private var advanceModeHelp: String {
        switch viewModel.advanceMode {
        case .advanceEach:
            "Every camera request serves the next step in order and advances."
        case .holdCurrent:
            "Every camera request serves the current step. Does not advance."
        }
    }

    // MARK: - Sequence

    private var sequenceSection: some View {
        Section {
            if viewModel.sequence.isEmpty {
                emptyState
            } else {
                ForEach(Array(viewModel.sequence.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, index: index)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel.removeStep(step.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .accessibilityIdentifier("browser.controls.sequence.remove.\(step.id.uuidString)")
                        }
                }
                .onMove { source, destination in
                    viewModel.moveStep(from: source, to: destination)
                }
            }

            addStepMenu

            if !viewModel.sequence.isEmpty {
                Button {
                    viewModel.resetPosition()
                } label: {
                    Label("Reset position", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("browser.controls.sequence.resetPosition")

                Button(role: .destructive) {
                    viewModel.clearSequence()
                    pendingPhotoStepID = nil
                    pendingVideoStepID = nil
                } label: {
                    Label("Clear & restore real camera", systemImage: "xmark.circle.fill")
                }
                .accessibilityIdentifier("browser.controls.sequence.clear")
            }
        } header: {
            HStack {
                Text("Sequence")
                Spacer()
                Text("\(viewModel.sequence.count)/\(maxSequenceSteps)")
                    .monospacedDigit()
                    .foregroundStyle(viewModel.canAddStep ? Color.secondary : Color.orange)
            }
        } footer: {
            Text("Each photo or video has a Live camera switch — serve the fake live feed or block it. The Take Photo / file-upload picker is always faked while media is on: even on Block or WebRTC-block steps it hands over the next photo as a fresh capture, never the real camera.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No steps yet")
                .font(.subheadline.weight(.semibold))
            Text("Add photos, videos, or WebRTC block steps. Each photo/video can serve or block the live camera; the upload picker is always faked while media is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var addStepMenu: some View {
        Menu {
            Menu {
                Button {
                    addAndPickPhoto()
                } label: {
                    Label("Pick from Library", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("browser.controls.add.photo.library")
                // Show Take Photo when either system camera UI or AVFoundation
                // can capture; takePhoto() picks the best available path.
                if CameraCaptureView.isCameraAvailable || CaptureService.isCameraAvailable {
                    Button {
                        addAndTakePhoto()
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                    }
                    .disabled(isCapturingFrame)
                    .accessibilityIdentifier("browser.controls.add.photo.camera")
                }
                if CaptureService.isCameraAvailable {
                    Button {
                        addAndCaptureFrame()
                    } label: {
                        Label("Capture Frame", systemImage: "viewfinder")
                    }
                    .disabled(isCapturingFrame)
                    .accessibilityIdentifier("browser.controls.add.photo.captureFrame")
                }
            } label: {
                Label("Add Photo", systemImage: "photo.badge.plus")
            }
            Button("Add Video") { addAndPickVideo() }
                .accessibilityIdentifier("browser.controls.add.video")
            Divider()
            // Ready-made steps reserved for one request surface, so a flow can be
            // laid out in the exact order a site will ask.
            Menu {
                Button {
                    addAndPickPhoto(surface: .nativeCamera)
                } label: {
                    Label("Native Camera Photo", systemImage: "camera.fill")
                }
                Button {
                    addAndPickPhoto(surface: .liveCamera)
                } label: {
                    Label("Live Camera Photo", systemImage: "video.fill")
                }
                Button {
                    addAndPickVideo(surface: .liveCamera)
                } label: {
                    Label("Live Camera Video", systemImage: "video.badge.waveform")
                }
            } label: {
                Label("Add For One Request", systemImage: "arrow.triangle.branch")
            }
            Divider()
            Button("Block WebRTC Once") { viewModel.addStep(kind: .webRTCBlock) }
                .accessibilityIdentifier("browser.controls.add.webRTCBlock")
            Button("Stream Block") { viewModel.addStep(kind: .block) }
                .accessibilityIdentifier("browser.controls.add.streamBlock")
        } label: {
            Label("Add Step", systemImage: "plus.circle.fill")
        }
        .disabled(!viewModel.canAddStep)
        .accessibilityIdentifier("browser.controls.sequence.add")
        .accessibilityValue("count=\(viewModel.sequence.count);limit=\(maxSequenceSteps)")
    }

    private func stepRow(_ step: SequenceStep, index: Int) -> some View {
        let isLive = viewModel.isMediaActive && viewModel.activeStep?.id == step.id

        return HStack(spacing: 12) {
            thumbnail(step)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(stepTitle(step))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isLive {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 6) {
                    if step.kind == .webRTCBlock {
                        Text("one WebRTC request")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: .capsule)
                    } else if step.kind == .block {
                        blockModeMenu(step)
                    } else if step.isConverting {
                        ProgressView().controlSize(.mini)
                        Text(step.isPlaceholder ? "Importing…" : "\(Int(step.conversionProgress * 100))%")
                            .font(step.isPlaceholder ? .caption2 : .caption2.monospacedDigit())
                            .foregroundStyle(.blue)
                    } else if step.isPlaceholder {
                        Text("No media")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                if step.kind == .photo || step.kind == .video {
                    HStack(spacing: 6) {
                        liveCameraMenu(step)
                        requestSurfaceMenu(step)
                    }
                }

                if step.isPlaceholder && !step.isConverting {
                    HStack(spacing: 8) {
                        if step.kind == .photo {
                            photoSourceMenu(for: step.id)
                        }
                        if step.kind == .video {
                            Button { chooseVideo(for: step.id) } label: {
                                Label("Choose Video", systemImage: "video")
                            }
                            .accessibilityIdentifier("browser.controls.step.video.\(step.id.uuidString)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(isLive ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
        .accessibilityIdentifier("browser.controls.step.\(step.id.uuidString)")
        .accessibilityValue("index=\(index);kind=\(step.kind.rawValue);live=\(isLive);placeholder=\(step.isPlaceholder);surface=\(step.requestSurface.rawValue)")
    }

    private func thumbnail(_ step: SequenceStep) -> some View {
        Group {
            if let image = step.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(stepTint(step).opacity(0.16))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: stepIcon(step))
                            .font(.title3)
                            .foregroundStyle(stepTint(step))
                    }
            }
        }
    }

    private func liveCameraMenu(_ step: SequenceStep) -> some View {
        let isBlocked = step.liveCamera == .block
        return Menu {
            Button {
                viewModel.setStepLiveCamera(.serveLive, for: step.id)
            } label: {
                Label("Serve live feed", systemImage: step.liveCamera == .serveLive ? "checkmark" : "video.fill")
            }
            Button {
                viewModel.setStepLiveCamera(.block, for: step.id)
            } label: {
                Label("Block live camera", systemImage: step.liveCamera == .block ? "checkmark" : "video.slash.fill")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isBlocked ? "video.slash.fill" : "video.fill")
                    .font(.system(size: 9))
                Text(isBlocked ? "Live: Block" : "Live: Serve")
                    .font(.caption2.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(isBlocked ? Color.red : Color.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isBlocked ? Color.red : Color.green).opacity(0.12), in: .capsule)
        }
        .accessibilityIdentifier("browser.controls.step.liveCamera.\(step.id.uuidString)")
        .accessibilityValue(step.liveCamera.rawValue)
    }

    /// Which kind of camera request this step answers. "Either" is the default and
    /// keeps the original behavior for every existing sequence.
    private func requestSurfaceMenu(_ step: SequenceStep) -> some View {
        let surface = step.requestSurface
        let tint: Color = switch surface {
        case .either: .secondary
        case .liveCamera: .green
        case .nativeCamera: .orange
        }
        return Menu {
            ForEach(RequestSurface.allCases) { option in
                Button {
                    viewModel.setStepRequestSurface(option, for: step.id)
                } label: {
                    Label(option.label, systemImage: surface == option ? "checkmark" : option.icon)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: surface.icon)
                    .font(.system(size: 9))
                Text("Answers: \(surface.shortLabel)")
                    .font(.caption2.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
        }
        .accessibilityIdentifier("browser.controls.step.surface.\(step.id.uuidString)")
        .accessibilityValue(surface.rawValue)
    }

    private func blockModeMenu(_ step: SequenceStep) -> some View {
        Menu {
            Button {
                viewModel.setStepBlockMode(.once, for: step.id)
            } label: {
                Label("Block once", systemImage: step.blockMode == .once ? "checkmark" : "")
            }
            Button {
                viewModel.setStepBlockMode(.fromHereOn, for: step.id)
            } label: {
                Label("Block from here", systemImage: step.blockMode == .fromHereOn ? "checkmark" : "")
            }
        } label: {
            HStack(spacing: 3) {
                Text(step.blockMode.label)
                    .font(.caption2.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.red.opacity(0.12), in: .capsule)
        }
        .accessibilityIdentifier("browser.controls.step.blockMode.\(step.id.uuidString)")
        .accessibilityValue(step.blockMode.rawValue)
    }


    private func photoSourceMenu(for stepID: UUID) -> some View {
        Menu {
            Button {
                choosePhoto(for: stepID)
            } label: {
                Label("Pick from Library", systemImage: "photo.on.rectangle")
            }
            if CameraCaptureView.isCameraAvailable || CaptureService.isCameraAvailable {
                Button {
                    takePhoto(for: stepID)
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                }
                .disabled(isCapturingFrame)
            }
            if CaptureService.isCameraAvailable {
                Button {
                    captureFrame(for: stepID)
                } label: {
                    Label("Capture Frame", systemImage: "viewfinder")
                }
                .disabled(isCapturingFrame)
            }
        } label: {
            Label("Choose Photo", systemImage: "photo")
        }
        .accessibilityIdentifier("browser.controls.step.photo.\(stepID.uuidString)")
    }

    private func stepTitle(_ step: SequenceStep) -> String {
        switch step.kind {
        case .webRTCBlock: step.displayName.isEmpty ? "Block WebRTC Once" : step.displayName
        case .block: step.displayName.isEmpty ? "Stream Block" : step.displayName
        case .photo: step.displayName.isEmpty ? "Photo" : step.displayName
        case .video: step.displayName.isEmpty ? "Video" : step.displayName
        }
    }

    private func stepIcon(_ step: SequenceStep) -> String {
        switch step.kind {
        case .photo: "photo"
        case .video: "video"
        case .webRTCBlock: "video.slash.fill"
        case .block: "hand.raised.fill"
        }
    }

    private func stepTint(_ step: SequenceStep) -> Color {
        switch step.kind {
        case .webRTCBlock: .orange
        case .block: .red
        case .photo, .video: .blue
        }
    }

    // MARK: - Activation

    private var activationSection: some View {
        Section {
            Toggle("Enable Media", isOn: Binding(
                get: { viewModel.isMediaActive },
                set: { viewModel.setMediaActive($0) }
            ))
            .disabled(!viewModel.hasServableStep)
            .accessibilityIdentifier("browser.controls.mediaEnabled")
            .accessibilityValue(viewModel.isMediaActive ? "on" : "off")

            if !viewModel.hasServableStep {
                Text("Add at least one photo, video, or block step to start serving media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.activeInjectionProfile == .passthrough {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.caution)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Passthrough is active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.caution)
                        Text("The real camera is used. Switch to Auto or another method to serve queued media.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(DS.caution.opacity(0.1), in: .rect(cornerRadius: 10))
            }

            if viewModel.isMediaActive {
                HStack {
                    advanceCounter("Pointer", value: viewModel.pointer, color: .blue)
                    Spacer()
                    Text(lastActionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                CameraRequestSettingsView(store: viewModel.cameraPrompt) {
                    // Any change has to reach the page that is already open.
                    viewModel.syncCameraPromptState()
                }
            } label: {
                HStack {
                    Label("Camera Requests", systemImage: "questionmark.app.dashed")
                    Spacer()
                    Text(viewModel.cameraPrompt.settings.enabledKindsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("browser.controls.cameraRequests")
            .accessibilityValue(viewModel.cameraPrompt.settings.enabledKindsSummary)

        } header: {
            Text("Media Source")
        } footer: {
            if viewModel.hasServableStep {
                Text("Turn on to serve media steps or block matching WebRTC stream requests. A file hand-off is only marked complete after WebKit confirms a native file landed; otherwise the app asks for a fresh user tap instead of claiming a system camera opened.")
            } else {
                Text("Add at least one photo, video, or WebRTC block step to enable the sequence. Use Analyze Site to learn the live page's front/back request pattern.")
            }
        }
    }

    private var lastActionLabel: String {
        switch viewModel.lastAction {
        case "serve": "Last: served media"
        case "blockWebRTC", "refuse": "Last: blocked WebRTC"
        case "blockNative": "Last: blocked this site's camera request"
        case "hardBlock": "Last: blocked (no real camera)"
        case "deny": "Last: denied (no real camera)"
        case "nativePicker": "Last: picker (no media to fake)"
        case "nativePickerFail", "nativePickerRetry": "Last: hand-off needs a fresh user tap"
        case "realCamera", "real": "Last: real camera"
        default: "Waiting for request"
        }
    }

    private func advanceCounter(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)/\(viewModel.sequence.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - Save & load

    private var librarySection: some View {
        Section {
            Menu {
                Button {
                    saveName = ""
                    showSaveSequencePrompt = true
                } label: {
                    Label("Save as Sequence", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("browser.controls.library.saveSequence")
                Button {
                    saveName = ""
                    showSaveTemplatePrompt = true
                } label: {
                    Label("Save as Template", systemImage: "square.and.arrow.down.on.square")
                }
                .accessibilityIdentifier("browser.controls.library.saveTemplate")
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.sequence.isEmpty)
            .accessibilityIdentifier("browser.controls.library.saveMenu")

            ForEach(viewModel.sequenceLibrary.saved) { record in
                Button {
                    viewModel.loadSaved(record)
                    pendingPhotoStepID = nil
                    pendingVideoStepID = nil
                } label: {
                    savedRow(record)
                }
                .accessibilityIdentifier("browser.controls.library.saved.\(record.id.uuidString)")
                .accessibilityValue("name=\(record.name);template=\(record.isTemplate);steps=\(record.steps.count)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.deleteSaved(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("browser.controls.library.delete.\(record.id.uuidString)")
                }
            }

            Button {
                showMyVideos = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add from My Media")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(viewModel.videoLibrary.videos.count) saved item\(viewModel.videoLibrary.videos.count == 1 ? "" : "s") · \(viewModel.videoLibrary.videos.reduce(0) { $0 + $1.allVariants.count }) variants")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!viewModel.canAddStep)
            .accessibilityIdentifier("browser.controls.library.addMedia")
        } header: {
            Text("Saved & Library")
        } footer: {
            Text("Save the current list as a reusable Sequence (with media) or Template (placeholders only). Tap a saved item to load it, or add image and video variants from My Media.")
        }
    }

    private func savedRow(_ record: SavedMediaSequence) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.isTemplate ? "square.dashed" : "rectangle.stack.fill")
                .font(.title3)
                .foregroundStyle(record.isTemplate ? .orange : .purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(record.isTemplate ? "Template" : "Sequence") · \(record.steps.count) step\(record.steps.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - SDK interception

    private var sdkInterceptionSection: some View {
        Section {
            Toggle("Intercept SDK Camera Calls", isOn: Binding(
                get: { SdkInterceptionStore.shared.isEnabled },
                set: { SdkInterceptionStore.shared.isEnabled = $0 }
            ))
            .disabled(!viewModel.hasServableStep)
            .accessibilityIdentifier("browser.controls.sdkInterception")
            .accessibilityValue(SdkInterceptionStore.shared.isEnabled ? "on" : "off")

            if SdkInterceptionStore.shared.isEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SDK wrapping active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                        Text("Vendor SDK launchers and bridge transports are routed through the injection engine. Standard getUserMedia and file-picker interception remains always on.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.cyan.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        } header: {
            Text("SDK Interception")
        } footer: {
            Text("Optional. Wraps vendor verification SDKs (Onfido, Veriff, iProov, FaceTec, etc.), Cordova/Capacitor camera APIs, and bridge transports so camera commands route through the queued media. Only active when media is enabled.")
        }
    }

    // MARK: - Visual overlay

    private var visualOverlaySection: some View {
        Section {
            Toggle("Visual Overlay", isOn: $viewModel.isOverlayActive)
                .disabled(!viewModel.hasMedia)
                .accessibilityIdentifier("browser.controls.visualOverlay")
                .accessibilityValue(viewModel.isOverlayActive ? "on" : "off")

            if viewModel.isOverlayActive {
                HStack {
                    Text("Opacity").font(.subheadline)
                    Slider(value: $viewModel.overlayOpacity, in: 0.1...1.0, step: 0.05)
                        .accessibilityIdentifier("browser.controls.overlayOpacity")
                        .accessibilityValue(String(viewModel.overlayOpacity))
                }
            }
        } header: {
            Text("Visual Overlay")
        } footer: {
            Text("Shows the active step's media directly on top of the browser view as a visual cover.")
        }
    }

    // MARK: - Reset

    /// The one-tap way out when a site is stuck. Everything cleared here is a
    /// remembered behaviour that can divert or refuse a camera request; no media
    /// or saved sequence is affected.
    private var resetSection: some View {
        Section {
            Button {
                showResetConfirmation = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: didReset ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(didReset ? DS.good : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(didReset ? "Injection Defaults Reset" : "Reset Injection Defaults")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(didReset
                            ? "Saved site answers and learned methods were cleared."
                            : "Use this if a site stops receiving your media.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityIdentifier("browser.controls.reset")
            .accessibilityValue(didReset ? "completed" : "ready")
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Clears saved per-site camera answers, turns Ask Me off, and forgets learned per-site methods. Your media, saved sequences and bookmarks are never touched.")
        }
    }

    private var versionSection: some View {
        Section {
            HStack {
                Spacer()
                Text(AppVersion.shortLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("browser.controls.version")
            .accessibilityValue(AppVersion.shortLabel)
        }
    }
}

// MARK: - My Media picker (adds into the sequence)

struct MyVideosSequenceSheet: View {
    let videoLibrary: VideoLibraryService
    var onAddBoth: (SavedVideo) -> Void
    var onAddVariant: (SavedMediaVariant, String) -> Void
    var onAddVideo: (URL, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if videoLibrary.videos.isEmpty {
                    ContentUnavailableView("No Media", systemImage: "photo.stack", description: Text("Import images or videos from the My Media tab first, then generate variants."))
                } else {
                    List(videoLibrary.videos) { media in
                        Section {
                            if !media.allVariants.isEmpty {
                                Button {
                                    onAddBoth(media)
                                    dismiss()
                                } label: {
                                    Label("Add All Variants", systemImage: "rectangle.stack.badge.plus")
                                }
                                .tint(.blue)
                                .accessibilityIdentifier("browser.controls.mediaPicker.all.\(media.id.uuidString)")

                                ForEach(media.allVariants) { variant in
                                    Button {
                                        onAddVariant(variant, media.name)
                                        dismiss()
                                    } label: {
                                        Label("Add \(variant.target.label) · \(variant.specLabel)", systemImage: variant.kind == .image ? "photo" : "video.fill")
                                    }
                                    .accessibilityIdentifier("browser.controls.mediaPicker.variant.\(variant.id.uuidString)")
                                }
                            } else if media.isVideo {
                                if let url = videoLibrary.frontVideoURL(for: media) ?? videoLibrary.backVideoURL(for: media) {
                                    Button {
                                        onAddVideo(url, media.name)
                                        dismiss()
                                    } label: {
                                        Label("Add step", systemImage: "plus.circle.fill")
                                    }
                                    .tint(.blue)
                                    .accessibilityIdentifier("browser.controls.mediaPicker.video.\(media.id.uuidString)")
                                }
                            } else {
                                Text("Generate a variant in My Media before adding this image to the sequence.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                thumbnailView(media)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(media.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(media.resolvedKind.label) · \(media.allVariants.count) variant\(media.allVariants.count == 1 ? "" : "s")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Add Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("browser.controls.mediaPicker.cancel")
                }
            }
        }
        .accessibilityIdentifier("browser.controls.mediaPicker")
    }



    private func thumbnailView(_ media: SavedVideo) -> some View {
        Group {
            if let uiImage = videoLibrary.thumbnailImage(for: media) {
                Color(.tertiarySystemFill)
                    .frame(width: 40, height: 30)
                    .overlay {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 40, height: 30)
                    .overlay {
                        Image(systemName: media.isImage ? "photo" : "video")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}
