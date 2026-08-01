import AVFoundation
import Foundation
import WebRTC

actor NativeWebRTCBridgeCoordinator: MediaDeliveryCancelling {
    struct ActiveSession: @unchecked Sendable {
        let request: MediaDeliveryRequest
        let captureService: CaptureService
        let peerSession: NativeWebRTCSession
    }

    typealias SignalSink = @Sendable (NativeWebRTCSignalEvent) -> Void

    private var sessions: [UUID: ActiveSession] = [:]
    private let eventRecorder: (any MediaDeliveryEventRecording)?
    private let telemetryStore: MediaDeliveryTelemetryStore
    private let rawSampleSelector: MediaRawSampleSelector
    private let signalSink: SignalSink

    init(
        eventRecorder: (any MediaDeliveryEventRecording)? = MediaDeliveryTelemetryStore.shared,
        telemetryStore: MediaDeliveryTelemetryStore = .shared,
        rawSampleSelector: MediaRawSampleSelector = .shared,
        signalSink: @escaping SignalSink
    ) {
        self.eventRecorder = eventRecorder
        self.telemetryStore = telemetryStore
        self.rawSampleSelector = rawSampleSelector
        self.signalSink = signalSink
    }

    func startNativeCameraSession(
        for request: MediaDeliveryRequest
    ) async throws -> NativeWebRTCStartResult {
        guard request.kind == .webRTC else {
            throw MediaDeliveryContractError.invalidRequest("A native WebRTC session requires a WebRTC request.")
        }
        guard request.constraints.wantsVideo else {
            throw MediaDeliveryContractError.invalidRequest("A native camera session requires video constraints.")
        }
        guard Date() < request.deadline else {
            throw MediaDeliveryContractError.timedOut
        }
        guard sessions[request.id] == nil else {
            throw MediaDeliveryContractError.invalidRequest("The request already owns a native WebRTC session.")
        }

        await record(request: request, stage: .sourceResolving, detail: "Preparing native camera and WebRTC sender.")

        let captureService = CaptureService()
        switch request.constraints.facingMode {
        case .user:
            captureService.preparePosition(.front)
        case .environment:
            captureService.preparePosition(.back)
        case .unspecified:
            break
        }

        let audioDecision = try await MediaAudioPolicyResolver.resolve(
            wantsAudio: request.constraints.wantsAudio,
            policy: request.constraints.audioPolicy
        )

        rawSampleSelector.configure(requestID: request.id, mode: request.rawSampleMode)
        let peerSession = try NativeWebRTCSession(
            requestID: request.id,
            dimensions: request.constraints.dimensions,
            frameRate: request.constraints.frameRate,
            includeRealAudio: audioDecision.includeRealMicrophoneTrack
        ) { [signalSink] event in
            signalSink(event)
        }

        let requestID = request.id
        let selector = rawSampleSelector
        let telemetry = telemetryStore
        captureService.onFrame = { [weak captureService, weak peerSession] sampleBuffer in
            guard let captureService, let peerSession else { return }
            do {
                try peerSession.push(
                    sampleBuffer: sampleBuffer,
                    rotation: Self.rotation(for: captureService.videoRotationAngle)
                )
            } catch {
                // A single malformed frame is dropped; request lifecycle telemetry
                // continues to report the peer and capture-session state.
            }
            if let sample = selector.captureIfSelected(requestID: requestID, sampleBuffer: sampleBuffer) {
                Task { try? await telemetry.recordRawSample(sample) }
            }
        }

        let active = ActiveSession(
            request: request,
            captureService: captureService,
            peerSession: peerSession
        )
        sessions[request.id] = active

        do {
            try await captureService.start()
            await record(
                request: request,
                stage: .sourceReady,
                sourceKind: .nativeCamera,
                detail: "Native camera frames are connected to the WebRTC video source.",
                metadata: [
                    "facingMode": request.constraints.facingMode.rawValue,
                    "width": String(request.constraints.dimensions?.width ?? 0),
                    "height": String(request.constraints.dimensions?.height ?? 0),
                    "frameRate": String(request.constraints.frameRate ?? 0),
                    "rawSampleMode": request.rawSampleMode.kind.rawValue,
                    "rawSampleInterval": request.rawSampleMode.interval.map(String.init) ?? "",
                ]
            )
            let offer = try await peerSession.makeOffer()
            let stage: MediaDeliveryStage = audioDecision.outcome.kind == .silentFallback ? .degraded : .signaling
            await record(
                request: request,
                stage: stage,
                audioOutcome: audioDecision.outcome,
                detail: audioDecision.outcome.reason ?? "Native SDP offer created."
            )
            return NativeWebRTCStartResult(offer: offer, audioOutcome: audioDecision.outcome)
        } catch {
            sessions.removeValue(forKey: request.id)
            rawSampleSelector.remove(requestID: request.id)
            captureService.onFrame = nil
            peerSession.close()
            await captureService.stop()
            await record(
                request: request,
                stage: .failed,
                terminalReason: .failed,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    func setPageAnswer(
        _ answer: NativeWebRTCSessionDescription,
        requestID: UUID
    ) async throws {
        guard answer.type == .answer || answer.type == .provisionalAnswer else {
            throw MediaDeliveryContractError.signalingFailed("The page response was not an SDP answer.")
        }
        guard let active = sessions[requestID] else {
            throw MediaDeliveryContractError.cancelled("No active native WebRTC session exists for this request.")
        }
        try await active.peerSession.setRemoteDescription(answer)
        await record(request: active.request, stage: .delivering, detail: "Page SDP answer applied.")
    }

    func addPageCandidate(
        _ candidate: NativeWebRTCIceCandidate,
        requestID: UUID
    ) async throws {
        guard let active = sessions[requestID] else {
            throw MediaDeliveryContractError.cancelled("No active native WebRTC session exists for this request.")
        }
        try await active.peerSession.addRemoteCandidate(candidate)
    }

    func markActive(requestID: UUID) async {
        guard let active = sessions[requestID] else { return }
        await record(request: active.request, stage: .active, detail: "Native media track is active in the page peer connection.")
    }

    func cancel(
        requestID: UUID,
        reason: MediaDeliveryTerminalReason
    ) async {
        guard let active = sessions.removeValue(forKey: requestID) else { return }
        await record(request: active.request, stage: .cancelling, terminalReason: reason)
        active.captureService.onFrame = nil
        rawSampleSelector.remove(requestID: requestID)
        active.peerSession.close()
        await active.captureService.stop()
        await record(request: active.request, stage: .cancelled, terminalReason: reason)
    }

    func stop(requestID: UUID) async {
        guard let active = sessions.removeValue(forKey: requestID) else { return }
        active.captureService.onFrame = nil
        rawSampleSelector.remove(requestID: requestID)
        active.peerSession.close()
        await active.captureService.stop()
        await record(request: active.request, stage: .stopped, terminalReason: .callerStopped)
    }

    func stopAll(reason: MediaDeliveryTerminalReason) async {
        for requestID in Array(sessions.keys) {
            await cancel(requestID: requestID, reason: reason)
        }
    }

    func activeRequestIDs() -> Set<UUID> {
        Set(sessions.keys)
    }

    private func record(
        request: MediaDeliveryRequest,
        stage: MediaDeliveryStage,
        sourceKind: MediaDeliverySourceKind? = nil,
        audioOutcome: MediaAudioOutcome? = nil,
        terminalReason: MediaDeliveryTerminalReason? = nil,
        detail: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        guard let eventRecorder else { return }
        await eventRecorder.record(MediaDeliveryTraceEvent(
            requestID: request.id,
            navigationSessionID: request.navigationSessionID,
            origin: request.origin,
            stage: stage,
            sourceKind: sourceKind,
            audioOutcome: audioOutcome,
            terminalReason: terminalReason,
            detail: detail,
            metadata: metadata
        ))
    }

    nonisolated private static func rotation(for angle: CGFloat) -> RTCVideoRotation {
        let normalized = Int(angle.rounded()) % 360
        switch normalized {
        case 45..<135: return ._90
        case 135..<225: return ._180
        case 225..<315: return ._270
        default: return ._0
        }
    }
}
