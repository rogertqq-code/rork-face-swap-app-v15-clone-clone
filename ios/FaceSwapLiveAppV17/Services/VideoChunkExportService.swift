import Foundation
import AVFoundation
import CoreMedia

/// Demuxes a transcoded H.264 clip into WebCodecs-ready encoded chunks and
/// packages them as JSON for the injection engine's new frame engine.
///
/// The clean feed's new frame engine feeds these chunks straight into a
/// `VideoDecoder` in the page — decoding the clip into camera frames without a
/// hidden `<video>` element. This is deliberately best-effort: it returns `nil`
/// for anything it can't cleanly demux (non-H.264 codecs, missing tracks,
/// oversized clips, read failures). A `nil` result is never a failure — the
/// engine simply falls back to the proven element-backed clean feed, so the
/// camera is never left without a source.
nonisolated enum VideoChunkExportService {
    /// Produces a JSON bundle of encoded video chunks for `url`, or `nil` when
    /// the clip can't be demuxed into a WebCodecs-friendly form.
    ///
    /// JSON shape:
    /// `{codec, description(base64 avcC), codedWidth, codedHeight, fps, frames:[{t,d,k,b}]}`
    /// where each frame is `{timestamp µs, duration µs, isKeyframe, base64 AVCC sample}`.
    static func exportChunksJSON(
        from url: URL,
        maxFrames: Int = 1800,
        maxTotalBytes: Int = 40_000_000
    ) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let formatDescriptions = try await track.load(.formatDescriptions)
            guard let format = formatDescriptions.first else { return nil }

            // Only H.264 is supported by this path; every other codec cleanly
            // falls back to the element-backed clean feed.
            guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else { return nil }
            guard let avcC = avcCData(from: format) else { return nil }

            let dims = CMVideoFormatDescriptionGetDimensions(format)
            let codecString = avcCodecString(from: avcC)
            let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 30
            let fallbackDurationMicros = Int(1_000_000.0 / Double(max(nominalFPS, 1)))

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var frameEntries: [String] = []
            var totalBytes = 0

            while let sample = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }

                var bytes = [UInt8](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                    return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
                guard status == kCMBlockBufferNoErr else { continue }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                let timestampMicros = pts.isValid && pts.seconds.isFinite ? Int(pts.seconds * 1_000_000) : 0
                let durationMicros = (duration.isValid && duration.seconds.isFinite && duration.seconds > 0)
                    ? Int(duration.seconds * 1_000_000)
                    : fallbackDurationMicros
                let isKey = sampleIsKeyframe(sample)

                totalBytes += length
                if frameEntries.count >= maxFrames || totalBytes > maxTotalBytes { return nil }

                let base64 = Data(bytes).base64EncodedString()
                frameEntries.append(
                    "{\"t\":\(timestampMicros),\"d\":\(durationMicros),\"k\":\(isKey ? "true" : "false"),\"b\":\"\(base64)\"}"
                )
            }

            guard reader.status != .failed, !frameEntries.isEmpty else { return nil }

            let descriptionBase64 = avcC.base64EncodedString()
            let json = "{\"codec\":\"\(codecString)\","
                + "\"description\":\"\(descriptionBase64)\","
                + "\"codedWidth\":\(dims.width),"
                + "\"codedHeight\":\(dims.height),"
                + "\"fps\":\(Int(nominalFPS.rounded())),"
                + "\"frames\":[\(frameEntries.joined(separator: ","))]}"
            return json.data(using: .utf8)
        } catch {
            return nil
        }
    }

    /// Extracts the raw `avcC` decoder configuration record from a video format
    /// description. WebCodecs uses this as the decoder `description`, and the
    /// AVCC-format samples we vend match it exactly (length-prefixed NAL units).
    private static func avcCData(from format: CMFormatDescription) -> Data? {
        guard let atoms = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return nil }
        guard let data = atoms["avcC"] as? Data, data.count >= 4 else { return nil }
        return data
    }

    /// Builds the WebCodecs codec string (`avc1.PPCCLL`) from the avcC record,
    /// where PP/CC/LL are the profile, compatibility, and level bytes.
    /// Internal (not private) so the byte-offset logic — a silent-failure risk,
    /// since a malformed string makes `VideoDecoder.configure` throw and disables
    /// the whole WebCodecs engine — can be regression-tested directly.
    static func avcCodecString(from avcC: Data) -> String {
        let start = avcC.startIndex
        let profile = avcC[start + 1]
        let compatibility = avcC[start + 2]
        let level = avcC[start + 3]
        return String(format: "avc1.%02X%02X%02X", profile, compatibility, level)
    }

    /// A sample is a keyframe unless it is explicitly flagged not-a-sync-sample.
    private static func sampleIsKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true
    }
}
