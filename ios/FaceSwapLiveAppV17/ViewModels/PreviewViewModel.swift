import SwiftUI
import AVFoundation

@Observable
@MainActor
final class PreviewViewModel {
    var overlayImage: UIImage?
    var selectedSourceImage: UIImage?
    var detectedRect: CGRect = .zero
    var roll: CGFloat = 0
    var sourceAspectRatio: CGFloat = 1.0
    var isActive: Bool = false
    var isProcessingSource: Bool = false
    var showImageSelection: Bool = false
    var showGallery: Bool = false
    var showNoResultAlert: Bool = false
    var showCaptureFlash: Bool = false
    var capturedImages: [CapturedImage] = []
    var viewSize: CGSize = .zero
    var isFrontPosition: Bool = false
    var showDebugOverlay: Bool = false
    var debugLandmarkScreenPoints: [CGPoint] = []
    /// Human-readable name of the active camera source, updated on switch.
    var activeCameraName: String = "Back Camera"

    let captureService = CaptureService()
    private let processor = ImageProcessor()
    /// Frame-loop state shared between the camera queue and the main actor.
    /// Its internal lock removes the data race the three loose
    /// `nonisolated(unsafe)` vars used to have, and guarantees the in-flight
    /// gate is always released.
    nonisolated private let frameState = FrameLoopState()

