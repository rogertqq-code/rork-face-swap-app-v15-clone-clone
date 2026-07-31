import Testing
import UIKit
import Foundation
import ImageIO
@testable import FaceSwapLiveAppV17

struct FaceSwapLiveAppV17Tests {
    @Test func byteRangeParsesStandardStartEnd() async throws {
        let result = LocalResourceHandler.resolveByteRange("bytes=10-19", fileSize: 100)
        #expect(result == .partial(ResourceByteRange(start: 10, end: 19)))
    }

    @Test func byteRangeParsesOpenEndedRange() async throws {
        let result = LocalResourceHandler.resolveByteRange("bytes=95-", fileSize: 100)
        #expect(result == .partial(ResourceByteRange(start: 95, end: 99)))
    }

    @Test func byteRangeParsesSuffixRange() async throws {
        let result = LocalResourceHandler.resolveByteRange("bytes=-10", fileSize: 100)
        #expect(result == .partial(ResourceByteRange(start: 90, end: 99)))
    }

    @Test func byteRangeRejectsOutOfBoundsStart() async throws {
        let result = LocalResourceHandler.resolveByteRange("bytes=100-120", fileSize: 100)
        #expect(result == .unsatisfiable)
    }

    @Test func renderedImagesUseExactPixelDimensions() async throws {
        let input = solidImage(width: 24, height: 12)
        let rendered = MediaConverterService().renderImage(input, width: 320, height: 180, mode: .fillCrop)
        #expect(rendered.cgImage?.width == 320)
        #expect(rendered.cgImage?.height == 180)
    }

