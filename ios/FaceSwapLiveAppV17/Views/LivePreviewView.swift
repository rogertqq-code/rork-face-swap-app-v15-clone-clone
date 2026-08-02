import SwiftUI
import PhotosUI

struct LivePreviewView: View {
    @State private var viewModel = PreviewViewModel()

    var body: some View {
        ZStack {
            previewLayer
                .ignoresSafeArea()

            if viewModel.showCaptureFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                topBar
                cameraSourceBadge
                Spacer()

                if !viewModel.isActive && !viewModel.isProcessingSource {
                    selectPrompt
                        .padding(.bottom, 32)
                        .transition(.scale.combined(with: .opacity))
                }

                if viewModel.isProcessingSource {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                        .padding(.bottom, 32)
                }

                bottomBar
            }
        }
        .animation(.spring(duration: 0.3), value: viewModel.showCaptureFlash)
        .statusBarHidden()
        .sheet(isPresented: $viewModel.showImageSelection) {
            ImageSelectionSheet { image in
                viewModel.selectSourceImage(image)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $viewModel.showGallery) {
            GalleryView(images: viewModel.capturedImages)
        }
        .alert("No Face Detected", isPresented: $viewModel.showNoResultAlert) {
            Button("OK") {}
        } message: {
            Text("No face was found in the selected photo. Please try a different photo with a clear, front-facing face.")
        }
        .onAppear {
            viewModel.startCapture()
        }
        .onDisappear {
            viewModel.stopCapture()
        }
    }

    private var previewLayer: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if viewModel.hasCameraDevice {
                    MediaPreviewView(session: viewModel.captureService.session)

                    if let overlay = viewModel.overlayImage,
                       viewModel.isActive,
                       viewModel.detectedRect.width > 0 {
                        overlayView(overlay)
                    }

                    if viewModel.showDebugOverlay, viewModel.detectedRect.width > 0 {
                        debugOverlayCanvas
                    }
                } else {
                    simulatorPlaceholder
                }
            }
            .onAppear { viewModel.viewSize = geo.size }
            .onChange(of: geo.size) { _, size in viewModel.viewSize = size }
        }
    }

    private func overlayView(_ overlay: UIImage) -> some View {
        let rect = viewModel.detectedRect
        let expandedWidth = rect.width * 1.8
        let expandedHeight = expandedWidth / viewModel.sourceAspectRatio

        return Image(uiImage: overlay)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: expandedWidth, height: expandedHeight)
            .rotationEffect(.radians(viewModel.roll))
            .position(x: rect.midX, y: rect.midY - rect.height * 0.03)
            .opacity(0.88)
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: rect)
    }

    private var debugOverlayCanvas: some View {
        Canvas { context, _ in
            let rect = viewModel.detectedRect
            let rectPath = Path { p in
                p.addRect(rect)
            }
            context.stroke(rectPath, with: .color(.green), lineWidth: 3)

            for point in viewModel.debugLandmarkScreenPoints {
                let dotPath = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                context.fill(dotPath, with: .color(.red))
            }
        }
        .allowsHitTesting(false)
    }

    private var simulatorPlaceholder: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.white.opacity(0.06))
                    .frame(width: 140, height: 140)

                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: 180, height: 180)

                Image(systemName: "person.2.crop.square.stack.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.7))
                    .symbolEffect(.pulse.byLayer)
            }

            Text("Live Preview")
                .font(.title.bold())
                .foregroundStyle(.white)

            Text("Install this app on your device\nvia the Rork App to use the camera.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            if let selectedImage = viewModel.selectedSourceImage {
                VStack(spacing: 8) {
                    Text("Selected Image")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Image(uiImage: selectedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 2))
                }
                .padding(.top, 8)
                .transition(.scale.combined(with: .opacity))
            }

            if let overlay = viewModel.overlayImage {
                VStack(spacing: 8) {
                    Text("Overlay Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Image(uiImage: overlay)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 120)
                }
                .padding(.top, 4)
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.4), value: viewModel.selectedSourceImage != nil)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if viewModel.isActive {
                Button { viewModel.clearSelection() } label: {
                    Image(systemName: "xmark")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.dsPress)
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            Button {
                viewModel.showDebugOverlay.toggle()
            } label: {
                Image(systemName: viewModel.showDebugOverlay ? "eye.fill" : "eye.slash")
                    .font(.callout.bold())
                    .foregroundStyle(viewModel.showDebugOverlay ? DS.caution : .white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.dsPress)

            Button { viewModel.switchPosition() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.dsPress)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .animation(.spring(duration: 0.25), value: viewModel.isActive)
    }

    /// Compact badge showing which camera (front or back) is currently active.
    /// Sits just below the top bar so it's always visible without obscuring the
    /// preview. Tapping it switches the camera (same as the flip button).
    private var cameraSourceBadge: some View {
        HStack(spacing: 6) {
            if viewModel.isSwitchingCamera {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                    .tint(.white)
            } else {
                Image(systemName: viewModel.isFrontPosition ? "person.crop.circle.fill" : "camera.aperture")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(viewModel.activeCameraName)
                .font(.system(size: 12, weight: .semibold))
            if viewModel.isSwitchingCamera {
                Text("stream #\(viewModel.streamIdentifier)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(viewModel.isSwitchingCamera ? Color.yellow.opacity(0.5) : .white.opacity(0.15), lineWidth: 0.5)
        }
        .onTapGesture {
            viewModel.switchPosition()
            Haptics.selection()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .animation(.spring(duration: 0.3), value: viewModel.activeCameraName)
        .animation(.spring(duration: 0.3), value: viewModel.isFrontPosition)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSwitchingCamera)
    }

    private var selectPrompt: some View {
        Button { viewModel.showImageSelection = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "face.smiling")
                    .symbolEffect(.bounce.byLayer, options: .repeating.speed(0.4))
                Text("Select an Image")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button { viewModel.showImageSelection = true } label: {
                if let overlay = viewModel.overlayImage {
                    Image(uiImage: overlay)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 2))
                } else {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 50, height: 50)
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .buttonStyle(.dsPress)
            .frame(width: 60)

            Spacer()

            Button { viewModel.capture() } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(CaptureButtonStyle())
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.showCaptureFlash)

            Spacer()

            Button { viewModel.showGallery = true } label: {
                if let lastCapture = viewModel.capturedImages.first {
                    Image(uiImage: lastCapture.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(0.4), lineWidth: 2)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                            .frame(width: 50, height: 50)
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.dsPress)
            .frame(width: 60)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

struct CaptureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
    }
}
