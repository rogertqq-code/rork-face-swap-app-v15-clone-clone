import Foundation

nonisolated enum SmartMediaPresetService {
    static func presets(profile: DeviceProfile?, constraintEntries: [ConstraintLogEntry], currentURL: URL?) -> [MediaVariantPreset] {
        var result: [MediaVariantPreset] = []
        var seen: Set<String> = []

        func add(_ preset: MediaVariantPreset) {
            let key = "\(preset.target.rawValue)-\(preset.width)-\(preset.height)-\(preset.frameRate)-\(preset.sourceGroup.rawValue)-\(preset.responseResult?.request.surface.rawValue ?? "base")"
            guard !seen.contains(key), preset.width > 0, preset.height > 0 else { return }
            seen.insert(key)
            result.append(preset)
        }

        let learnedResponseMap = CameraResponseCalibrationService.learnedMap(
            from: constraintEntries,
            existing: profile?.cameraResponseMap
        )
        let responseResults = prioritizedResponses(learnedResponseMap.results, currentURL: currentURL)
        for response in responseResults.prefix(12) {
            add(responsePreset(response))
        }

        if let front = profile?.frontCamera {
            add(cameraPreset(front, target: .front, group: .frontCamera, fallbackLabel: "Profile front"))
            for format in usefulFormats(front.supportedFormats, limit: 2) {
                add(MediaVariantPreset(
                    target: .front,
                    width: format.width,
                    height: format.height,
                    frameRate: Int(format.maxFrameRate.rounded()),
                    sourceGroup: .frontCamera,
                    sourceLabel: "Front format"
                ))
            }
        }

        if let back = profile?.backCamera {
            add(cameraPreset(back, target: .back, group: .backCamera, fallbackLabel: "Profile back"))
            for format in usefulFormats(back.supportedFormats, limit: 2) {
                add(MediaVariantPreset(
                    target: .back,
                    width: format.width,
                    height: format.height,
                    frameRate: Int(format.maxFrameRate.rounded()),
                    sourceGroup: .backCamera,
                    sourceLabel: "Back format"
                ))
            }
        }

        let liveEntries = prioritizedLiveEntries(constraintEntries, currentURL: currentURL)
        for request in liveEntries.prefix(5).compactMap(extractRequestPreset) {
            add(request)
        }

        let iphoneDefaults: [(RequestTarget, Int, Int, Int, String)] = [
            (.back, 1920, 1080, 30, "1080p back"),
            (.front, 1280, 720, 30, "720p front"),
            (.back, 3840, 2160, 30, "4K back"),
            (.front, 1920, 1080, 30, "1080p front")
        ]
        for item in iphoneDefaults {
            add(MediaVariantPreset(target: item.0, width: item.1, height: item.2, frameRate: item.3, sourceGroup: .iPhoneDefault, sourceLabel: item.4))
        }

        let browserDefaults: [(Int, Int, Int, String)] = [
            (640, 480, 30, "VGA WebRTC"),
            (1280, 720, 30, "HD WebRTC"),
            (1920, 1080, 30, "Full HD WebRTC"),
            (1080, 1920, 30, "Portrait WebRTC")
        ]
        for item in browserDefaults {
            add(MediaVariantPreset(target: .any, width: item.0, height: item.1, frameRate: item.2, sourceGroup: .commonBrowser, sourceLabel: item.3))
        }

        return Array(result.prefix(24))
    }

    static func spec(from preset: MediaVariantPreset, profile: DeviceProfile?) -> MediaConversionSpec {
        let referenceCamera: CameraDeviceSpec?
        switch preset.target {
        case .front: referenceCamera = profile?.frontCamera
        case .back: referenceCamera = profile?.backCamera
        case .any: referenceCamera = profile?.backCamera ?? profile?.frontCamera
        }

        let fps = MediaConversionSpec.clampFrameRate(preset.frameRate)
        let bitrate = referenceCamera?.testClipBitrate ?? defaultBitrate(width: preset.width, height: preset.height, fps: fps)
        return MediaConversionSpec(
            targetWidth: preset.width,
            targetHeight: preset.height,
            targetFrameRate: fps,
            targetBitrate: bitrate,
            targetCodec: referenceCamera?.testClipCodec ?? "h264",
            targetColorPrimaries: referenceCamera?.testClipColorPrimaries,
            targetTransferFunction: referenceCamera?.testClipTransferFunction,
            targetColorMatrix: referenceCamera?.testClipColorMatrix,
            targetProfileLevel: referenceCamera?.testClipProfileLevel
        )
    }

    private static func responsePreset(_ response: CameraResponseResult) -> MediaVariantPreset {
        let group: MediaVariantSourceGroup
        switch response.request.surface {
        case .webRTC: group = .responseMap
        case .nativeCamera: group = .nativeResponse
        case .liveSite: group = .liveResponse
        }
        let sourceLabel = "\(response.request.surface.label): \(response.request.requestedLabel) → \(response.actualLabel)"
        return MediaVariantPreset(
            target: response.request.target,
            width: response.actualWidth,
            height: response.actualHeight,
            frameRate: response.actualFrameRate,
            sourceGroup: group,
            sourceLabel: sourceLabel,
            isLiveRequest: response.request.surface == .liveSite,
            responseResult: response
        )
    }

    private static func prioritizedResponses(_ responses: [CameraResponseResult], currentURL: URL?) -> [CameraResponseResult] {
        guard let host = currentURL?.host?.lowercased(), !host.isEmpty else {
            return responses.sorted { $0.confidence > $1.confidence }
        }
        return responses.sorted { lhs, rhs in
            let lhsMatches = lhs.request.sourceLabel.lowercased().contains(host)
            let rhsMatches = rhs.request.sourceLabel.lowercased().contains(host)
            if lhsMatches != rhsMatches { return lhsMatches }
            if lhs.request.surface != rhs.request.surface { return lhs.request.surface == .liveSite }
            return lhs.confidence > rhs.confidence
        }
    }

    private static func cameraPreset(_ camera: CameraDeviceSpec, target: RequestTarget, group: MediaVariantSourceGroup, fallbackLabel: String) -> MediaVariantPreset {
        let fps = MediaConversionSpec.clampFrameRate(Int(camera.activeFrameRate.rounded()))
        return MediaVariantPreset(
            target: target,
            width: max(camera.activeWidth, 1),
            height: max(camera.activeHeight, 1),
            frameRate: fps,
            sourceGroup: group,
            sourceLabel: camera.label.isEmpty ? fallbackLabel : camera.label
        )
    }

    private static func usefulFormats(_ formats: [CameraFormatSpec], limit: Int) -> [CameraFormatSpec] {
        var bySize: [String: CameraFormatSpec] = [:]
        for format in formats where format.width > 0 && format.height > 0 {
            let key = "\(format.width)x\(format.height)"
            if let existing = bySize[key] {
                if format.maxFrameRate > existing.maxFrameRate { bySize[key] = format }
            } else {
                bySize[key] = format
            }
        }
        return bySize.values
            .sorted { ($0.width * $0.height) > ($1.width * $1.height) }
            .prefix(limit)
            .map { $0 }
    }

    private static func prioritizedLiveEntries(_ entries: [ConstraintLogEntry], currentURL: URL?) -> [ConstraintLogEntry] {
        guard let host = currentURL?.host?.lowercased(), !host.isEmpty else { return entries }
        let matching = entries.filter { $0.siteURL.lowercased().contains(host) }
        return matching + entries.filter { !$0.siteURL.lowercased().contains(host) }
    }

    private static func extractRequestPreset(from entry: ConstraintLogEntry) -> MediaVariantPreset? {
        let combined = entry.requestedConstraints + " " + entry.negotiatedResult
        guard let size = firstSize(in: combined) else { return nil }
        let fps = firstFrameRate(in: combined) ?? 30
        let lower = combined.lowercased()
        let target: RequestTarget
        if lower.contains("user") || lower.contains("front") {
            target = .front
        } else if lower.contains("environment") || lower.contains("back") || lower.contains("rear") {
            target = .back
        } else {
            target = .any
        }
        let host = URL(string: entry.siteURL)?.host ?? "Live request"
        return MediaVariantPreset(
            target: target,
            width: size.width,
            height: size.height,
            frameRate: fps,
            sourceGroup: .browserRequest,
            sourceLabel: host,
            isLiveRequest: true
        )
    }

    private static func firstSize(in text: String) -> (width: Int, height: Int)? {
        let patterns = [
            #"width[^0-9]{0,20}(\d{3,4}).{0,80}height[^0-9]{0,20}(\d{3,4})"#,
            #"(\d{3,4})\s*[x×]\s*(\d{3,4})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3,
                  let wRange = Range(match.range(at: 1), in: text),
                  let hRange = Range(match.range(at: 2), in: text),
                  let width = Int(text[wRange]),
                  let height = Int(text[hRange]),
                  width >= 160,
                  height >= 120 else { continue }
            return (width, height)
        }
        return nil
    }

    private static func firstFrameRate(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"frameRate[^0-9]{0,20}(\d{1,3})"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let fpsRange = Range(match.range(at: 1), in: text),
              let fps = Int(text[fpsRange]) else { return nil }
        return MediaConversionSpec.clampFrameRate(fps)
    }

    private static func defaultBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = width * height
        if pixels >= 3840 * 2160 { return fps >= 60 ? 50_000_000 : 25_000_000 }
        if pixels >= 1920 * 1080 { return fps >= 60 ? 17_000_000 : 10_000_000 }
        if pixels >= 1280 * 720 { return fps >= 60 ? 10_000_000 : 5_000_000 }
        return 2_500_000
    }
}
