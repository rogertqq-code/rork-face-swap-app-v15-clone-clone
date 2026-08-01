import AVFoundation
import Foundation
import WebRTC

nonisolated enum NativeWebRTCSDPType: String, Codable, Sendable, Hashable {
    case offer
    case answer
    case provisionalAnswer

    fileprivate init(_ type: RTCSdpType) {
        switch type {
        case .offer: self = .offer
        case .answer: self = .answer
        case .prAnswer: self = .provisionalAnswer
        @unknown default: self = .offer
        }
    }

    fileprivate var rtcType: RTCSdpType {
        switch self {
        case .offer: .offer
        case .answer: .answer
        case .provisionalAnswer: .prAnswer
        }
    }
}

nonisolated struct NativeWebRTCSessionDescription: Codable, Sendable, Hashable {
    var type: NativeWebRTCSDPType
    var sdp: String

    init(type: NativeWebRTCSDPType, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    fileprivate init(_ description: RTCSessionDescription) {
        self.type = NativeWebRTCSDPType(description.type)
        self.sdp = description.sdp
    }

    fileprivate var rtcDescription: RTCSessionDescription {
        RTCSessionDescription(type: type.rtcType, sdp: sdp)
    }
}

nonisolated struct NativeWebRTCIceCandidate: Codable, Sendable, Hashable {
    var sdp: String
    var sdpMLineIndex: Int32
    var sdpMid: String?

    init(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }

    fileprivate init(_ candidate: RTCIceCandidate) {
        self.sdp = candidate.sdp
        self.sdpMLineIndex = candidate.sdpMLineIndex
        self.sdpMid = candidate.sdpMid
    }

    fileprivate var rtcCandidate: RTCIceCandidate {
        RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}

nonisolated struct NativeWebRTCStartResult: Codable, Sendable, Hashable {
    var offer: NativeWebRTCSessionDescription
    var audioOutcome: MediaAudioOutcome
}

nonisolated enum NativeWebRTCSignalKind: String, Codable, Sendable, Hashable {
    case localCandidate
    case iceConnectionState
    case peerConnectionState
    case signalingState
    case negotiationNeeded
    case closed
    case failed
}

nonisolated struct NativeWebRTCSignalEvent: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var requestID: UUID
    var kind: NativeWebRTCSignalKind
    var candidate: NativeWebRTCIceCandidate?
    var state: String?
    var detail: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        requestID: UUID,
        kind: NativeWebRTCSignalKind,
        candidate: NativeWebRTCIceCandidate? = nil,
        state: String? = nil,
        detail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.candidate = candidate
        self.state = state
        self.detail = detail
        self.timestamp = timestamp
    }
}

nonisolated final class NativeWebRTCSession: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    typealias EventSink = @Sendable (NativeWebRTCSignalEvent) -> Void

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    let requestID: UUID

    private let peerConnection: RTCPeerConnection
    private let videoSource: RTCVideoSource
    private let videoCapturer: RTCVideoCapturer
    private let localVideoTrack: RTCVideoTrack
    private let localAudioTrack: RTCAudioTrack?
    private let eventSink: EventSink
    private let stateLock = NSLock()
    private var closed = false

    init(
        requestID: UUID,
        dimensions: MediaDimensions? = nil,
        frameRate: Double? = nil,
        includeRealAudio: Bool,
        eventSink: @escaping EventSink
    ) throws {
        self.requestID = requestID
        self.eventSink = eventSink

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = []

        let peerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        guard let peerConnection = Self.factory.peerConnection(
            with: configuration,
            constraints: peerConstraints,
            delegate: nil
        ) else {
            throw MediaDeliveryContractError.signalingFailed("The native peer connection could not be created.")
        }
        self.peerConnection = peerConnection

        let videoSource = Self.factory.videoSource()
        if let dimensions {
            videoSource.adaptOutputFormat(
                toWidth: Int32(dimensions.width),
                height: Int32(dimensions.height),
                fps: Int32(max(1, Int(frameRate ?? 30)))
            )
        }
        self.videoSource = videoSource
        self.videoCapturer = RTCVideoCapturer(delegate: videoSource)
        self.localVideoTrack = Self.factory.videoTrack(
            with: videoSource,
            trackId: "fsl-native-video-\(requestID.uuidString)"
        )

        if includeRealAudio {
            let audioSource = Self.factory.audioSource(
                with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            self.localAudioTrack = Self.factory.audioTrack(
                with: audioSource,
                trackId: "fsl-native-audio-\(requestID.uuidString)"
            )
        } else {
            self.localAudioTrack = nil
        }

        super.init()

        let streamID = "fsl-native-stream-\(requestID.uuidString)"
        peerConnection.add(localVideoTrack, streamIds: [streamID])
        if let localAudioTrack {
            peerConnection.add(localAudioTrack, streamIds: [streamID])
        }
        peerConnection.delegate = self
    }

    func makeOffer() async throws -> NativeWebRTCSessionDescription {
        try ensureOpen()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        let offer = try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: MediaDeliveryContractError.signalingFailed(error.localizedDescription))
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: MediaDeliveryContractError.signalingFailed("The native peer returned no SDP offer."))
                }
            }
        }
        try await setLocalDescription(offer)
        return NativeWebRTCSessionDescription(offer)
    }

    func setRemoteDescription(_ description: NativeWebRTCSessionDescription) async throws {
        try ensureOpen()
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.setRemoteDescription(description.rtcDescription) { error in
                if let error {
                    continuation.resume(throwing: MediaDeliveryContractError.signalingFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func addRemoteCandidate(_ candidate: NativeWebRTCIceCandidate) async throws {
        try ensureOpen()
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.add(candidate.rtcCandidate) { error in
                if let error {
                    continuation.resume(throwing: MediaDeliveryContractError.signalingFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func push(
        sampleBuffer: CMSampleBuffer,
        rotation: RTCVideoRotation = ._0
    ) throws {
        try ensureOpen()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw MediaDeliveryContractError.deliveryFailed("The AVFoundation frame did not contain a pixel buffer.")
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNanoseconds: Int64
        if presentationTime.isValid && !presentationTime.isIndefinite {
            timestampNanoseconds = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
        } else {
            timestampNanoseconds = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        }
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: rotation,
            timeStampNs: timestampNanoseconds
        )
        videoSource.capturer(videoCapturer, didCapture: frame)
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()

        localVideoTrack.isEnabled = false
        localAudioTrack?.isEnabled = false
        peerConnection.close()
        emit(kind: .closed, state: "closed")
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: MediaDeliveryContractError.signalingFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func ensureOpen() throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        if isClosed {
            throw MediaDeliveryContractError.cancelled("The native WebRTC session is already closed.")
        }
    }

    private func emit(
        kind: NativeWebRTCSignalKind,
        candidate: NativeWebRTCIceCandidate? = nil,
        state: String? = nil,
        detail: String? = nil
    ) {
        eventSink(NativeWebRTCSignalEvent(
            requestID: requestID,
            kind: kind,
            candidate: candidate,
            state: state,
            detail: detail
        ))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        emit(kind: .signalingState, state: String(describing: stateChanged))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        emit(kind: .negotiationNeeded)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        emit(kind: .iceConnectionState, state: String(describing: newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        emit(kind: .localCandidate, candidate: NativeWebRTCIceCandidate(candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        emit(kind: .peerConnectionState, state: String(describing: newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
}
