import AVFoundation
import UIKit

@globalActor
actor CaptureSessionActor {
    static let shared = CaptureSessionActor()
    
    nonisolated let unownedExecutor: UnownedSerialExecutor
    let queue: DispatchQueue
    
    init() {
        let q = DispatchQueue(label: "com.app.capturesession")
        self.queue = q
        self.unownedExecutor = q.asUnownedSerialExecutor()
    }
}

nonisolated final class CaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError, Sendable {
        case permissionDenied
        case cameraUnavailable
        case configurationFailed
        case captureInProgress
        case captureCancelled
        case captureTimedOut
        case invalidPhotoData
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Camera access is denied. Enable it in Settings to capture a photo."
            case .cameraUnavailable:
                return "No camera is available on this device."
            case .configurationFailed:
                return "The camera could not be configured for photo capture."
            case .captureInProgress:
                return "A photo capture is already in progress."
            case .captureCancelled:
                return "The photo capture was cancelled."
            case .captureTimedOut:
                return "The camera did not return a photo in time. Try again."
            case .invalidPhotoData:
                return "The camera returned an unreadable photo."
            case .captureFailed(let message):
                return "Photo capture failed: \(message)"
            }
        }
    }

    let session = AVCaptureSession()

    private let videoQueue = DispatchQueue(label: "com.app.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let positionLock = NSLock()
    private let completionLock = NSLock()

    private var _currentPosition: AVCaptureDevice.Position = .back
    private var photoCompletion: ((Result<UIImage, CaptureError>) -> Void)?
    private var activePhotoID: Int64?
    private var photoTimeoutWorkItem: DispatchWorkItem?

    private var _rotationCoordinator: Any?

    @available(iOS 17.0, *)
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator? {
        _rotationCoordinator as? AVCaptureDevice.RotationCoordinator
    }

    var videoRotationAngle: CGFloat {
        if #available(iOS 17.0, *), let rc = rotationCoordinator {
            return rc.videoRotationAngleForHorizonLevelCapture
        }
        return 0
    }

    private var interruptionObserver: NSObjectProtocol?
    private var interruptionEndedObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?

    override init() {
        super.init()
        let nc = NotificationCenter.default
        interruptionObserver = nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.handleInterruption()
        }
        interruptionEndedObserver = nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.handleInterruptionEnded()
        }
        runtimeErrorObserver = nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
            self?.handleRuntimeError(notification)
        }
    }

    deinit {
        let nc = NotificationCenter.default
        if let obs = interruptionObserver { nc.removeObserver(obs) }
        if let obs = interruptionEndedObserver { nc.removeObserver(obs) }
        if let obs = runtimeErrorObserver { nc.removeObserver(obs) }
        // Ensure the capture session is stopped and the hardware lease is
        // released even if the caller never invoked stop(). deinit is
        // synchronous so we dispatch to the session queue and fire-and-forget
        // the async lease release — both are best-effort cleanup.
        let captureSession = session
        CaptureSessionActor.shared.queue.async {
            if captureSession.isRunning { captureSession.stopRunning() }
        }
        Task { await MediaResourceCoordinator.shared.releaseLease(for: "CaptureService") }
    }

    private func handleInterruption() {
        cancelActivePhotoCapture()
    }
    
    private func handleInterruptionEnded() {
        Task {
            try? await configureAndStartSession()
        }
    }
    
    private func handleRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        if error.code == .mediaServicesWereReset {
            Task {
                try? await configureAndStartSession()
            }
        }
    }

    var currentPosition: AVCaptureDevice.Position {
        positionLock.lock()
        defer { positionLock.unlock() }
        return _currentPosition
    }

    var currentCameraName: String {
        let position = currentPosition
        let device = cameraDevice(for: position)
        if let device, !device.localizedName.isEmpty {
            return device.localizedName
        }
        switch position {
        case .front: return "Front Camera"
        case .back: return "Back Camera"
        default: return "Camera"
        }
    }

    private let callbackLock = NSLock()
    private var _onFrame: ((CMSampleBuffer) -> Void)?
    var onFrame: ((CMSampleBuffer) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onFrame
        }
        set {
            callbackLock.lock()
            _onFrame = newValue
            callbackLock.unlock()
        }
    }

    static var isCameraAvailable: Bool {
        !availableCameraDevices().isEmpty
    }

    func start() async throws {
        let granted = await withCheckedContinuation { continuation in
            requestVideoAccess { granted in continuation.resume(returning: granted) }
        }
        guard granted else { throw CaptureError.permissionDenied }
        await MediaResourceCoordinator.shared.acquireLease(for: "CaptureService")
        await configureAndStartSession()
    }

    func stop() async {
        await stopSession()
        await MediaResourceCoordinator.shared.releaseLease(for: "CaptureService")
    }

    func switchPosition() {
        positionLock.lock()
        _currentPosition = (_currentPosition == .front) ? .back : .front
        let newPosition = _currentPosition
        positionLock.unlock()
        
        Task {
            try? await configureAndStartSession()
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onPositionChanged?(newPosition)
        }
    }

    private var _onPositionChanged: ((AVCaptureDevice.Position) -> Void)?
    var onPositionChanged: ((AVCaptureDevice.Position) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onPositionChanged
        }
        set {
            callbackLock.lock()
            _onPositionChanged = newValue
            callbackLock.unlock()
        }
    }

    func capturePhoto(completion: @escaping (Result<UIImage, CaptureError>) -> Void) {
        requestVideoAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    completion(.failure(.permissionDenied))
                }
                return
            }

            Task {
                await self.performPhotoCapture(completion: completion)
            }
        }
    }
    
    @CaptureSessionActor
    private func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
        cancelActivePhotoCapture()
    }
    
    @CaptureSessionActor
    private func performPhotoCapture(completion: @escaping (Result<UIImage, CaptureError>) -> Void) {
        guard configureSessionSync(), photoOutput.connection(with: .video) != nil else {
            DispatchQueue.main.async {
                completion(.failure(.configurationFailed))
            }
            return
        }

        completionLock.lock()
        guard photoCompletion == nil else {
            completionLock.unlock()
            DispatchQueue.main.async {
                completion(.failure(.captureInProgress))
            }
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        activePhotoID = settings.uniqueID
        photoCompletion = completion
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishPhotoCapture(.failure(.captureTimedOut), id: settings.uniqueID)
        }
        photoTimeoutWorkItem = timeout
        completionLock.unlock()

        CaptureSessionActor.shared.queue.asyncAfter(deadline: .now() + .seconds(12), execute: timeout)
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @CaptureSessionActor
    private func configureAndStartSession() throws {
        guard configureSessionSync() else { throw CaptureError.cameraUnavailable }
        if !session.isRunning {
            session.startRunning()
        }
    }

    @CaptureSessionActor
    private func configureSessionSync() -> Bool {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        if !session.outputs.contains(where: { $0 === videoOutput }) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { return false }
            session.addOutput(videoOutput)
        }

        if !session.outputs.contains(where: { $0 === photoOutput }) {
            guard session.canAddOutput(photoOutput) else { return false }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        session.sessionPreset = .photo

        let targetDevice = cameraDevice(for: currentPosition)
        let currentInput = session.inputs.first as? AVCaptureDeviceInput
        
        if let currentInput, currentInput.device == targetDevice {
            return true
        }
        
        for input in session.inputs {
            session.removeInput(input)
        }

        guard let device = targetDevice,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }
        session.addInput(input)
        
        if #available(iOS 17.0, *) {
            _rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
        
        return true
    }

    private func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = Self.availableCameraDevices()
        return devices.first(where: { $0.position == position }) ?? devices.first
    }

    private static func availableCameraDevices() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 17.0, *) {
            deviceTypes.append(.external)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func requestVideoAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func cancelActivePhotoCapture() {
        completionLock.lock()
        let activeID = activePhotoID
        completionLock.unlock()
        guard let activeID else { return }
        finishPhotoCapture(.failure(.captureCancelled), id: activeID)
    }

    private func finishPhotoCapture(_ result: Result<UIImage, CaptureError>, id: Int64) {
        completionLock.lock()
        guard activePhotoID == id, let completion = photoCompletion else {
            completionLock.unlock()
            return
        }
        activePhotoID = nil
        photoCompletion = nil
        photoTimeoutWorkItem?.cancel()
        photoTimeoutWorkItem = nil
        completionLock.unlock()

        DispatchQueue.main.async {
            completion(result)
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame?(sampleBuffer)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let captureID = photo.resolvedSettings.uniqueID
        if let error {
            finishPhotoCapture(.failure(.captureFailed(error.localizedDescription)), id: captureID)
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            finishPhotoCapture(.failure(.invalidPhotoData), id: captureID)
            return
        }
        finishPhotoCapture(.success(image), id: captureID)
    }
}