    // MARK: - EXIF stamping (served picker image = a real camera capture)
    //
    // The file-picker path serves this EXIF-stamped JPEG as a "fresh capture", so
    // the metadata must read like an iPhone photo: Apple make/model, matching
    // pixel dimensions, upright orientation, a full capture timestamp with a
    // timezone offset, and lens identity. These lock the perfection contract
    // through the exact public API the resource handler calls.
    @Test func exifStampProducesRealisticAppleCameraMetadata() async throws {
        let image = solidImage(width: 160, height: 120)
        let data = try #require(EXIFMetadataService().jpegDataWithEXIF(image: image, camera: nil, hardware: nil))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])

        // Pixel dimensions match the decoded bytes exactly.
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 160)
        #expect(props[kCGImagePropertyPixelHeight as String] as? Int == 120)
        // Baked upright (orientation tag 1) so no viewer re-rotates it.
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 1)

        let tiff = try #require(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "Apple")
        #expect((tiff[kCGImagePropertyTIFFModel as String] as? String)?.isEmpty == false)

        let exif = try #require(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        // Full capture timestamp + subsecond + timezone offset (EXIF 2.31).
        #expect((exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)?.isEmpty == false)
        #expect((exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)?.isEmpty == false)
        let offset = try #require(exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String)
        #expect(offset.contains(":"))
        #expect(offset.hasPrefix("+") || offset.hasPrefix("-"))
        // Lens identity present, as on a real capture.
        #expect(exif[kCGImagePropertyExifLensMake as String] as? String == "Apple")
        #expect((exif[kCGImagePropertyExifLensModel as String] as? String)?.isEmpty == false)
        // Exif pixel dimensions agree with the container dimensions.
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == 160)
        #expect(exif[kCGImagePropertyExifPixelYDimension as String] as? Int == 120)
    }

    @Test func exifStampEmbedsGPSWhenCoordinatesProvided() async throws {
        let image = solidImage(width: 48, height: 48)
        let data = try #require(EXIFMetadataService().jpegDataWithEXIFAndGPS(
            image: image, camera: nil, hardware: nil,
            latitude: 37.3349, longitude: -122.0090, altitude: 12.0
        ))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let gps = try #require(props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "N")
        #expect(gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W")
        #expect((gps[kCGImagePropertyGPSLatitude as String] as? Double) != nil)
    }

    private func solidImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - WebCodecs demux codec-string (new frame engine)
    //
    // The codec string feeds VideoDecoder.configure(). If the profile/
    // compatibility/level bytes are read from the wrong offsets, or emitted
    // lowercase / zero-padded wrong, configure() throws and the whole WebCodecs
    // frame engine silently falls back to the element feed — a regression that
    // would never surface as a crash. These lock the byte-offset + format logic.

    @Test func avcCodecStringFormatsProfileCompatLevelAsUppercaseHex() async throws {
        // avcC record: configurationVersion(0x01), AVCProfileIndication(High=0x64),
        // profile_compatibility(0x00), AVCLevelIndication(0x28 = level 4.0), then
        // the SPS/PPS payload the builder must ignore.
        let avcC = Data([0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, 0x1A])
        #expect(VideoChunkExportService.avcCodecString(from: avcC) == "avc1.640028")
    }

    @Test func avcCodecStringZeroPadsSingleDigitBytes() async throws {
        // Baseline profile 0x42, compatibility 0xC0, level 0x0A (level 1.0): the
        // 0x0A must render as "0A", never "A", or the string is malformed.
        let avcC = Data([0x01, 0x42, 0xC0, 0x0A])
        #expect(VideoChunkExportService.avcCodecString(from: avcC) == "avc1.42C00A")
    }

    @Test func avcCodecStringReadsFromSliceStartIndexNotZero() async throws {
        // A Data slice whose startIndex is not 0 must still read the record's own
        // first four bytes. The builder anchors on avcC.startIndex, not literal 0;
        // this guards against a regression to `avcC[1]` (which would crash or read
        // the wrong byte on a sliced Data).
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(Data([0x01, 0x4D, 0x40, 0x1E]))
        let slice = padded.suffix(4)
        #expect(slice.startIndex == 3)
        #expect(VideoChunkExportService.avcCodecString(from: slice) == "avc1.4D401E")
    }

    // MARK: - Network Rewrite proxy response building
    //
    // These target the two polish items from the deep-review fix pass: multiple
    // Set-Cookie headers getting merged into one corrupted line, and
    // integrity-stripping silently skipping non-UTF8 legacy HTML.

    @Test func rewriteBuilderSplitsMergedSetCookieHeadersIntoSeparateLines() async throws {
        let url = try #require(URL(string: "http://example.com/"))
        let headerFields = [
            "Content-Type": "text/html; charset=utf-8",
            "Set-Cookie": "session=abc123; Path=/; HttpOnly, pref=dark; Path=/; Expires=Wed, 01 Jan 2030 00:00:00 GMT"
        ]
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headerFields))
        let body = Data("<html><head><title>t</title></head><body>hi</body></html>".utf8)

        let output = NetworkRewriteResponseBuilder.build(response: response, body: body)
        // Require a real decode: a `?? ""` fallback would let the negative
        // assertions below pass against an empty string even if output broke.
        let text = try #require(String(data: output, encoding: .utf8))
        let cookieLines = text.components(separatedBy: "\r\n").filter { $0.hasPrefix("Set-Cookie:") }

        #expect(cookieLines.count == 2)
        #expect(cookieLines.contains { $0.contains("session=abc123") })
        #expect(cookieLines.contains { $0.contains("pref=dark") })
        // The bug being guarded against: both cookies collapsing onto one line
        // (the comma inside "Expires" getting treated as a cookie separator).
        #expect(!cookieLines.contains { $0.contains("session=abc123") && $0.contains("pref=dark") })
    }

    @Test func rewriteBuilderStripsIntegrityAttributesAndInjectsMarker() async throws {
        let url = try #require(URL(string: "http://example.com/"))
        let headerFields = ["Content-Type": "text/html; charset=utf-8"]
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headerFields))
        let html = "<html><head><script src=\"a.js\" integrity=\"sha384-abc123\"></script></head><body>hi</body></html>"

        let output = NetworkRewriteResponseBuilder.build(response: response, body: Data(html.utf8))
        let text = try #require(String(data: output, encoding: .utf8))

        #expect(!text.contains("integrity="))
        #expect(text.contains("window.__fslProxyRewrite=1"))
    }

    @Test func rewriteBuilderDropsSecurityHeadersThatWouldBlockInjection() async throws {
        let url = try #require(URL(string: "http://example.com/"))
        let headerFields = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "default-src 'none'",
            "X-Frame-Options": "DENY",
            "Strict-Transport-Security": "max-age=31536000"
        ]
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headerFields))

        let output = NetworkRewriteResponseBuilder.build(response: response, body: Data("<html><head></head><body></body></html>".utf8))
        // Require a real decode so the "header dropped" assertions can't pass
        // trivially against an empty-string fallback.
        let text = try #require(String(data: output, encoding: .utf8))
        let lowered = text.lowercased()

        #expect(!lowered.contains("content-security-policy"))
        #expect(!lowered.contains("x-frame-options"))
        #expect(!lowered.contains("strict-transport-security"))
    }

    @Test func rewriteBuilderHandlesNonUTF8LegacyHTMLWithoutCorruption() async throws {
        let url = try #require(URL(string: "http://example.com/"))
        let headerFields = ["Content-Type": "text/html"]
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headerFields))

        // A legacy plain-HTTP page in Latin-1: the raw byte 0xE9 ('é') is not
        // valid UTF-8 on its own, so decoding as UTF-8 must fail and the
        // isoLatin1 fallback must take over — and the body must be re-encoded
        // with that SAME encoding, or the byte would get corrupted.
        var bytes = Array("<html><head></head><body>caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Array("</body></html>".utf8))
        let body = Data(bytes)

        let output = NetworkRewriteResponseBuilder.build(response: response, body: body)
        let terminator = try #require(output.range(of: Data("\r\n\r\n".utf8)))
        let outBody = output.subdata(in: terminator.upperBound..<output.endIndex)
        let decoded = try #require(String(data: outBody, encoding: .isoLatin1))

        #expect(decoded.contains("café"))
        #expect(decoded.contains("window.__fslProxyRewrite=1"))
    }

    // MARK: - Legacy injection-method migration
    //
    // The old Network Filter / Network Rewrite picker entries, plus the folded
    // Classic Canvas and Video Direct methods, must keep decoding safely and
    // migrate to their active replacements, exactly once, with no drift for
    // active methods.

    @Test func legacyNetworkFilterMigratesToCanvasPipelinePlusBlockDetectionOnly() async throws {
        let legacy = InjectionMethodKind.networkFilter
        #expect(legacy.migratedCameraMethod == .canvasPipeline)
        let backend = try #require(legacy.migratedNetworkBackend)
        #expect(backend.blockDetectionScripts == true)
        #expect(backend.useRewriteProxy == false)
    }

    @Test func legacyNetworkRewriteMigratesToCanvasPipelinePlusBothSwitches() async throws {
        let legacy = InjectionMethodKind.networkRewrite
        #expect(legacy.migratedCameraMethod == .canvasPipeline)
        let backend = try #require(legacy.migratedNetworkBackend)
        #expect(backend.blockDetectionScripts == true)
        #expect(backend.useRewriteProxy == true)
    }

    @Test func legacyClassicCanvasMigratesToCanvasPipeline() async throws {
        let legacy = InjectionMethodKind.classicCanvas
        #expect(legacy.migratedCameraMethod == .canvasPipeline)
    }

    @Test func legacyVideoDirectMigratesToRawFramePipe() async throws {
        let legacy = InjectionMethodKind.videoDirect
        #expect(legacy.migratedCameraMethod == .rawFramePipe)
    }

    @Test func activeDisplayOrderLeadsWithAutoThenTheProvenMethods() async throws {
        #expect(InjectionMethodKind.displayOrder == [
            .auto,
            .canvasPipeline,
            .rawFramePipe,
            .privateLane,
            .passthrough
        ])
    }

    @Test func autoIsTheDefaultAndServesMedia() async throws {
        #expect(InjectionMethodKind.displayOrder.first == .auto)
        #expect(InjectionMethodKind.auto.servesMedia == true)
        #expect(InjectionMethodKind.auto.migratedCameraMethod == .auto)
    }

    @Test func nonLegacyMethodsNeverMigrate() async throws {
        for kind in InjectionMethodKind.displayOrder {
            #expect(kind.migratedCameraMethod == kind)
            #expect(kind.migratedNetworkBackend == nil)
        }
    }

    @Test func siteProfileRecordDecodesAndMigratesClassicCanvas() async throws {
        let json = """
        {
            "host": "test.com",
            "profile": "classicCanvas",
            "outcome": "worked"
        }
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(SiteProfileRecord.self, from: json)
        #expect(record.profile == .canvasPipeline)
        #expect(record.networkBackend.blockDetectionScripts == false)
    }

    @Test func siteProfileRecordDecodesAndMigratesVideoDirect() async throws {
        let json = """
        {
            "host": "test.com",
            "profile": "videoDirect",
            "outcome": "worked"
        }
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(SiteProfileRecord.self, from: json)
        #expect(record.profile == .rawFramePipe)
        #expect(record.networkBackend.blockDetectionScripts == false)
    }

    @Test func browserViewModelMigrateLoadedProfileHandlesLegacyValues() async throws {
        let classicResult = try #require(BrowserViewModel.migrateLoadedProfile("classicCanvas"))
        #expect(classicResult.profile == .canvasPipeline)
        #expect(classicResult.network == nil)
        
        let videoResult = try #require(BrowserViewModel.migrateLoadedProfile("videoDirect"))
        #expect(videoResult.profile == .rawFramePipe)
        #expect(videoResult.network == nil)
        
        let activeResult = try #require(BrowserViewModel.migrateLoadedProfile("rawFramePipe"))
        #expect(activeResult.profile == .rawFramePipe)
        #expect(activeResult.network == nil)
    }

    // MARK: - Feed engine readout honesty
    //
    // The live readout must only ever claim "private lane" when the lane truly
    // carried the stream — a Tier-2 in-page fallback must read as a plain
    // clean feed, never over-claiming the private lane succeeded.

    @Test func feedEngineStatusNeverOverclaimsPrivateLaneOnInPageFallback() async throws {
        let fallback = FeedEngineStatus(
            active: true, method: "privateLane", feed: "vtg", lane: "",
            intended: "privateLane", downgraded: false, reason: "private-lane-fallback"
        )
        #expect(fallback.isPrivateLane == false)
        #expect(fallback.isPrivateLaneFallback == true)
        #expect(fallback.feedLabel == "Clean background track")
    }

    @Test func feedEngineStatusLabelsGenuinePrivateLaneSuccess() async throws {
        let truePrivateLane = FeedEngineStatus(
            active: true, method: "privateLane", feed: "vtg", lane: "private",
            intended: "privateLane", downgraded: false, reason: ""
        )
        #expect(truePrivateLane.isPrivateLane == true)
        #expect(truePrivateLane.isPrivateLaneFallback == false)
        #expect(truePrivateLane.feedLabel == "Clean background track · private lane")
    }

    // MARK: - Detector self-test score banding

    @Test func detectorReportScoreTintReflectsFailWarnAndScoreBands() async throws {
        let allPass = DetectorSelfTestReport(
            methodRaw: "canvasPipeline", active: true, score: 95,
            checks: [DetectorSelfTestCheck(checkID: "a", title: "A", status: .pass, detail: "")]
        )
        #expect(allPass.scoreTintName == "green")

        let withWarn = DetectorSelfTestReport(
            methodRaw: "canvasPipeline", active: true, score: 85,
            checks: [DetectorSelfTestCheck(checkID: "a", title: "A", status: .warn, detail: "")]
        )
        #expect(withWarn.scoreTintName == "orange")

        let withFail = DetectorSelfTestReport(
            methodRaw: "canvasPipeline", active: true, score: 90,
            checks: [DetectorSelfTestCheck(checkID: "a", title: "A", status: .fail, detail: "")]
        )
        #expect(withFail.scoreTintName == "red")
    }

    // MARK: - patchScript integrity

    @Test func patchScriptIntegrity() async throws {
        let script = StyleSheetProvider.patchScript
        
        // Assert no raw TAB or CR characters (Swift would convert lone \t / \r
        // escapes at compile time, corrupting the JS regex that WebKit then
        // fails to parse)
        #expect(!script.contains("\t"))
        #expect(!script.contains("\r"))
        
        // Assert the control characters are properly escaped as backslash sequences in the JS regex
        #expect(script.contains(#"[\t\n\r ]"#))
        
        // Assert it contains the install marker
        #expect(script.contains("Symbol.for('fsl')"))
    }

    @Test func rawFramePipePhotoRequestsDoNotDowngradeToCanvas() async throws {
        let script = StyleSheetProvider.patchScript
        // The script MUST NOT guard photo steps for rawFramePipe, which naturally
        // supports them via VTG. The fallback is limited to the legacy videoDirect.
        #expect(script.contains("if(method==='videoDirect'&&!step.vid)"))
        #expect(!script.contains("if(method==='rawFramePipe'&&!step.vid)"))
    }

    // MARK: - Recommendation Resolver

    @Test func resolverPrefersConfirmedWorkedSiteMemory() async throws {
        let workedRecord = SiteProfileRecord(host: "worked.com", profile: .privateLane, outcome: .worked)
        
        // Even if category says canvas and scanner says passthrough, worked memory wins
        let result = RecommendationResolver.resolve(
            siteRecord: workedRecord,
            categoryWinner: .canvasPipeline,
            scannerDefault: .passthrough
        )
        #expect(result.profile == .privateLane)
        #expect(result.memoryInformed == true)
    }

    @Test func resolverPrefersCategoryWinnerOverScannerDefault() async throws {
        // No site record
        let result = RecommendationResolver.resolve(
            siteRecord: nil,
            categoryWinner: .privateLane,
            scannerDefault: .canvasPipeline
        )
        #expect(result.profile == .privateLane)
        #expect(result.memoryInformed == false)
    }

    @Test func resolverFallsBackToScannerDefaultWhenNoMemoryAndNoCategoryWinner() async throws {
        let result = RecommendationResolver.resolve(
            siteRecord: nil,
            categoryWinner: nil,
            scannerDefault: .canvasPipeline
        )
        #expect(result.profile == .canvasPipeline)
        #expect(result.memoryInformed == false)
    }

    @Test func resolverSteersAwayFromFailedMemory() async throws {
        let failedRecord = SiteProfileRecord(host: "failed.com", profile: .rawFramePipe, outcome: .failed)
        
        // If category winner is different, use it
        let result1 = RecommendationResolver.resolve(
            siteRecord: failedRecord,
            categoryWinner: .privateLane,
            scannerDefault: .canvasPipeline
        )
        #expect(result1.profile == .privateLane)
        #expect(result1.memoryInformed == true)

        // If category winner is the one that failed, but scanner default is different, use scanner default
        let result2 = RecommendationResolver.resolve(
            siteRecord: failedRecord,
            categoryWinner: .rawFramePipe,
            scannerDefault: .canvasPipeline
        )
        #expect(result2.profile == .canvasPipeline)
        #expect(result2.memoryInformed == true)

        // If both category and scanner default are the failed method, it picks the first displayOrder alternative
        let result3 = RecommendationResolver.resolve(
            siteRecord: failedRecord,
            categoryWinner: .rawFramePipe,
            scannerDefault: .rawFramePipe
        )
        // first display order alt not equal to rawFramePipe and passthrough is canvasPipeline
        #expect(result3.profile == .canvasPipeline)
        #expect(result3.memoryInformed == true)
    }

    // MARK: - Sequence Builder & Resolver

    @Test func builderOmitsTargetAndContainsExpectedKeys() async throws {
        let step = SequenceStepScript(id: "uuid1", kindJS: "photo", blockJS: "once", liveJS: "serve", surfaceJS: "either", img: "img1", vid: nil, empty: false)
        let arrayJS = SequenceScriptBuilder.sequenceArrayJS([step])
        #expect(!arrayJS.contains("target:"))
        #expect(arrayJS.contains("id:"))
        #expect(arrayJS.contains("kind:"))
        #expect(arrayJS.contains("block:"))
        #expect(arrayJS.contains("live:"))
        #expect(arrayJS.contains("surface:"))
        #expect(arrayJS.contains("img:"))
        #expect(arrayJS.contains("vid:"))
        #expect(arrayJS.contains("empty:"))
    }

    // MARK: - Per-step request surface

    @Test func requestSurfaceDefaultsToEitherAndKeepsLegacyBehavior() async throws {
        let step = SequenceStep(kind: .photo)
        #expect(step.requestSurface == .either)
        // A sequence saved before this setting existed decodes as nil.
        let json = """
        {
            "id": "1E7B9C4A-0000-4000-8000-000000000001",
            "kind": "photo",
            "blockMode": "once",
            "displayName": "legacy"
        }
        """.data(using: .utf8)!
        let saved = try JSONDecoder().decode(SavedSequenceStep.self, from: json)
        #expect(saved.requestSurface == nil)
    }

    @Test func requestSurfaceEmitsTheTokenTheEngineReads() async throws {
        #expect(RequestSurface.either.jsValue == "either")
        #expect(RequestSurface.liveCamera.jsValue == "live")
        #expect(RequestSurface.nativeCamera.jsValue == "native")
    }

    @Test func surfaceReservedStepsAreEmittedSoEachSurfaceCanSkipTheOther() async throws {
        let live = SequenceStepScript(id: "a", kindJS: "photo", blockJS: "once", liveJS: "serve", surfaceJS: "live", img: "i1", vid: nil, empty: false)
        let native = SequenceStepScript(id: "b", kindJS: "photo", blockJS: "once", liveJS: "serve", surfaceJS: "native", img: "i2", vid: nil, empty: false)
        let arrayJS = SequenceScriptBuilder.sequenceArrayJS([live, native])
        #expect(arrayJS.contains(#"surface:"live""#))
        #expect(arrayJS.contains(#"surface:"native""#))
    }

    // MARK: - Ask-me-every-request settings

    @Test func askModeIsOffByDefaultAndAsksForNothing() async throws {
        let settings = CameraPromptSettings.off
        #expect(settings.isEnabled == false)
        for kind in CameraRequestKind.allCases {
            #expect(settings.asks(for: kind) == false)
        }
        #expect(settings.enabledKindsSummary == "Off")
    }

    @Test func askModeHonorsPerKindSelectionOnceEnabled() async throws {
        var settings = CameraPromptSettings(isEnabled: true, askForLiveCamera: true, askForNativeCamera: false, askForFilePick: false)
        #expect(settings.asks(for: .liveCamera) == true)
        #expect(settings.asks(for: .nativeCamera) == false)
        #expect(settings.asks(for: .filePick) == false)
        settings.isEnabled = false
        // The master switch always wins.
        #expect(settings.asks(for: .liveCamera) == false)
    }

    @Test func rememberedActionsMapToTheEngineTokens() async throws {
        #expect(CameraRequestAction.serveNext.jsValue == "serve")
        #expect(CameraRequestAction.block.jsValue == "block")
        #expect(CameraRequestAction.realCamera.jsValue == "real")
    }

    // MARK: - Request origin keying

    @Test func siteRulesKeyOffTheAddressThatActuallyAsked() async throws {
        #expect(BrowserViewModel.host(fromOrigin: "https://frame.vendor.example/widget?x=1") == "frame.vendor.example")
        #expect(BrowserViewModel.host(fromOrigin: "") == nil)
        #expect(BrowserViewModel.host(fromOrigin: "not a url") == nil)
    }

    // MARK: - Capture photo shape

    @Test func strippedCaptureJPEGAlwaysFitsTheInPageBudget() async throws {
        // A camera capture must always be deliverable as bytes carried inside the
        // page, so a locked-down site can never push it onto a blockable route.
        let service = EXIFMetadataService()
        let large = solidImage(width: 2400, height: 1800)
        let budget = 120_000
        let data = try #require(service.strippedJPEGData(image: large, maxBytes: budget))
        #expect(data.count <= budget)
        #expect(data.count > 0)
    }

    @Test func strippedCaptureJPEGCarriesNoLocationOrCameraTags() async throws {
        let service = EXIFMetadataService()
        let data = try #require(service.strippedJPEGData(image: solidImage(width: 64, height: 48), maxBytes: 400_000))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil)
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifLensModel as String] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFModel as String] == nil)
    }

    @Test func libraryPickJPEGKeepsItsFullCameraDetails() async throws {
        // Library / file picks are deliberately untouched by the capture rules.
        let service = EXIFMetadataService()
        let data = try #require(service.jpegDataWithEXIF(
            image: solidImage(width: 64, height: 48),
            camera: nil,
            hardware: nil
        ))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "Apple")
    }

    @Test func strippedCaptureBytesAvailableThroughTheStepHandler() async throws {
        let handler = LocalResourceHandler()
        let id = "capture-shape"
        handler.setStepImageSource(
            ImageInjectionSource(
                image: solidImage(width: 1200, height: 900),
                camera: nil,
                hardware: nil,
                latitude: 51.5,
                longitude: -0.12,
                altitude: 20
            ),
            id: id
        )
        let budget = 90_000
        let stripped = try #require(handler.strippedJPEGDataForStep(id, maxBytes: budget))
        #expect(stripped.count <= budget)
        // Even though the source carried GPS, the capture variant does not.
        let source = try #require(CGImageSourceCreateWithData(stripped as CFData, nil))
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil)
    }
    
    @Test func builderActiveMethods() async throws {
        for kind in InjectionMethodKind.displayOrder {
            let stateJS = SequenceScriptBuilder.stateFieldsJS(mode: "advance", end: "hold", method: kind.jsValue, active: true)
            #expect(stateJS.contains("s._method='\(kind.jsValue)'"))
        }
    }
    
    @Test func builderActiveFlagAndEmptyMedia() async throws {
        let activeOn = SequenceScriptBuilder.stateFieldsJS(mode: "advance", end: "hold", method: "canvasPipeline", active: true)
        #expect(activeOn.contains("s.a=true"))
        
        let activeOff = SequenceScriptBuilder.stateFieldsJS(mode: "advance", end: "hold", method: "canvasPipeline", active: false)
        #expect(activeOff.contains("s.a=false"))
        
        let emptyStep = SequenceStepScript(id: "uuid2", kindJS: "photo", blockJS: "once", liveJS: "serve", surfaceJS: "either", img: nil, vid: nil, empty: true)
        let emptyJS = SequenceScriptBuilder.stepObjectJS(emptyStep)
        #expect(emptyJS.contains("empty:true"))
        #expect(emptyJS.contains("img:null"))
        #expect(emptyJS.contains("vid:null"))
        
        let mediaStep = SequenceStepScript(id: "uuid3", kindJS: "photo", blockJS: "once", liveJS: "serve", surfaceJS: "either", img: "token123", vid: nil, empty: false)
        let mediaJS = SequenceScriptBuilder.stepObjectJS(mediaStep)
        #expect(mediaJS.contains("empty:false"))
        #expect(mediaJS.contains(#"img:"token123""#))
    }
    
    @Test func resolverAdvanceEachWalksAndAdvances() async throws {
        let step = ResolverStep(kind: .photo, blockMode: .once, liveCamera: .serveLive, isEmpty: false)
        let steps = [step, step, step]
        
        let r0 = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .holdLast, pointer: 0, held: nil, isInjecting: true)
        #expect(r0.action == .serve(index: 0))
        #expect(r0.pointer == 1)
        
        let r1 = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .holdLast, pointer: 1, held: 0, isInjecting: true)
        #expect(r1.action == .serve(index: 1))
        #expect(r1.pointer == 2)
        
        let r2 = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .holdLast, pointer: 2, held: 1, isInjecting: true)
        #expect(r2.action == .serve(index: 2))
        #expect(r2.pointer == 3)
    }
    
    @Test func resolverHoldCurrentServesWithoutAdvancing() async throws {
        let step = ResolverStep(kind: .photo, blockMode: .once, liveCamera: .serveLive, isEmpty: false)
        let steps = [step, step, step]
        
        let r1 = SequenceAdvanceResolver.resolve(steps: steps, mode: .holdCurrent, end: .holdLast, pointer: 1, held: nil, isInjecting: true)
        #expect(r1.action == .serve(index: 1))
        #expect(r1.pointer == 1)
    }
    
    @Test func resolverEndBehaviorsAtExhaustion() async throws {
        let step = ResolverStep(kind: .photo, blockMode: .once, liveCamera: .serveLive, isEmpty: false)
        let steps = [step, step]
        
        let rHold = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .holdLast, pointer: 2, held: 1, isInjecting: true)
        #expect(rHold.action == .serve(index: 1))
        
        let rLoop = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .loop, pointer: 2, held: 1, isInjecting: true)
        #expect(rLoop.action == .serve(index: 0))
        #expect(rLoop.pointer == 1)
        
        let rRealInjecting = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .realCamera, pointer: 2, held: 1, isInjecting: true)
        #expect(rRealInjecting.action == .blockWebRTC)
        
        let rRealNotInjecting = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .realCamera, pointer: 2, held: 1, isInjecting: false)
        #expect(rRealNotInjecting.action == .real)
        
        let rRefuse = SequenceAdvanceResolver.resolve(steps: steps, mode: .advanceEach, end: .refuse, pointer: 2, held: 1, isInjecting: true)
        #expect(rRefuse.action == .blockWebRTC)
    }
    
    @Test func resolverStepKindRules() async throws {
        let webRTC = ResolverStep(kind: .webRTCBlock, blockMode: .once, liveCamera: .serveLive, isEmpty: false)
        let rWeb = SequenceAdvanceResolver.resolve(steps: [webRTC], mode: .advanceEach, end: .holdLast, pointer: 0, held: nil, isInjecting: true)
        #expect(rWeb.action == .blockWebRTC)
        #expect(rWeb.pointer == 1)
        
        let blockOnce = ResolverStep(kind: .block, blockMode: .once, liveCamera: .serveLive, isEmpty: false)
        let rOnce = SequenceAdvanceResolver.resolve(steps: [blockOnce], mode: .advanceEach, end: .holdLast, pointer: 0, held: nil, isInjecting: true)
        #expect(rOnce.action == .blockWebRTC)
        #expect(rOnce.pointer == 1)
        
        let blockFromHere = ResolverStep(kind: .block, blockMode: .fromHereOn, liveCamera: .serveLive, isEmpty: false)
        let rFrom = SequenceAdvanceResolver.resolve(steps: [blockFromHere], mode: .advanceEach, end: .holdLast, pointer: 0, held: nil, isInjecting: true)
        #expect(rFrom.action == .blockWebRTC)
        #expect(rFrom.pointer == 0)
        
        let liveBlock = ResolverStep(kind: .photo, blockMode: .once, liveCamera: .block, isEmpty: false)
        let rLive = SequenceAdvanceResolver.resolve(steps: [liveBlock], mode: .advanceEach, end: .holdLast, pointer: 0, held: nil, isInjecting: true)
        #expect(rLive.action == .blockWebRTC)
        #expect(rLive.pointer == 0)
    }

    // MARK: - Injected still orientation (putImageData pixel path)
    //
    // The live camera feed prefers the raw RGBA pixel path (putImageData). If the
    // extracted buffer is vertically flipped, injected stills render upside-down
    // even when the JPEG/EXIF path is correct. This locks row 0 = visual top and
    // column 0 = visual left through the exact public API the renderer uses:
    // setStepImageSource -> rgbaPixelDataForStep.

    @Test func rgbaPixelDataKeepsTopLeftOriginForInjectedStill() async throws {
        let handler = LocalResourceHandler()
        let id = "orientation-test"
        handler.setStepImageSource(
            ImageInjectionSource(
                image: quadrantImage(),
                camera: nil,
                hardware: nil,
                latitude: nil,
                longitude: nil,
                altitude: nil
            ),
            id: id
        )

        let pixels = try #require(handler.rgbaPixelDataForStep(id, targetWidth: 4, targetHeight: 4))
        #expect(pixels.width == 4)
        #expect(pixels.height == 4)

        let bytes = [UInt8](pixels.data)
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * pixels.width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        // Corners must line up with the quadrants as drawn (top-left origin).
        let topLeft = rgb(0, 0)
        let topRight = rgb(3, 0)
        let bottomLeft = rgb(0, 3)
        let bottomRight = rgb(3, 3)

        #expect(topLeft.r > 200 && topLeft.g < 60 && topLeft.b < 60)          // red
        #expect(topRight.r < 60 && topRight.g > 200 && topRight.b < 60)       // green
        #expect(bottomLeft.r < 60 && bottomLeft.g < 60 && bottomLeft.b > 200) // blue
        #expect(bottomRight.r > 200 && bottomRight.g > 200 && bottomRight.b > 200) // white
    }

    /// 4x4 image split into four solid quadrants, each a distinct primary color,
    /// so a flip or mirror is unambiguous when reading back the RGBA buffer.
    private func quadrantImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))   // top-left
            UIColor.green.setFill()
            context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))   // top-right
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 2, width: 2, height: 2))   // bottom-left
            UIColor.white.setFill()
            context.fill(CGRect(x: 2, y: 2, width: 2, height: 2))   // bottom-right
        }
    }
}
