import Foundation
import AVFoundation
import UIKit
import CoreImage
import WebKit

@Observable
@MainActor
final class DiagnosticsService {

    var driftReport: DriftReport?
    var driftStatus: String?
    /// Which feed engine actually engaged for the live stream (clean track vs
    /// Canvas) and whether/why it downgraded. Set whenever the injected stream is
    /// read, even if there aren't enough frames yet for a full drift report.
    var feedEngine: FeedEngineStatus?
    var isMeasuringDrift: Bool = false
    var audioRouteProfile: AudioRouteProfile?
    var isMonitoring: Bool = false

    // MARK: - Audio Route Profile

    func captureAudioRouteProfile() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        let inputName = route.inputs.first?.portName ?? "none"
        let sampleRate = session.sampleRate
        let channelCount = session.inputNumberOfChannels
        let ioBufferDuration = session.ioBufferDuration
        let mode = session.mode

        let echoCancellation = (mode == .voiceChat || mode == .videoChat)

        audioRouteProfile = AudioRouteProfile(
            inputRoute: inputName,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: 16,
            echoCancellation: echoCancellation,
            audioSessionMode: mode.rawValue,
            ioBufferDuration: ioBufferDuration
        )
    }

    // MARK: - Drift Report (live injected stream)

    /// Reads the real frame-delivery timestamps the injection engine records for
    /// the stream the current site receives, then computes cadence statistics.
    /// Falls back to a friendly status when no injected stream is live.
    func generateDriftReport() async {
        isMeasuringDrift = true
        defer { isMeasuringDrift = false }

        guard let webView = InjectionStreamRegistry.shared.activeWebView else {
            driftReport = nil
            feedEngine = nil
            driftStatus = "No browser stream found. Open the Browser tab and turn on Enable Media first."
            return
        }

        let evaluation = try? await webView.callAsyncJavaScript(
            StyleSheetProvider.injectedFrameTimingBody,
            arguments: [:],
            contentWorld: .page
        )

        guard let jsonString = evaluation as? String,
              let data = jsonString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            driftReport = nil
            feedEngine = nil
            driftStatus = "Couldn't read the injected stream from the page. Reload the site and try again."
            return
        }

        let active = (raw["active"] as? Bool) ?? ((raw["active"] as? NSNumber)?.boolValue ?? false)
        let armed = (raw["armed"] as? Bool) ?? ((raw["armed"] as? NSNumber)?.boolValue ?? true)
        let armError = raw["armError"] as? String ?? ""
        // Record which feed engine engaged regardless of whether timing is ready,
        // so the readout can show clean-vs-Canvas, any downgrade reason, and
        // whether the camera takeover is genuinely armed.
        feedEngine = FeedEngineStatus(
            active: active,
            method: raw["method"] as? String ?? "",
            feed: raw["feed"] as? String ?? "",
            lane: raw["lane"] as? String ?? "",
            intended: raw["intended"] as? String ?? "",
            downgraded: (raw["downgraded"] as? Bool) ?? ((raw["downgraded"] as? NSNumber)?.boolValue ?? false),
            reason: raw["reason"] as? String ?? "",
            armed: armed,
            armError: armError,
            sensorRealismEnabled: (raw["sensorRealism"] as? Bool) ?? ((raw["sensorRealism"] as? NSNumber)?.boolValue ?? false),
            sensorCanvasFeed: (raw["srCanvas"] as? Bool) ?? ((raw["srCanvas"] as? NSNumber)?.boolValue ?? false)
        )

        // Active but not armed is the exact failure that lets the real camera
        // pass through — call it out plainly instead of a generic "no frames".
        if active && !armed {
            driftReport = nil
            let detail = armError.isEmpty ? "" : " (\(armError))"
            driftStatus = "Media is on but the camera takeover isn't armed\(detail) — the site is getting the real camera. Reload the page to re-arm it."
            return
        }
        let timestampsMs: [Double] = (raw["times"] as? [Double])
            ?? (raw["times"] as? [NSNumber])?.map { $0.doubleValue }
            ?? []

        guard active else {
            driftReport = nil
            driftStatus = "Injection isn't running yet. Turn on Enable Media in the browser, then analyze."
            return
        }

        guard let report = Self.buildDriftReport(timestampsMs: timestampsMs) else {
            driftReport = nil
            driftStatus = "Injection is live but hasn't delivered enough frames yet — give it a moment and try again."
            return
        }

        driftReport = report
        driftStatus = nil
    }

    /// Builds a drift report from injected-frame delivery timestamps (milliseconds).
    private static func buildDriftReport(timestampsMs: [Double]) -> DriftReport? {
        guard timestampsMs.count >= 2 else { return nil }

        let times = timestampsMs.map { $0 / 1000.0 }
        var deltas: [Double] = []
        for i in 1..<times.count {
            let delta = times[i] - times[i - 1]
            if delta >= 0 { deltas.append(delta) }
        }
        guard !deltas.isEmpty else { return nil }

        let sortedDeltas = deltas.sorted()
        let median = sortedDeltas[sortedDeltas.count / 2]

        var jitterCount = 0
        var duplicateCount = 0
        for delta in deltas {
            if delta < 0.001 {
                duplicateCount += 1
            } else if median > 0 && abs(delta - median) > median * 0.5 {
                jitterCount += 1
            }
        }

        let totalDelta = deltas.reduce(0, +)
        let averageFPS = totalDelta > 0 ? Double(deltas.count) / totalDelta : 0

        let sampleCount = min(60, deltas.count)
        let sampleStart = deltas.count - sampleCount
        var samples: [FrameTimingSample] = []
        for i in sampleStart..<deltas.count {
            let delta = deltas[i]
            let isDuplicate = delta < 0.001
            let isJitter = !isDuplicate && median > 0 && abs(delta - median) > median * 0.5
            samples.append(FrameTimingSample(
                timestamp: times[i + 1],
                delta: delta,
                isDuplicate: isDuplicate,
                isJitter: isJitter
            ))
        }

        return DriftReport(
            averageFPS: averageFPS,
            minDelta: sortedDeltas.first ?? 0,
            maxDelta: sortedDeltas.last ?? 0,
            jitterCount: jitterCount,
            duplicateCount: duplicateCount,
            totalFrames: times.count,
            samples: samples
        )
    }

    // MARK: - Media File Inspection

    static func inspectMediaFile(at url: URL) async -> MediaMetadataReport? {
        let asset = AVURLAsset(url: url)

        let container = url.pathExtension.lowercased()

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let estimatedDataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
        let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        var videoCodec = ""
        var pixelFormat = ""
        var colorPrimaries = ""
        var transferFunction = ""
        var colorMatrix = ""
        var isFullRange = false

        if let formatDesc = formatDescriptions.first {
            let subType = CMFormatDescriptionGetMediaSubType(formatDesc)
            switch subType {
            case kCMVideoCodecType_H264:
                videoCodec = "h264"
            case kCMVideoCodecType_HEVC:
                videoCodec = "hevc"
            default:
                videoCodec = String(fourCharCode: subType)
            }

            if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                colorPrimaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String ?? ""
                transferFunction = extensions[kCVImageBufferTransferFunctionKey as String] as? String ?? ""
                colorMatrix = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String ?? ""

                if let pixelAspect = extensions[kCVImageBufferPixelAspectRatioKey as String] as? [String: Any] {
                    let hSpacing = pixelAspect["HorizontalSpacing"] as? Int ?? 1
                    let vSpacing = pixelAspect["VerticalSpacing"] as? Int ?? 1
                    pixelFormat = "PAR \(hSpacing):\(vSpacing)"
                } else {
                    pixelFormat = ""
                }

                if let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
                    isFullRange = fullRange
                }
            }
        }

        let rotationDegrees: Int
        let angle = atan2(preferredTransform.b, preferredTransform.a)
        let degrees = angle * 180 / .pi
        rotationDegrees = Int(round(degrees < 0 ? degrees + 360 : degrees))

        let isHDR = transferFunction.contains("HLG") || transferFunction.contains("PQ")
            || transferFunction.contains("SMPTE_ST_2084")

        // Audio track info
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = !audioTracks.isEmpty
        var audioCodec = ""
        var audioSampleRate: Double = 0
        var audioChannels = 0
        var audioBitrate = 0

        if let audioTrack = audioTracks.first {
            let audioFormats = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let audioDataRate = (try? await audioTrack.load(.estimatedDataRate)) ?? 0
            audioBitrate = Int(audioDataRate)

            if let audioFormat = audioFormats.first {
                let audioSubType = CMFormatDescriptionGetMediaSubType(audioFormat)
                switch audioSubType {
                case kAudioFormatMPEG4AAC:
                    audioCodec = "aac"
                case kAudioFormatLinearPCM:
                    audioCodec = "pcm"
                case kAudioFormatOpus:
                    audioCodec = "opus"
                default:
                    audioCodec = String(fourCharCode: audioSubType)
                }

                if let streamBasicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat) {
                    audioSampleRate = streamBasicDesc.pointee.mSampleRate
                    audioChannels = Int(streamBasicDesc.pointee.mChannelsPerFrame)
                }
            }
        }

        return MediaMetadataReport(
            container: container,
            videoCodec: videoCodec,
            videoBitrate: Int(estimatedDataRate),
            videoFrameRate: Double(nominalFrameRate),
            pixelFormat: pixelFormat,
            rotationDegrees: rotationDegrees,
            videoWidth: Int(naturalSize.width),
            videoHeight: Int(naturalSize.height),
            hasAudio: hasAudio,
            audioCodec: audioCodec,
            audioBitrate: audioBitrate,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            colorMatrix: colorMatrix,
            isFullRange: isFullRange,
            isHDR: isHDR
        )
    }

    // MARK: - Conformance Scoring

    static func scoreConformance(media: MediaMetadataReport, camera: CameraDeviceSpec) -> MediaConformanceScore {
        var details: [String] = []
        var matchCount = 0

        let resolutionMatch = abs(media.videoWidth - camera.activeWidth) <= Int(Double(camera.activeWidth) * 0.1)
            && abs(media.videoHeight - camera.activeHeight) <= Int(Double(camera.activeHeight) * 0.1)
        if resolutionMatch { matchCount += 1 }
        details.append("Resolution: media \(media.videoWidth)x\(media.videoHeight) vs camera \(camera.activeWidth)x\(camera.activeHeight) → \(resolutionMatch ? "match" : "mismatch")")

        let fpsMatch = abs(media.videoFrameRate - camera.activeFrameRate) <= 5
        if fpsMatch { matchCount += 1 }
        details.append("FPS: media \(String(format: "%.1f", media.videoFrameRate)) vs camera \(String(format: "%.1f", camera.activeFrameRate)) → \(fpsMatch ? "match" : "mismatch")")

        let cameraCodec = camera.testClipCodec ?? ""
        let codecMatch = media.videoCodec.lowercased() == cameraCodec.lowercased()
        if codecMatch { matchCount += 1 }
        details.append("Codec: media \(media.videoCodec) vs camera \(cameraCodec) → \(codecMatch ? "match" : "mismatch")")

        let cameraBitrate = camera.testClipBitrate ?? 0
        let bitrateMatch: Bool
        if cameraBitrate > 0 {
            bitrateMatch = abs(media.videoBitrate - cameraBitrate) <= Int(Double(cameraBitrate) * 0.3)
        } else {
            bitrateMatch = false
        }
        if bitrateMatch { matchCount += 1 }
        details.append("Bitrate: media \(media.videoBitrate) vs camera \(cameraBitrate) → \(bitrateMatch ? "match" : "mismatch")")

        let orientationMatch = media.rotationDegrees == 0
        if orientationMatch { matchCount += 1 }
        details.append("Orientation: rotation \(media.rotationDegrees)° → \(orientationMatch ? "match" : "mismatch")")

        let audioMatch = media.hasAudio
        if audioMatch { matchCount += 1 }
        details.append("Audio: \(audioMatch ? "present" : "missing") → \(audioMatch ? "match" : "mismatch")")

        let overallScore = Double(matchCount) / 6.0 * 100.0

        return MediaConformanceScore(
            overallScore: overallScore,
            resolutionMatch: resolutionMatch,
            fpsMatch: fpsMatch,
            codecMatch: codecMatch,
            bitrateMatch: bitrateMatch,
            orientationMatch: orientationMatch,
            audioMatch: audioMatch,
            details: details
        )
    }
}

// MARK: - Helpers

private extension String {
    init(fourCharCode code: UInt32) {
        self = String(
            format: "%c%c%c%c",
            (code >> 24) & 0xFF,
            (code >> 16) & 0xFF,
            (code >> 8) & 0xFF,
            code & 0xFF
        )
    }


}
