import SwiftUI
import PhotosUI
import AVKit

private enum MyMediaTab: String, CaseIterable, Identifiable {
    case all = "All"
    case images = "Images"
    case videos = "Videos"
    case variants = "Variants"

    var id: String { rawValue }
}

struct MyVideosView: View {
    @Environment(DeviceProfileManager.self) private var profileManager
    @State var videoLibrary: VideoLibraryService
    @State private var constraintLog = ConstraintLogService()
    @State private var selectedTab: MyMediaTab = .all
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var isImagePickerPresented: Bool = false
    @State private var isVideoPickerPresented: Bool = false
    @State private var isImporting: Bool = false
    @State private var importProgress: Double = 0
    @State private var importStatus: String = ""
    @State private var mediaToDelete: SavedVideo?
    @State private var showDeleteConfirm: Bool = false
    @State private var selectedMedia: SavedVideo?
    @State private var renamingMedia: SavedVideo?
    @State private var renameText: String = ""

    var onSelectVideo: ((SavedVideo, URL) -> Void)?

    private var filteredMedia: [SavedVideo] {
        switch selectedTab {
        case .all: videoLibrary.videos
        case .images: videoLibrary.videos.filter(\.isImage)
        case .videos: videoLibrary.videos.filter(\.isVideo)
        case .variants: videoLibrary.videos.filter { !$0.allVariants.isEmpty }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if videoLibrary.videos.isEmpty && !isImporting {
                    emptyState
                } else {
                    mediaList
                }
            }
            .navigationTitle("My Media")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isImagePickerPresented = true
                        } label: {
                            Label("Import Image", systemImage: "photo")
                        }
                        .accessibilityIdentifier("media.import.image.menu")
                        Button {
                            isVideoPickerPresented = true
                        } label: {
                            Label("Import Video", systemImage: "video")
                        }
                        .accessibilityIdentifier("media.import.video.menu")
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityIdentifier("media.import.menu")
                    .accessibilityLabel("Add Media")
                    .disabled(isImporting)
                }
            }
        }
        .accessibilityIdentifier("media.screen")
        .accessibilityValue("count=\(videoLibrary.videos.count);filter=\(selectedTab.rawValue);importing=\(isImporting)")
        .photosPicker(isPresented: $isImagePickerPresented, selection: $imagePickerItem, matching: .images)
        .photosPicker(isPresented: $isVideoPickerPresented, selection: $videoPickerItem, matching: .videos)
        .onChange(of: imagePickerItem) { _, item in
            guard let item else { return }
            importImageFromPicker(item)
        }
        .onChange(of: videoPickerItem) { _, item in
            guard let item else { return }
            importVideoFromPicker(item)
        }
        .alert("Delete Media?", isPresented: $showDeleteConfirm, presenting: mediaToDelete) { media in
            Button("Delete", role: .destructive) {
                withAnimation(.spring(duration: 0.3)) {
                    videoLibrary.deleteVideo(media)
                }
            }
            .accessibilityIdentifier("media.delete.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("media.delete.cancel")
        } message: { media in
            Text("This will permanently remove \"\(media.name)\" and all generated variants.")
        }
        .alert("Rename Media", isPresented: .init(
            get: { renamingMedia != nil },
            set: { if !$0 { renamingMedia = nil } }
        )) {
            TextField("Name", text: $renameText)
                .accessibilityIdentifier("media.rename.input")
            Button("Save") {
                if let media = renamingMedia, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    videoLibrary.renameVideo(media, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                renamingMedia = nil
            }
            .accessibilityIdentifier("media.rename.save")
            Button("Cancel", role: .cancel) { renamingMedia = nil }
                .accessibilityIdentifier("media.rename.cancel")
        }
        .onAppear {
            constraintLog.reload()
        }
        .sheet(item: $selectedMedia) { media in
            MediaDetailSheet(
                media: media,
                videoLibrary: videoLibrary,
                profile: profileManager.activeProfile,
                constraintEntries: constraintLog.entries,
                currentURL: nil,
                onUseLegacyVideo: onSelectVideo
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.teal.opacity(0.22), .indigo.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.teal)
            }
            VStack(spacing: 8) {
                Text("No Media Yet")
                    .font(.title3.bold())
                Text("Import images or videos, then generate camera-matched variants for browser and native camera requests.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $imagePickerItem, matching: .images) {
                    Label("Image", systemImage: "photo")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(.teal, in: Capsule())
                }
                .accessibilityIdentifier("media.import.image.empty")
                PhotosPicker(selection: $videoPickerItem, matching: .videos) {
                    Label("Video", systemImage: "video")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(.blue, in: Capsule())
                }
                .accessibilityIdentifier("media.import.video.empty")
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal)
    }

    private var mediaList: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $selectedTab) {
                ForEach(MyMediaTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("media.filter")
            .accessibilityValue(selectedTab.rawValue)
            .padding(.horizontal)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if isImporting { importProgressCard }
                    if filteredMedia.isEmpty {
                        ContentUnavailableView("No \(selectedTab.rawValue)", systemImage: "tray", description: Text("Import media or generate variants to fill this section."))
                            .padding(.top, 40)
                    } else {
                        ForEach(filteredMedia) { media in
                            mediaCard(media)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
    }

    private var importProgressCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ProgressView(value: importProgress)
                    .progressViewStyle(.circular)
                    .tint(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processing Media")
                        .font(.subheadline.weight(.semibold))
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(Int(importProgress * 100))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.teal)
            }
            ProgressView(value: importProgress)
                .tint(.teal)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityIdentifier("media.import.progress")
        .accessibilityValue("progress=\(importProgress);status=\(importStatus)")
    }

    private func mediaCard(_ media: SavedVideo) -> some View {
        Button { selectedMedia = media } label: {
            HStack(spacing: 14) {
                mediaThumbnail(media)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: media.isImage ? "photo" : "video.fill")
                            .foregroundStyle(media.isImage ? .teal : .blue)
                        Text(media.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if media.originalWidth > 0 {
                            Text("\(media.originalWidth)×\(media.originalHeight)")
                        }
                        if media.originalDuration > 0 {
                            Text(formatDuration(media.originalDuration))
                        }
                        Text(formatFileSize(media.fileSizeBytes))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Label("\(media.allVariants.count) variant\(media.allVariants.count == 1 ? "" : "s")", systemImage: "rectangle.stack.fill")
                            .foregroundStyle(.purple)
                        if media.allVariants.contains(where: { $0.sourceGroup == .browserRequest }) {
                            Label("Live URL", systemImage: "globe")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.dsPress)
        .accessibilityIdentifier("media.item.\(media.id.uuidString)")
        .accessibilityValue("name=\(media.name);type=\(media.isImage ? "image" : "video");variants=\(media.allVariants.count)")
        .contextMenu {
            Button {
                renameText = media.name
                renamingMedia = media
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .accessibilityIdentifier("media.item.rename.\(media.id.uuidString)")
            Button(role: .destructive) {
                mediaToDelete = media
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("media.item.delete.\(media.id.uuidString)")
        }
    }

    private func mediaThumbnail(_ media: SavedVideo) -> some View {
        Group {
            if let uiImage = videoLibrary.thumbnailImage(for: media) {
                Color(.tertiarySystemFill)
                    .frame(width: 78, height: 58)
                    .overlay {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 9))
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 78, height: 58)
                    .overlay {
                        Image(systemName: media.isImage ? "photo" : "film")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func importImageFromPicker(_ item: PhotosPickerItem) {
        isImporting = true
        importProgress = 0.1
        importStatus = "Importing image…"
        Task {
            defer { imagePickerItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                resetImportState()
                return
            }
            let _ = await videoLibrary.importImage(data: data, name: "Imported Image")
            resetImportState()
        }
    }

    private func importVideoFromPicker(_ item: PhotosPickerItem) {
        isImporting = true
        importProgress = 0
        importStatus = "Preparing video…"
        Task {
            defer { videoPickerItem = nil }
            guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
                resetImportState()
                return
            }
            let fileName = movie.url.lastPathComponent
            let name = fileName.components(separatedBy: ".").first ?? "Imported Video"
            let _ = await videoLibrary.importVideo(sourceURL: movie.url, name: name, profile: profileManager.activeProfile) { progress, status in
                self.importProgress = progress
                self.importStatus = status
            }
            resetImportState()
        }
    }

    private func resetImportState() {
        withAnimation(.spring(duration: 0.3)) {
            isImporting = false
            importProgress = 0
            importStatus = ""
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct MediaDetailSheet: View {
    let media: SavedVideo
    let videoLibrary: VideoLibraryService
    let profile: DeviceProfile?
    let constraintEntries: [ConstraintLogEntry]
    let currentURL: URL?
    var onUseLegacyVideo: ((SavedVideo, URL) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPresetIDs: Set<String> = []
    @State private var selectedResizeMode: MediaResizeMode = .fillCrop
    @State private var cropRect: NormalizedCropRect = .full
    @State private var customWidth: Int = 1280
    @State private var customHeight: Int = 720
    @State private var customFrameRate: Int = 30
    @State private var customTarget: RequestTarget = .any
    @State private var isGenerating: Bool = false
    @State private var generationProgress: Double = 0
    @State private var generationStatus: String = ""

    private var currentMedia: SavedVideo {
        videoLibrary.videos.first { $0.id == media.id } ?? media
    }

    private var smartPresets: [MediaVariantPreset] {
        SmartMediaPresetService.presets(profile: profile, constraintEntries: constraintEntries, currentURL: currentURL)
    }

    private var selectedPresets: [MediaVariantPreset] {
        var presets = smartPresets.filter { selectedPresetIDs.contains($0.id) }
        if selectedPresetIDs.contains("custom"), customWidth > 0, customHeight > 0, customFrameRate > 0 {
            presets.append(MediaVariantPreset(target: customTarget, width: customWidth, height: customHeight, frameRate: customFrameRate, sourceGroup: .custom, sourceLabel: "Custom"))
        }
        return presets
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    previewSection
                    analysisSection
                    resizeModeSection
                    cropEditorSection
                    presetSection
                    customPresetSection
                    generateSection
                    variantSection
                    detailSection
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .navigationTitle(currentMedia.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var previewSection: some View {
        let media = currentMedia
        return VStack(alignment: .leading, spacing: 10) {
            Label(media.isImage ? "Image Preview" : "Video Preview", systemImage: media.isImage ? "photo" : "video")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if media.isVideo, let url = videoLibrary.mediaURL(for: media) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: 14))
            } else if let image = videoLibrary.thumbnailImage(for: media) {
                Color(.tertiarySystemFill)
                    .frame(height: 220)
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(cropOverlay, alignment: .center)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 220)
            }
        }
    }

    private var cropOverlay: some View {
        GeometryReader { geo in
            Rectangle()
                .stroke(.teal, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .frame(width: geo.size.width * cropRect.width, height: geo.size.height * cropRect.height)
                .position(x: geo.size.width * (cropRect.x + cropRect.width / 2), y: geo.size.height * (cropRect.y + cropRect.height / 2))
        }
        .allowsHitTesting(false)
    }

    private var analysisSection: some View {
        let media = currentMedia
        return Group {
            if let analysis = media.imageAnalysis {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .foregroundStyle(.teal)
                        Text("Intelligent Image Analysis")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(analysis.confidence * 100))%")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.teal)
                    }
                    Text(analysis.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        analysisChip("Faces", analysis.faceCount, color: .cyan)
                        analysisChip("Text", analysis.textRegionCount, color: .orange)
                        analysisChip("Subjects", analysis.humanRegionCount, color: .green)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }
        }
    }

    private func analysisChip(_ label: String, _ value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
    }

    private var resizeModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resize / Crop Mode")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                ForEach(MediaResizeMode.allCases) { mode in
                    Button { selectedResizeMode = mode } label: {
                        Label(mode.label, systemImage: mode.symbolName)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selectedResizeMode == mode ? Color.teal.opacity(0.22) : Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(selectedResizeMode.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cropEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Crop Outline")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Smart Adjust") { smartAdjustCrop() }
                    .font(.caption.weight(.semibold))
            }
            sliderRow("X", value: Binding(get: { cropRect.x }, set: { newValue in
                cropRect.x = max(0, min(newValue, 0.95))
                cropRect.width = max(0.05, min(cropRect.width, 1 - cropRect.x))
            }), range: 0...0.8)
            sliderRow("Y", value: Binding(get: { cropRect.y }, set: { newValue in
                cropRect.y = max(0, min(newValue, 0.95))
                cropRect.height = max(0.05, min(cropRect.height, 1 - cropRect.y))
            }), range: 0...0.8)
            sliderRow("Width", value: Binding(get: { cropRect.width }, set: { cropRect.width = max(0.2, min($0, 1 - cropRect.x)) }), range: 0.2...1)
            sliderRow("Height", value: Binding(get: { cropRect.height }, set: { cropRect.height = max(0.2, min($0, 1 - cropRect.y)) }), range: 0.2...1)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38)
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Smart Presets")
                .font(.subheadline.weight(.semibold))
            ForEach(MediaVariantSourceGroup.allCases) { group in
                let groupPresets = smartPresets.filter { $0.sourceGroup == group }
                if !groupPresets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(groupPresets) { preset in
                                presetButton(preset)
                            }
                        }
                    }
                }
            }
        }
    }

    private func presetButton(_ preset: MediaVariantPreset) -> some View {
        let selected = selectedPresetIDs.contains(preset.id)
        return Button {
            if selected { selectedPresetIDs.remove(preset.id) } else { selectedPresetIDs.insert(preset.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(preset.target.label)
                        .font(.caption2.weight(.bold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                }
                Text(preset.specLabel)
                    .font(.caption.weight(.semibold))
                if preset.responseResult != nil {
                    Text("Requested \(preset.requestedLabel)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(preset.matchLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(preset.confidence >= 0.9 ? .green : .orange)
                        .lineLimit(1)
                } else {
                    Text(preset.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(selected ? Color.blue.opacity(0.2) : Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var customPresetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include Custom Variant", isOn: Binding(
                get: { selectedPresetIDs.contains("custom") },
                set: { enabled in
                    if enabled {
                        selectedPresetIDs.insert("custom")
                    } else {
                        selectedPresetIDs.remove("custom")
                    }
                }
            ))
            Picker("Target", selection: $customTarget) {
                ForEach(RequestTarget.allCases) { target in Text(target.label).tag(target) }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("Width", value: $customWidth, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text("×")
                TextField("Height", value: $customHeight, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                TextField("FPS", value: $customFrameRate, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var generateSection: some View {
        VStack(spacing: 10) {
            if isGenerating {
                ProgressView(value: generationProgress)
                    .tint(.teal)
                Text(generationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { generateSelectedVariants() } label: {
                Label("Generate \(selectedPresets.count) Variant\(selectedPresets.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(selectedPresets.isEmpty || isGenerating ? Color.gray : Color.teal, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.dsPress)
            .disabled(selectedPresets.isEmpty || isGenerating)
        }
    }

    private var variantSection: some View {
        let media = currentMedia
        return VStack(alignment: .leading, spacing: 10) {
            Text("Variant Previews")
                .font(.subheadline.weight(.semibold))
            if media.allVariants.isEmpty {
                Text("No generated variants yet. Pick smart presets above to create camera-ready outputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(media.allVariants) { variant in
                    variantRow(variant)
                }
            }
        }
    }

    private func variantRow(_ variant: SavedMediaVariant) -> some View {
        HStack(spacing: 12) {
            if let image = videoLibrary.variantThumbnailImage(for: variant) {
                Color(.tertiarySystemFill)
                    .frame(width: 74, height: 54)
                    .overlay { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 74, height: 54)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(variant.sourceLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(variant.target.label) · \(variant.specLabel) · \(variant.resizeMode.shortLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let match = variant.responseMatchType {
                    Text("\(match.label) · \(Int((variant.responseConfidence ?? 0) * 100))% confidence")
                        .font(.caption2)
                        .foregroundStyle((variant.responseConfidence ?? 0) >= 0.9 ? .green : .orange)
                    if let rw = variant.requestedWidth, let rh = variant.requestedHeight {
                        Text("Requested \(rw)×\(rh) → Output \(variant.width)×\(variant.height)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(variant.sourceGroup.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if variant.kind == .video,
               let onUseLegacyVideo,
               let url = videoLibrary.variantURL(for: variant) {
                Button {
                    onUseLegacyVideo(currentMedia, url)
                    dismiss()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Use video variant")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var detailSection: some View {
        let media = currentMedia
        return VStack(spacing: 0) {
            detailRow("Original", "\(media.originalWidth)×\(media.originalHeight)")
            Divider().padding(.leading, 16)
            detailRow("Kind", media.resolvedKind.label)
            Divider().padding(.leading, 16)
            detailRow("Imported", media.importedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func smartAdjustCrop() {
        let media = currentMedia
        if let analysis = media.imageAnalysis {
            cropRect = analysis.suggestedCrop
            return
        }
        let isPortrait = media.originalHeight > media.originalWidth
        cropRect = isPortrait
            ? NormalizedCropRect(x: 0.08, y: 0.05, width: 0.84, height: 0.86)
            : NormalizedCropRect(x: 0.12, y: 0.08, width: 0.76, height: 0.82)
    }

    private func generateSelectedVariants() {
        let presets = selectedPresets
        guard !presets.isEmpty else { return }
        isGenerating = true
        generationProgress = 0
        generationStatus = "Starting…"
        Task {
            for (index, preset) in presets.enumerated() {
                let base = Double(index) / Double(presets.count)
                let span = 1.0 / Double(presets.count)
                _ = await videoLibrary.generateVariant(for: currentMedia, preset: preset, resizeMode: selectedResizeMode, cropRect: cropRect, profile: profile) { progress, status in
                    generationProgress = base + progress * span
                    generationStatus = status
                }
            }
            isGenerating = false
            generationProgress = 0
            generationStatus = ""
            selectedPresetIDs.removeAll()
        }
    }
}