    func startCapture() {
        let processor = self.processor

        captureService.onFrame = { [weak self] buffer in
            guard let self else { return }
            // Atomically claim the in-flight slot; drop this frame if busy.
            guard self.frameState.beginFrameIfIdle() else { return }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                self.frameState.endFrame()
                return
            }

            let isFront = self.captureService.currentPosition == .front
            let result = processor.detectFeatures(in: pixelBuffer, isFrontPosition: isFront)

            if let result {
                self.frameState.bufferSize = CGSize(
                    width: CGFloat(result.bufferWidth),
                    height: CGFloat(result.bufferHeight)
                )
            }

            var capturedImage: UIImage?
            if let ctx = self.frameState.takePendingCapture() {
                capturedImage = processor.compositeCapture(pixelBuffer: pixelBuffer, context: ctx)
            }

            // Release the gate as soon as the heavy work on this queue is done,
            // so a delayed main-actor hop can never permanently freeze frames.
            self.frameState.endFrame()

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.detectedRect = self.convertToScreen(
                        result.boundingBox,
                        bufferWidth: result.bufferWidth,
                        bufferHeight: result.bufferHeight
                    )
                    self.roll = result.roll
                    self.debugLandmarkScreenPoints = result.landmarkPoints.map { point in
                        self.convertPointToScreen(point, bufferWidth: result.bufferWidth, bufferHeight: result.bufferHeight)
                    }
                } else {
                    self.detectedRect = .zero
                    self.roll = 0
                    self.debugLandmarkScreenPoints = []
                }
                if let captured = capturedImage {
                    self.capturedImages.insert(CapturedImage(image: captured), at: 0)
                }
            }
        }

        captureService.onPositionChanged = { [weak self] newPosition in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFrontPosition = (newPosition == .front)
                self.activeCameraName = self.captureService.currentCameraName
            }
        }

        // Sync the initial camera name and position state.
        isFrontPosition = (captureService.currentPosition == .front)
        activeCameraName = captureService.currentCameraName

        captureService.start()
    }

    func stopCapture() {
        captureService.stop()
    }

    func selectSourceImage(_ image: UIImage) {
        selectedSourceImage = image
        isProcessingSource = true
        let proc = self.processor

        Task.detached {
            let result = proc.processSourceImage(image)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessingSource = false
                if let result {
                    self.overlayImage = result.overlay
                    self.sourceAspectRatio = result.aspectRatio
                    self.isActive = true
                } else {
                    self.showNoResultAlert = true
                    self.isActive = false
                }
                self.showImageSelection = false
            }
        }
    }

    func clearSelection() {
        overlayImage = nil
        selectedSourceImage = nil
        isActive = false
        detectedRect = .zero
    }

    func capture() {
        guard let overlay = overlayImage else { return }
        // A composite needs a real camera frame (non-zero buffer) and a laid-out
        // view; without both the geometry is nonsensical, so ignore the tap.
        let bufferSize = frameState.bufferSize
        guard bufferSize != .zero, viewSize != .zero else { return }
        frameState.setPendingCapture(CaptureContext(
            overlayImage: overlay,
            overlayRect: detectedRect,
            viewSize: viewSize,
            bufferSize: bufferSize,
            isFrontPosition: isFrontPosition,
            sourceAspectRatio: sourceAspectRatio
        ))

        showCaptureFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            showCaptureFlash = false
        }
    }

    func switchPosition() {
        isFrontPosition.toggle()
        captureService.switchPosition()
        activeCameraName = captureService.currentCameraName
    }

    private func convertToScreen(_ visionRect: CGRect, bufferWidth: Int, bufferHeight: Int) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let bw = CGFloat(bufferWidth)
        let bh = CGFloat(bufferHeight)
        guard bw > 0, bh > 0 else { return .zero }

        let videoAspect = bw / bh
        let viewAspect = viewSize.width / viewSize.height

        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if videoAspect > viewAspect {
            scale = viewSize.height / bh
            offsetX = (bw * scale - viewSize.width) / 2
            offsetY = 0
        } else {
            scale = viewSize.width / bw
            offsetX = 0
            offsetY = (bh * scale - viewSize.height) / 2
        }

        let pixelX = visionRect.origin.x * bw
        let pixelY = (1 - visionRect.origin.y - visionRect.height) * bh
        let pixelW = visionRect.width * bw
        let pixelH = visionRect.height * bh

        return CGRect(
            x: pixelX * scale - offsetX,
            y: pixelY * scale - offsetY,
            width: pixelW * scale,
            height: pixelH * scale
        )
    }

    private func convertPointToScreen(_ point: CGPoint, bufferWidth: Int, bufferHeight: Int) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let bw = CGFloat(bufferWidth)
        let bh = CGFloat(bufferHeight)
        guard bw > 0, bh > 0 else { return .zero }

        let videoAspect = bw / bh
        let viewAspect = viewSize.width / viewSize.height

        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if videoAspect > viewAspect {
            scale = viewSize.height / bh
            offsetX = (bw * scale - viewSize.width) / 2
            offsetY = 0
        } else {
            scale = viewSize.width / bw
            offsetX = 0
            offsetY = (bh * scale - viewSize.height) / 2
        }

        let pixelX = point.x * bw
        let pixelY = (1 - point.y) * bh

        return CGPoint(
            x: pixelX * scale - offsetX,
            y: pixelY * scale - offsetY
        )
    }
}

/// Thread-safe holder for the preview frame loop's shared mutable state. Every
/// stored property is only ever read or written under `lock`, so the camera
/// queue and the main actor can touch it concurrently without a data race —
/// which is why `@unchecked Sendable` is sound here.
private final class FrameLoopState: @unchecked Sendable {
    private let lock = NSLock()
    private var _processing = false
    private var _bufferSize: CGSize = .zero
    private var _pendingCapture: CaptureContext?

    /// Claims the in-flight slot if idle; returns false when a frame is already
    /// being processed so the caller drops the frame.
    func beginFrameIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _processing { return false }
        _processing = true
        return true
    }

    func endFrame() {
        lock.lock()
        _processing = false
        lock.unlock()
    }

    var bufferSize: CGSize {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _bufferSize
        }
        set {
            lock.lock()
            _bufferSize = newValue
            lock.unlock()
        }
    }

    func setPendingCapture(_ context: CaptureContext?) {
        lock.lock()
        _pendingCapture = context
        lock.unlock()
    }

    /// Returns and clears any armed capture request in one atomic step.
    func takePendingCapture() -> CaptureContext? {
        lock.lock()
        defer { lock.unlock() }
        let context = _pendingCapture
        _pendingCapture = nil
        return context
    }
}
