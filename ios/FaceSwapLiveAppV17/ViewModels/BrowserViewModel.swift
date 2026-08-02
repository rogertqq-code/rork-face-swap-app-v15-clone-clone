import SwiftUI
import WebKit
import AVFoundation
import Network
import UIKit

struct TrackedFrame: Identifiable {
    var id: String { "\(navigationSessionID)_\(origin)" }
    let frameInfo: WKFrameInfo
    let navigationSessionID: String
    let origin: String
}

@Observable
@MainActor
final class BrowserViewModel {
    var urlText: String = ""
    var currentURL: URL? {
        didSet {
            urlText = currentURL?.absoluteString ?? ""
        }
    }
    var pageTitle: String = ""
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var estimatedProgress: Double = 0

    var pendingNavigationURL: URL?

    var bookmarks: [Bookmark] = []
    var showBookmarks: Bool = false
    var showOverlayPanel: Bool = false

    // MARK: - Sequence state

    var sequence: [SequenceStep] = []
    var advanceMode: SequenceAdvanceMode = .advanceEach
    var endBehavior: SequenceEndBehavior = .holdLast
    private(set) var sequenceVersion: Int = 0

    /// Live pointers reported back from the page so the UI can show how far each
    /// camera has advanced and highlight the step currently being served.
    var pointer: Int = 0
    /// Native picker progress is intentionally isolated from the live/WebRTC cursor.
    var nativePickerPointer: Int = 0
    var lastServedStepID: UUID?
    var lastAction: String = ""
    /// Monotonic token for an optimistic toolbar advance. A late JavaScript
    /// failure must never roll back a newer manual selection.
    private var manualAdvanceAttemptID: Int = 0

    // MARK: - Native camera capture screen

    /// True while a native camera hand-off is in flight, so the app can present
    /// the camera-style screen for exactly that window.
    var isNativeCaptureActive: Bool = false
    /// Set briefly when the queued photo lands, driving the shutter flash.
    var nativeCaptureDidFire: Bool = false
    /// Plain-language note when a hand-off could not be completed.
    var nativeCaptureFailure: String = ""
    /// Plain-language note when a LIVE camera request was refused or diverted.
    ///
    /// A gate that stops a request must never be silent: that is exactly how the
    /// injection appeared "completely broken" while the delivery engine was fine.
    var liveRequestNotice: String = ""
    /// Per-hand-off token issued by the page. Delayed callbacks from an old page or
    /// another frame are ignored unless they match this active request.
    private var activeNativeCaptureToken: String?

    // MARK: - Ask-me-every-request

    /// Opt-in settings for pausing each camera request (default off).
    let cameraPrompt = CameraPromptStore.shared
    /// The request currently paused and awaiting the user's decision.
    var pendingCameraRequest: PendingCameraRequest?
    /// The frame each paused request came from, so the answer is delivered back to
    /// the exact frame that asked (an embedded frame can otherwise never be told).
    private var requestFrames: [String: WKFrameInfo] = [:]
    /// Frames that have talked to us on this page, so state pushes reach embedded
    /// frames instead of only the top-level document.
    private var knownTrackedFrames: [TrackedFrame] = []

    // MARK: - Live feed engine readout

    /// Which feed engine the page reported actually engaging for the live
    /// stream: "vtg" (clean worker-backed track), "canvas", or "" (none yet).
    var liveFeedRaw: String = ""
    /// Delivery lane of the clean feed reported by the page: "private" when the
    /// Private Lane method carried it, otherwise "".
    var liveFeedLaneRaw: String = ""
    /// True when a clean-feed method fell back to Canvas for the live stream.
    var liveFeedDowngraded: Bool = false
    /// Reason code for the active feed / downgrade (mapped via `InjectionFeed`).
    var liveFeedReasonRaw: String = ""
    /// Which frame source produced the clean feed: "webcodecs" (new frame engine
    /// decoding straight to frames) or "element" (media-element backed).
    var liveFeedEngineRaw: String = ""

    /// True once a live in-page stream has actually engaged a feed engine.
    var liveFeedEngaged: Bool { !liveFeedRaw.isEmpty }
    /// The clean worker-backed track is the live feed.
    var liveFeedIsClean: Bool { liveFeedRaw == "vtg" }
    /// The live clean feed is running through the app-only private lane.
    var liveFeedIsPrivateLane: Bool { liveFeedIsClean && liveFeedLaneRaw == "private" }
    /// A still photo under Video Direct that intentionally uses the Canvas draw.
    var liveFeedIntentionalCanvas: Bool { liveFeedReasonRaw == "photo-step" }
    /// A clean-feed method that genuinely downgraded to Canvas (not the photo case).
    var liveFeedDidDowngrade: Bool { liveFeedDowngraded && !liveFeedIntentionalCanvas }
    /// Plain-language reason for a downgrade or intentional Canvas draw.
    var liveFeedReasonText: String { InjectionFeed.reasonText(liveFeedReasonRaw) }
    /// Plain-language description of the clean-feed frame source, when engaged.
    var liveFeedEngineText: String {
        switch liveFeedEngineRaw {
        case "webcodecs": return "Frames decoded straight from your video — no hidden player."
        case "element": return "Frames streamed from a hidden player."
        default: return ""
        }
    }

    // MARK: - Engine armed self-check

    /// Whether the in-page camera-takeover interception is genuinely installed.
    /// Verified right after media turns on and each time a page settles; if the
    /// engine state loaded but the takeover is missing, the app re-installs it.
    var engineArmed: Bool = true
    /// Plain-language reason the takeover failed to arm, when `engineArmed` is false.
    var engineArmError: String = ""
    /// True once at least one arm check has run for the current injecting session,
    /// so the indicator only appears after we actually know the state.
    var engineArmChecked: Bool = false
    /// True while an arm verification round-trip is in flight (de-dupes checks).
    private var isVerifyingArm: Bool = false

    var isMediaActive: Bool = false

    // MARK: - Deterministic delivery lifecycle

    /// Changes on every top-level navigation. Page messages must echo this token
    /// before they can update UI state or complete a queued-media request.
    private(set) var navigationSessionID: String = UUID().uuidString
    /// Monotonic version for direct WebKit state pushes. The page drops lower
    /// versions so a late evaluation cannot overwrite a newer edit or navigation.
    private var runtimeStateVersion: Int = 0
    /// Compact, persistent readout shown above the browser while media is active.
    var mediaDeliveryStatus: MediaDeliveryStatus = .idle
    var mediaDeliveryDetail: String = "Waiting for a camera request."
    var activeMediaRequestID: String = ""
    var activeMediaRequestOrigin: String = ""
    private(set) var mediaDeliveryEvents: [MediaDeliveryEvent] = []

    // MARK: - Eyedeekit mode (additive, default off)

    /// When true, this session's native document picker serves photo steps only
    /// (reserving the front selfie video for the live camera), and the doc
    /// hand-off uses `docHoldRange`. The main Browser tab never sets this, so
    /// its serving and timing behavior stays byte-for-byte unchanged.
    var eyedeekitMode: Bool = false
    /// Eyedeekit-only native document hand-off delay window (ms). nil = the app
    /// default used everywhere else.
    var docHoldRange: ClosedRange<Int>?

    var isOverlayActive: Bool = false
    var overlayOpacity: Double = 1.0
    var showBurnConfirmation: Bool = false
    var isBurning: Bool = false

    /// Shown when the user tries to enable media while Passthrough is the active
    /// method. Passthrough means "use the real camera" — turning Enable Media on
    /// would set `s.a=true` on the page but the JS gates route to real hardware.
    /// The warning offers to switch to Auto instead of silently doing nothing.
    var showPassthroughWarning: Bool = false
    var isProbingCurrentSite: Bool = false
    var probeStatus: String = ""
    var isInspectingCurrentSite: Bool = false
    var inspectionStatus: String = ""

    /// Drives the single unified Analyze Site results sheet (merges the old
    /// Scan, Inspect, and Probe actions into one place).
    var showAnalyzeSite: Bool = false

    /// True while either half of a site analysis (inspection or probe) is running.
    var isAnalyzingSite: Bool { isInspectingCurrentSite || isProbingCurrentSite }

    // MARK: - Lifecycle transaction

    private var lifecycleTransactionTask: Task<Void, Never>?

    private func performLifecycleTransaction(action: @escaping @MainActor () async -> Void) {
        lifecycleTransactionTask?.cancel()
        lifecycleTransactionTask = Task { @MainActor in
            if Task.isCancelled { return }
            await action()
        }
    }

    // MARK: - Adaptive injection
    /// media is fed into the page: canvas capture, video direct, raw frame
    /// pipe, or passthrough (real camera).
    var activeInjectionProfile: InjectionMethodKind = .auto

    /// Optional network-side tools layered on top of the selected camera method.
    /// These never change the feed engine; they only add request/script blocking
    /// and/or the local rewrite proxy around the page.
    var activeNetworkBackend: NetworkBackendOptions = .off
    /// The most recent scanner result for the current site, if any.
    var latestDetectedSystem: DetectedSystem?
    /// Predicted and observed camera request summaries learned from page getUserMedia calls.
    var cameraRequestInsights: [CameraRequestInsight] = []
    var latestCameraRequestInsight: CameraRequestInsight?

    let runtimeCoordinator = WebRuntimeCoordinator()
    weak var webView: WKWebView? {
        didSet {
            runtimeCoordinator.setWebView(webView)
        }
    }
    let schemeHandler = LocalResourceHandler()
    let imageSchemeHandler = LocalResourceHandler()
    var activeProfile: DeviceProfile?
    /// Owns the profile-scoped verification record used to decide whether a
    /// stored device recommendation has enough concrete evidence to be applied.
    var verificationStore: OfflineVerificationStore?
    /// Shared with the My Media tab so Quick Load always reflects the same
    /// collection. Injected by the browser container on appear.
    var videoLibrary = VideoLibraryService()
    let sequenceLibrary = SequenceLibraryService()
    let constraintLog = ConstraintLogService()
    let siteHistory = SiteHistoryService()
    let injectionInspector = InjectionInspectionService()
    let siteMemory = SiteProfileMemoryService()
    private let detectionScanner = DetectionScannerService()
    var onActiveProfileUpdated: ((DeviceProfile) -> Void)?

    private let mediaConverter = MediaConverterService()
    let payloadCache = SequencePayloadCache()
    private var payloadGenerationByStepID: [UUID: Int] = [:]
    /// Generation guard for the async chunk-demux task so a rapid re-assign
    /// never lets a stale demux overwrite fresher chunks.
    private var chunkGenerationByStepID: [UUID: Int] = [:]
    /// Video step IDs whose WebCodecs chunk bundle is demuxed and ready to serve.
    private var chunkReadyStepIDs: Set<UUID> = []
    private let maxInlineRawPixelBytes: Int = 4_250_000
    private let maxInlineJPEGBytes: Int = 1_400_000
    /// Safety timer: if photo payload re-extraction hasn't produced a state push
    /// within 2 seconds of activation, force one so the page is never left
    /// without an active-state snapshot. Cancelled when any push fires or when
    /// injection is deactivated.
    private var mediaActivationSafetyTask: Task<Void, Never>?

    // MARK: - Derived sequence helpers

    var canAddStep: Bool { sequence.count < maxSequenceSteps }
    var hasServableStep: Bool { sequence.contains { $0.isServable } }
    var hasMedia: Bool { sequence.contains { ($0.kind == .photo || $0.kind == .video) && ($0.image != nil || $0.videoURL != nil) } }

    /// The step the UI should highlight as "live" — the last served step if known,
    /// otherwise the next step the active pointer would consume.
    var activeStep: SequenceStep? {
        if let id = lastServedStepID, let match = sequence.first(where: { $0.id == id }) {
            return match
        }
        let idx = pointer
        if idx >= 0 && idx < sequence.count { return sequence[idx] }
        return sequence.first
    }

    var overlayPreviewImage: UIImage? {
        if let step = activeStep, step.kind == .photo, let image = step.image { return image }
        return sequence.first(where: { $0.kind == .photo && $0.image != nil })?.image
    }

    var overlayPreviewVideoURL: URL? {
        if let step = activeStep, step.kind == .video, let url = step.videoURL { return url }
        return sequence.first(where: { $0.kind == .video && $0.videoURL != nil })?.videoURL
    }

    /// Advancement counters for the active mode, shown in the controls.
    var advanced: Int { pointer }

    private let bookmarksKey = "browser_bookmarks_v1"
    private let defaultBookmarkSeededKey = "browser_default_bookmark_seeded_v1"
    static let defaultBookmarkURL = "https://kyctest.work.app"
    private let injectionProfileKey = "active_injection_profile_v1"
    private let networkBackendKey = "active_network_backend_v1"

    /// Tracks whether the experimental content-blocking rule list is currently
    /// attached to the web view, so we never add it twice or leave it on after
    /// switching to another method.
    private var networkFilterApplied: Bool = false

    /// Controller for the experimental Network Rewrite local proxy.
    private let rewriteProxy = NetworkRewriteProxyService.shared

    init() {
        loadBookmarks()
        loadNetworkBackend()
        loadInjectionProfile()
    }

    // MARK: - Deterministic delivery lifecycle

    /// Begins a new top-level navigation session. All pending request/frame links
    /// are invalid after this point, so late messages from the outgoing document
    /// cannot complete a request on the incoming page.
    func beginNavigation() {
        performLifecycleTransaction { [weak self] in
            guard let self else { return }
            self.navigationSessionID = UUID().uuidString
            self.runtimeStateVersion &+= 1
            self.resetCameraRequestState()
            self.activeMediaRequestID = ""
            self.activeMediaRequestOrigin = ""
            self.mediaDeliveryStatus = self.isMediaActive ? .preparing : .idle
            self.mediaDeliveryDetail = self.isMediaActive
                ? "Loading a new page and binding its media runtime."
                : "Loading a new page."
            ConnectionLogService.shared.log(.navigation, "Navigation started \u{2014} session=\(self.navigationSessionID) url=\(self.currentURL?.host ?? "unknown") mediaActive=\(self.isMediaActive)")
        }
    }

    func markPageFinishedLoading() {
        performLifecycleTransaction { [weak self] in
            guard let self else { return }
            guard self.isMediaActive else {
                self.mediaDeliveryStatus = .pageReady
                self.mediaDeliveryDetail = "Page ready. Media serving is off."
                ConnectionLogService.shared.log(.navigation, "Page finished loading \u{2014} media inactive")
                return
            }
            self.mediaDeliveryStatus = .preparing
            self.mediaDeliveryDetail = "Page loaded. Waiting for the runtime state acknowledgement."
            ConnectionLogService.shared.log(.navigation, "Page finished loading \u{2014} waiting for runtime state ack, session=\(self.navigationSessionID)")
        }
    }

    func markPageLoadFailed() {
        performLifecycleTransaction { [weak self] in
            guard let self else { return }
            self.mediaDeliveryStatus = .needsAttention
            self.mediaDeliveryDetail = "The page did not finish loading, so queued media was not armed. Reload the page to try again."
            ConnectionLogService.shared.error("Page load failed \u{2014} session=\(self.navigationSessionID) url=\(self.currentURL?.host ?? "unknown")")
        }
    }


    /// Derives origin and frame identity from WebKit rather than trusting fields
    /// sent by the page.
    func bridgeContext(for frame: WKFrameInfo, expectedSessionID: String? = nil) -> MediaBridgeContext? {
        let securityOrigin = frame.securityOrigin
        let scheme = securityOrigin.protocol.lowercased()
        let host = securityOrigin.host.lowercased()
        if let expectedSessionID, expectedSessionID != navigationSessionID { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let portSuffix = securityOrigin.port > 0 && securityOrigin.port != defaultPort
            ? ":\(securityOrigin.port)"
            : ""
        let origin = "\(scheme)://\(host)\(portSuffix)"
        return MediaBridgeContext(
            navigationSessionID: navigationSessionID,
            origin: origin,
            frameURL: frame.request.url?.absoluteString ?? origin,
            isMainFrame: frame.isMainFrame
        )
    }

    /// Called when a fresh document has asked for its runtime snapshot through the
    /// reply bridge. The reply itself carries the state; this only updates UI.
    func noteRuntimeBridgeReady(context: MediaBridgeContext) {
        guard isMediaActive else { return }
        mediaDeliveryStatus = .preparing
        mediaDeliveryDetail = context.isMainFrame
            ? "Connecting queued media to the current page."
            : "Connecting queued media to an embedded page."
        ConnectionLogService.shared.log(.runtimeState, "Runtime bridge ready \u{2014} session=\(context.navigationSessionID) origin=\(context.origin) isMainFrame=\(context.isMainFrame)")
    }

    /// Accepts a lifecycle event only if its originating frame and session still
    /// match the page being displayed. Events from a prior navigation are ignored.
    func handleMediaLifecycle(_ body: [String: Any], context: MediaBridgeContext) {
        guard let phaseRaw = body["phase"] as? String,
              let phase = MediaDeliveryPhase(rawValue: phaseRaw),
              let sessionID = body["session"] as? String,
              sessionID == navigationSessionID else { return }
        let sequenceValue = (body["sequenceVersion"] as? NSNumber)?.intValue
            ?? (body["sequenceVersion"] as? Int)
            ?? sequenceVersion
        guard sequenceValue == sequenceVersion else { return }

        let requestID = body["requestId"] as? String ?? ""
        let reason = body["reason"] as? String ?? ""
        let detail = body["detail"] as? String ?? ""
        let frameOffset = (body["frameOffsetMs"] as? NSNumber)?.doubleValue
        let event = MediaDeliveryEvent(
            phase: phase,
            requestID: requestID,
            navigationSessionID: sessionID,
            sequenceVersion: sequenceValue,
            context: context,
            reason: reason,
            detail: detail,
            frameTimestampOffsetMs: frameOffset
        )
        mediaDeliveryEvents.insert(event, at: 0)
        if mediaDeliveryEvents.count > 48 {
            mediaDeliveryEvents = Array(mediaDeliveryEvents.prefix(48))
        }

        mediaDeliveryStatus = phase.status
        mediaDeliveryDetail = deliveryDetail(for: phase, reason: reason, detail: detail)
        if !requestID.isEmpty {
            activeMediaRequestID = requestID
            activeMediaRequestOrigin = context.origin
        }
        if phase == .requestCompleted || phase == .requestRejected || phase == .requestCancelled {
            activeMediaRequestID = ""
        }
        ConnectionLogService.shared.log(.lifecycle, "Lifecycle phase=\(phase.rawValue) request=\(requestID) reason=\(reason) origin=\(context.origin) seqV=\(sequenceValue)")
        if phase == .requestRejected || phase == .requestCancelled {
            ConnectionLogService.shared.error("Request \(phase.rawValue) \u{2014} request=\(requestID) reason=\(reason) detail=\(detail) origin=\(context.origin)")
        }
        if phase == .pageReady, isMediaActive {
            verifyEngineArmed()
        }
    }

    func retryMediaDelivery() {
        guard webView != nil else { return }
        performLifecycleTransaction { [weak self] in
            guard let self else { return }
            self.mediaDeliveryStatus = .preparing
            self.mediaDeliveryDetail = "Re-arming the current page. Trigger the page request again when it is ready."
            ConnectionLogService.shared.log(.mediaActivation, "Manual retry \u{2014} re-arming page, session=\(self.navigationSessionID)")
            self.syncMediaToPage()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard isMediaActive else { return }
        ConnectionLogService.shared.log(.info, "Scene phase changed \u{2014} \(phase) session=\(navigationSessionID)")
        performLifecycleTransaction { [weak self] in
            guard let self else { return }
            switch phase {
            case .background:
                self.mediaDeliveryStatus = .needsAttention
                self.mediaDeliveryDetail = "The app is in the background. Delivery will re-check when you return."
                // Fire-and-forget signal: non-blocking so we don't hang if WebKit
                // suspends before the JS evaluation completes.
                self.runtimeCoordinator.evaluate(StyleSheetProvider.pageLifecycleSignalScript(phase: .pageSuspended))
            case .active:
                self.mediaDeliveryStatus = .pageReady
                self.mediaDeliveryDetail = "The app returned to the foreground. Rechecking the active page."
                self.syncMediaToPage()
                self.runtimeCoordinator.evaluate(StyleSheetProvider.pageLifecycleSignalScript(phase: .pageResumed))
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    func noteNativePanelSuppressed(kind: String, context: MediaBridgeContext) {
        let event = MediaDeliveryEvent(
            phase: .requestRejected,
            requestID: "",
            navigationSessionID: navigationSessionID,
            sequenceVersion: sequenceVersion,
            context: context,
            reason: "native-\(kind)-panel-cancelled",
            detail: "The browser cancelled this page's \(kind) panel instead of opening a system sheet."
        )
        ConnectionLogService.shared.error("Native panel suppressed \u{2014} kind=\(kind) origin=\(context.origin)")
        mediaDeliveryEvents.insert(event, at: 0)
        if mediaDeliveryEvents.count > 48 {
            mediaDeliveryEvents = Array(mediaDeliveryEvents.prefix(48))
        }
        mediaDeliveryStatus = .blocked
        mediaDeliveryDetail = "This page requested a \(kind) panel. It was cancelled by the browser, so no system sheet interrupted media delivery."
    }

    /// Core decision for whether WebKit should grant camera/mic permission to the
    /// page, independent of the WKSecurityOrigin/WKFrameInfo that the delegate
    /// callback receives (which can't be constructed in unit tests). Exposed for
    /// testability so the passthrough-grant path can be verified without a live
    /// web view.
    /// - Returns: `.grant` when the real camera should flow (passthrough, or media
    ///   is off and no saved block exists); `.deny` when injection intercepts the
    ///   request (media active, non-passthrough method).
    enum WebMediaCaptureDecision: String, Sendable { case grant, deny }
    var webMediaCaptureDecision: WebMediaCaptureDecision {
        if isMediaActive {
            // Passthrough means "use the real camera." The JS getUserMedia gate
            // routes passthrough to origGUM, so WebKit must grant permission for
            // the real camera to flow through. Denying here would block it at the
            // native level, making the "Use real camera anyway" dialog useless.
            if effectiveInjectionMethod == .passthrough {
                return .grant
            }
            return .deny
        }
        return .grant
    }

    /// Returns the native WebKit permission decision for a concrete capture type.
    /// Audio-only requests must remain usable while a virtual video feed is active:
    /// the page-side getUserMedia gate only replaces video, so denying the microphone
    /// here incorrectly breaks legitimate voice-only features.
    func webMediaCaptureDecision(for type: WKMediaCaptureType, originHost: String) -> WebMediaCaptureDecision {
        switch type {
        case .microphone:
            return cameraPrompt.rule(for: originHost) == .block ? .deny : .grant
        case .camera, .cameraAndMicrophone:
            return webMediaCaptureDecision
        @unknown default:
            return .deny
        }
    }

    func shouldGrantWebMediaCapture(for origin: WKSecurityOrigin, frame: WKFrameInfo) -> Bool {
        shouldGrantWebMediaCapture(for: origin, frame: frame, type: .camera)
    }

    func shouldGrantWebMediaCapture(
        for origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) -> Bool {
        let decision = webMediaCaptureDecision(for: type, originHost: origin.host)
        guard decision == .deny else {
            ConnectionLogService.shared.log(.request, "WebKit granting capture \u{2014} type=\(type.rawValue) host=\(origin.host) decision=grant")
            return true
        }
        if type != .microphone, let context = bridgeContext(for: frame) {
            noteNativePanelSuppressed(kind: "camera or microphone", context: context)
        }
        ConnectionLogService.shared.log(.request, "WebKit denying capture \u{2014} type=\(type.rawValue) host=\(origin.host) decision=deny")
        return false
    }

    /// Determines whether a non-web app URL names a camera-related handoff.
    /// Kept pure so the navigation policy is independently testable.
    static func isCameraCustomSchemeURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        let isWebRoute = scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" || scheme == "blob"
        guard !isWebRoute else { return false }

        let route = url.absoluteString.lowercased()
        return route.contains("camera") || route.contains("takephoto") || route.contains("capture")
    }

    /// Blocks a camera-related app URL only while optional SDK interception is on
    /// and injected media is active. Web URLs are never included: their normal
    /// camera boundary remains the getUserMedia/file-input interception layer.
    func shouldBlockCameraCustomScheme(_ url: URL) -> Bool {
        guard isMediaActive,
              effectiveInjectionMethod != .passthrough,
              SdkInterceptionStore.shared.isEnabled else {
            return false
        }
        return Self.isCameraCustomSchemeURL(url)
    }

    func noteCameraCustomSchemeBlocked(_ url: URL) {
        mediaDeliveryStatus = .blocked
        mediaDeliveryDetail = "Blocked a camera-related app URL while injected media is active: \(url.scheme ?? "custom") scheme."
        lastAction = "blockedCustomCameraScheme"
    }

    private func deliveryDetail(for phase: MediaDeliveryPhase, reason: String, detail: String) -> String {
        if !detail.isEmpty { return detail }
        switch phase {
        case .pageReady:
            return "The page accepted the latest media state."
        case .requestSeen:
            return "The page requested queued media."
        case .queueResolved:
            return "A queued media item was selected."
        case .mediaPrepared:
            return "Preparing the selected media item."
        case .feedBuilt:
            return "A media stream was created."
        case .mediaConnected:
            return "The media stream is connected to this request."
        case .framesFlowing:
            return "Frames are reaching the active stream."
        case .requestCompleted:
            return "The request completed successfully."
        case .requestRejected:
            return reason.isEmpty ? "The request was rejected." : "The request was rejected: \(reason)."
        case .requestCancelled:
            return reason.isEmpty ? "The request was cancelled." : "The request was cancelled: \(reason)."
        case .pageSuspended:
            return "The page is suspended."
        case .pageResumed:
            return "The page resumed."
        }
    }

    // MARK: - Injection methods

    /// Whether the active method serves media at all.
    private var methodServesMedia: Bool { activeInjectionProfile.servesMedia }

    /// True when Auto — not the user — is choosing the delivery route.
    var isAutoResolving: Bool { activeInjectionProfile == .auto }

    /// The CONCRETE delivery route in play right now.
    ///
    /// Auto is a user-facing choice, not something the page can act on. It is
    /// resolved here — what already worked on this site, then what the site scan
    /// detected, then the device's own tested default, then the universal canvas
    /// baseline — so the engine is never handed a placeholder it cannot deliver.
    var effectiveInjectionMethod: InjectionMethodKind {
        guard isAutoResolving else { return activeInjectionProfile.migratedCameraMethod }

        if let record = currentSiteRecord, record.outcome == .worked {
            let learned = record.profile.migratedCameraMethod
            if learned != .auto, learned.servesMedia { return learned }
        }
        if let detected = latestDetectedSystem?.baseRecommendation.migratedCameraMethod,
           detected != .auto, detected.servesMedia {
            return detected
        }
        if let deviceDefault = activeProfile?.recommendedMethod?.migratedCameraMethod,
           deviceDefault != .auto, deviceDefault.servesMedia {
            return deviceDefault
        }
        // Canvas is the route every other method degrades to, so it is the only
        // honest universal baseline.
        return .canvasPipeline
    }

    /// Handheld motion for still photos. Follows the sensor-realism switch only.
    ///
    /// Forcing it on for Auto (the default) meant it was on for everyone, which
    /// silently disabled the fastest way of drawing an image on every serve.
    private var servesPhotosAsMotion: Bool {
        SensorRealismStore.shared.isEnabled
    }

    /// What the user should see as the active route, naming the resolved method
    /// whenever Auto picked it rather than hiding it behind the word "Auto".
    var activeMethodDisplayName: String {
        isAutoResolving
            ? "Auto → \(effectiveInjectionMethod.label)"
            : activeInjectionProfile.label
    }

    /// The memory record for the site currently shown, if one exists.
    var currentSiteRecord: SiteProfileRecord? {
        guard let host = currentURL?.host() else { return nil }
        return siteMemory.record(for: host)
    }

    private func loadInjectionProfile() {
        guard let raw = UserDefaults.standard.string(forKey: injectionProfileKey),
              let result = Self.migrateLoadedProfile(raw) else { return }
        
        if let legacyBackend = result.network {
            activeNetworkBackend = legacyBackend
            saveNetworkBackend()
        }
        activeInjectionProfile = result.profile
        UserDefaults.standard.set(activeInjectionProfile.rawValue, forKey: injectionProfileKey)
    }

    static func migrateLoadedProfile(_ raw: String) -> (profile: InjectionMethodKind, network: NetworkBackendOptions?)? {
        guard let kind = InjectionMethodKind(rawValue: raw) else { return nil }
        return (kind.migratedCameraMethod, kind.migratedNetworkBackend)
    }

    private func loadNetworkBackend() {
        guard let data = UserDefaults.standard.data(forKey: networkBackendKey),
              let decoded = try? JSONDecoder().decode(NetworkBackendOptions.self, from: data) else { return }
        activeNetworkBackend = decoded
    }

    private func saveNetworkBackend() {
        guard let data = try? JSONEncoder().encode(activeNetworkBackend) else { return }
        UserDefaults.standard.set(data, forKey: networkBackendKey)
    }

    /// Switches the active profile, persists it, applies it live to the page,
    /// and optionally remembers the choice for the current site.
    func setInjectionProfile(_ kind: InjectionMethodKind, rememberForSite: Bool = false) {
        let migratedKind = kind.migratedCameraMethod
        let legacyBackend = kind.migratedNetworkBackend
        let nextBackend = legacyBackend ?? activeNetworkBackend
        guard migratedKind != activeInjectionProfile || nextBackend != activeNetworkBackend || rememberForSite else { return }
        activeInjectionProfile = migratedKind
        activeNetworkBackend = nextBackend
        UserDefaults.standard.set(migratedKind.rawValue, forKey: injectionProfileKey)
        saveNetworkBackend()
        // The feed will re-engage on the next request; clear the stale readout so
        // it never shows the previous method's feed after a switch.
        resetLiveFeedReadout()
        if rememberForSite, let host = currentURL?.host() {
            siteMemory.confirm(profile: migratedKind, networkBackend: activeNetworkBackend, host: host, detected: latestDetectedSystem)
        }
        updateUserScripts()
        syncContentFilter()
        syncProxyConfiguration()
        syncMediaToPage()
    }

    /// Toggles one of the optional network backend tools without changing the
    /// current camera delivery method. The active site remembers the new switch
    /// state so reloads and future visits restore the same backend.
    func setNetworkBackend(_ options: NetworkBackendOptions, rememberForSite: Bool = true) {
        guard options != activeNetworkBackend || rememberForSite else { return }
        activeNetworkBackend = options
        saveNetworkBackend()
        if rememberForSite, let host = currentURL?.host() {
            siteMemory.setNetworkBackend(options, for: host, profile: activeInjectionProfile, detected: latestDetectedSystem)
        }
        updateUserScripts()
        syncContentFilter()
        syncProxyConfiguration()
        syncMediaToPage()
    }

    func setBlockDetectionScriptsEnabled(_ enabled: Bool) {
        var next = activeNetworkBackend
        next.blockDetectionScripts = enabled
        setNetworkBackend(next)
    }

    func setRewriteProxyEnabled(_ enabled: Bool) {
        var next = activeNetworkBackend
        next.useRewriteProxy = enabled
        setNetworkBackend(next)
    }

    /// Restores the remembered camera method and network backend for the current
    /// host, if the site has a saved record. Called after navigation settles so
    /// per-site settings come back automatically.
    func restoreSiteMemoryForCurrentPage() {
        guard let url = currentURL else { return }
        restoreSiteMemory(for: url)
    }

    /// Restores a remembered setup before a navigation starts. This lets the
    /// optional content blocker, rewrite proxy, and document-start scripts match
    /// the destination site as early as WebKit allows.
    func restoreSiteMemory(for url: URL) {
        guard let host = url.host(), let record = siteMemory.record(for: host) else { return }
        let nextProfile = record.profile.migratedCameraMethod
        let nextBackend = record.networkBackend
        guard nextProfile != activeInjectionProfile || nextBackend != activeNetworkBackend else { return }
        activeInjectionProfile = nextProfile
        activeNetworkBackend = nextBackend
        UserDefaults.standard.set(nextProfile.rawValue, forKey: injectionProfileKey)
        saveNetworkBackend()
        resetLiveFeedReadout()
        updateUserScripts()
        syncContentFilter()
        syncProxyConfiguration()
        syncMediaToPage()
    }

    /// Attaches or detaches the optional Network Backend content-blocking rule
    /// list to match the Block Detection Scripts switch. Compilation is async;
    /// the page must be reloaded for the filter to take effect (surfaced in UI).
    private func syncContentFilter() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        if activeNetworkBackend.blockDetectionScripts {
            guard !networkFilterApplied else { return }
            networkFilterApplied = true
            Task { [weak self] in
                guard let list = await NetworkFilterService.shared.ruleList() else {
                    self?.networkFilterApplied = false
                    return
                }
                guard let self, self.activeNetworkBackend.blockDetectionScripts,
                      let wv = self.webView else { return }
                wv.configuration.userContentController.add(list)
            }
        } else if networkFilterApplied {
            controller.removeAllContentRuleLists()
            networkFilterApplied = false
        }
    }

    /// Resets per-web-view content-filter state and re-applies the filter for the
    /// active backend switch. A freshly created web view starts with no content
    /// rule lists, so the cached "applied" flag would otherwise be stale and the
    /// network backend would silently stop filtering after the browser returns
    /// home and navigates again.
    func resetContentFilterState() {
        networkFilterApplied = false
        syncContentFilter()
        syncProxyConfiguration()
    }

    /// Starts or stops the optional Network Rewrite proxy to match the backend
    /// switch, and points the web view's data store at it once it is running.
    /// Fails safe: if the proxy can't start, the proxy configuration is cleared
    /// and the selected camera feed continues normally.
    private func syncProxyConfiguration() {
        guard let webView else { return }
        if activeNetworkBackend.useRewriteProxy {
            Task { [weak self] in
                guard let self else { return }
                let ready = await self.rewriteProxy.start()
                guard self.activeNetworkBackend.useRewriteProxy, let wv = self.webView else { return }
                wv.configuration.websiteDataStore.proxyConfigurations = ready ? self.rewriteProxy.activeProxyConfigurations : []
            }
        } else {
            webView.configuration.websiteDataStore.proxyConfigurations = []
            rewriteProxy.shutdown()
        }
    }

    /// Applies the recommended profile from the latest scan and remembers it.
    func confirmRecommendedProfile() {
        guard let detected = latestDetectedSystem else { return }
        setInjectionProfile(detected.recommendedProfile, rememberForSite: true)
    }

    /// Automatically applies the recommended method as a base default if the site has no confirmed memory.
    func applyRecommendedMethodIfNoSiteMemory() {
        guard let host = currentURL?.host() else { return }
        let record = siteMemory.record(for: host)
        
        // If there's a confirmed .worked record, do not auto-apply.
        if record?.outcome == .worked { return }
        
        // A method already saved on the profile is an existing working setting, so
        // it is applied normally. Verification gates WRITING a new recommendation
        // (see DiagnosticsTestHarness), never reading one the device already has.
        let deviceDefault = activeProfile?.recommendedMethod

        let recommended: InjectionMethodKind
        if let detected = latestDetectedSystem {
            let blended = siteMemory.recommendation(
                forHost: host,
                category: detected.category,
                deviceDefault: deviceDefault,
                scannerDefault: detected.baseRecommendation
            )
            recommended = blended.profile
        } else if let fallback = deviceDefault {
            recommended = fallback
        } else {
            return
        }
        
        setInjectionProfile(recommended, rememberForSite: false)
    }

    /// Records the user's thumbs up / down verdict for the current site.
    func setCurrentSiteOutcome(_ outcome: SiteOutcome) {
        guard let host = currentURL?.host() else { return }
        if siteMemory.record(for: host) == nil {
            siteMemory.confirm(profile: activeInjectionProfile, networkBackend: activeNetworkBackend, host: host, detected: latestDetectedSystem)
        }
        siteMemory.setOutcome(outcome, for: host)
    }

    func navigateTo(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL?
        if trimmed.contains(".") && !trimmed.contains(" ") {
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                url = URL(string: trimmed)
            } else {
                url = URL(string: "https://\(trimmed)")
            }
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            url = URL(string: "https://www.google.com/search?q=\(query)")
        }

        guard let validURL = url else { return }
        currentURL = validURL
        restoreSiteMemory(for: validURL)
        pendingNavigationURL = validURL
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func handleWebContentProcessTerminated() {
        webView?.reload()
    }

    func goHome() {
        webView?.configuration.websiteDataStore.proxyConfigurations = []
        rewriteProxy.shutdown()
        currentURL = nil
        urlText = ""
        webView = nil
    }

    func addBookmark() {
        guard let url = currentURL else { return }
        let title = pageTitle.isEmpty ? url.host() ?? url.absoluteString : pageTitle
        guard !bookmarks.contains(where: { $0.urlString == url.absoluteString }) else { return }
        let bookmark = Bookmark(title: title, urlString: url.absoluteString)
        bookmarks.insert(bookmark, at: 0)
        saveBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }

    func isCurrentPageBookmarked() -> Bool {
        guard let url = currentURL else { return false }
        return bookmarks.contains { $0.urlString == url.absoluteString }
    }

    // MARK: - Sequence editing

    private func canonicalCamera() -> CameraDeviceSpec? {
        return activeProfile?.backCamera ?? activeProfile?.frontCamera
    }

    private func bumpVersion() { sequenceVersion += 1 }

    /// Appends a new step (placeholder for photo/video, ready-to-go for block).
    @discardableResult
    func addStep(
        kind: SequenceStepKind,
        blockMode: SequenceBlockMode = .once,
        requestSurface: RequestSurface = .either
    ) -> UUID? {
        guard canAddStep else { return nil }
        let step = SequenceStep(
            kind: kind,
            blockMode: blockMode,
            requestSurface: requestSurface,
            displayName: defaultDisplayName(for: kind)
        )
        sequence.append(step)
        bumpVersion()
        pushSequence()
        return step.id
    }

    private func defaultDisplayName(for kind: SequenceStepKind) -> String {
        switch kind {
        case .photo, .video: ""
        case .webRTCBlock: "Block WebRTC Once"
        case .block: "Stream Block"
        }
    }

    func setStepBlockMode(_ mode: SequenceBlockMode, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].blockMode = mode
        bumpVersion()
        pushSequence()
    }

    /// Sets whether a photo/video step serves or blocks the live in-page camera.
    /// The upload/"Take Photo" picker stays faked regardless of this setting.
    func setStepLiveCamera(_ mode: LiveCameraMode, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].liveCamera = mode
        bumpVersion()
        pushSequence()
    }

    /// Sets which kind of camera request a media step answers. `.either` (the
    /// default) keeps the original behavior: the step answers both surfaces.
    func setStepRequestSurface(_ surface: RequestSurface, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].requestSurface = surface
        bumpVersion()
        pushSequence()
    }

    func markStepImporting(_ stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].isConverting = true
        sequence[idx].conversionProgress = 0
        bumpVersion()
    }

    func markStepImportFailed(_ stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].isConverting = false
        sequence[idx].conversionProgress = 0
        bumpVersion()
    }

    /// Assigns a still image to a photo step, generating its EXIF source.
    func setStepImage(_ image: UIImage, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].image = image
        if sequence[idx].displayName.isEmpty { sequence[idx].displayName = "Photo" }
        let idString = stepID.uuidString
        let cam = canonicalCamera()

        if let profile = activeProfile, let cam {
            let spec = profile.conversionSpec(for: cam)
            let converter = mediaConverter
            let hardware = profile.deviceHardware
            sequence[idx].isConverting = true
            sequence[idx].conversionProgress = 0
            imageSchemeHandler.setStepImageSource(nil, id: idString)
            payloadCache.removePayload(for: stepID)
            Task.detached { [weak self] in
                let converted = converter.resizeImageForInjection(image, spec: spec)
                let source = ImageInjectionSource(
                    image: converted,
                    camera: cam,
                    hardware: hardware,
                    latitude: nil,
                    longitude: nil,
                    altitude: nil
                )
                await MainActor.run {
                    guard let self,
                          let i = self.sequence.firstIndex(where: { $0.id == stepID }),
                          self.sequence[i].image === image else { return }
                    self.sequence[i].image = converted
                    self.sequence[i].isConverting = false
                    self.imageSchemeHandler.setStepImageSource(source, id: idString)
                    // Pre-compute and cache pixel + JPEG data outside observable sequence state.
                    self.populateStepCache(for: stepID)
                    self.bumpVersion()
                    self.pushSequence()
                }
            }
        } else {
            let normalizedImage = image.normalizedForInjection()
            let source = ImageInjectionSource(
                image: normalizedImage,
                camera: cam,
                hardware: activeProfile?.deviceHardware,
                latitude: nil,
                longitude: nil,
                altitude: nil
            )
            sequence[idx].image = normalizedImage
            sequence[idx].isConverting = false
            sequence[idx].conversionProgress = 0
            imageSchemeHandler.setStepImageSource(source, id: idString)
            payloadCache.removePayload(for: stepID)
            populateStepCache(for: stepID)
            bumpVersion()
            pushSequence()
        }
    }

    /// Transcodes and assigns a video chosen from the photo library.
    func setStepVideo(_ url: URL, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        if sequence[idx].ownsVideoFile, let old = sequence[idx].videoURL {
            try? FileManager.default.removeItem(at: old)
        }
        sequence[idx].videoURL = url
        sequence[idx].ownsVideoFile = false
        if sequence[idx].displayName.isEmpty { sequence[idx].displayName = "Video" }
        let idString = stepID.uuidString
        let cam = canonicalCamera()

        if let profile = activeProfile, let cam {
            let spec = profile.conversionSpec(for: cam)
            let converter = mediaConverter
            sequence[idx].isConverting = true
            sequence[idx].conversionProgress = 0
            schemeHandler.setStepVideoURL(nil, id: idString)
            payloadCache.removePayload(for: stepID)
            Task { [weak self] in
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("seq_\(idString)_\(UUID().uuidString).mov")
                let success = await converter.convertVideoWithProgress(url, spec: spec, outputURL: outputURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let i = self.sequence.firstIndex(where: { $0.id == stepID }),
                              self.sequence[i].videoURL == url else { return }
                        self.sequence[i].conversionProgress = progress
                    }
                }
                await MainActor.run {
                    guard let self,
                          let i = self.sequence.firstIndex(where: { $0.id == stepID }),
                          self.sequence[i].videoURL == url else {
                        if success { try? FileManager.default.removeItem(at: outputURL) }
                        return
                    }
                    if success {
                        self.sequence[i].videoURL = outputURL
                        self.sequence[i].ownsVideoFile = true
                        self.schemeHandler.setStepVideoURL(outputURL, id: idString)
                        self.cacheFirstFramePayload(for: stepID, videoURL: outputURL)
                        self.cacheVideoChunks(for: stepID, videoURL: outputURL)
                    } else {
                        self.schemeHandler.setStepVideoURL(url, id: idString)
                        self.cacheFirstFramePayload(for: stepID, videoURL: url)
                        self.cacheVideoChunks(for: stepID, videoURL: url)
                    }
                    self.sequence[i].isConverting = false
                    self.sequence[i].conversionProgress = 0
                    self.bumpVersion()
                    self.pushSequence()
                }
            }
        } else {
            sequence[idx].isConverting = false
            sequence[idx].conversionProgress = 0
            schemeHandler.setStepVideoURL(url, id: idString)
            payloadCache.removePayload(for: stepID)
            cacheFirstFramePayload(for: stepID, videoURL: url)
            cacheVideoChunks(for: stepID, videoURL: url)
            bumpVersion()
            pushSequence()
        }
    }

    /// Assigns an already-converted library video without re-transcoding.
    func assignLibraryVideo(_ url: URL, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        sequence[idx].videoURL = url
        sequence[idx].ownsVideoFile = false
        sequence[idx].isConverting = false
        schemeHandler.setStepVideoURL(url, id: stepID.uuidString)
        cacheFirstFramePayload(for: stepID, videoURL: url)
        cacheVideoChunks(for: stepID, videoURL: url)
        bumpVersion()
        pushSequence()
    }

    /// Assigns an already-rendered library image without reprocessing.
    func assignLibraryImage(_ image: UIImage, name: String, for stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        let cam = canonicalCamera()
        let normalizedImage = image.normalizedForInjection()
        let source = ImageInjectionSource(
            image: normalizedImage,
            camera: cam,
            hardware: activeProfile?.deviceHardware,
            latitude: nil,
            longitude: nil,
            altitude: nil
        )
        sequence[idx].image = normalizedImage
        sequence[idx].displayName = name
        sequence[idx].isConverting = false
        sequence[idx].conversionProgress = 0
        imageSchemeHandler.setStepImageSource(source, id: stepID.uuidString)
        populateStepCache(for: stepID)
        bumpVersion()
        pushSequence()
    }

    /// Adds a single already-converted library video as a new step.
    func addLibraryVideoStep(_ url: URL, name: String) {
        guard canAddStep else { return }
        let step = SequenceStep(kind: .video, displayName: name)
        sequence.append(step)
        assignLibraryVideo(url, for: step.id)
    }

    /// Adds a single already-rendered library image as a new step.
    func addLibraryImageStep(_ image: UIImage, name: String) {
        guard canAddStep else { return }
        let step = SequenceStep(kind: .photo, displayName: name)
        sequence.append(step)
        assignLibraryImage(image, name: name, for: step.id)
    }

    func addMediaVariantStep(_ variant: SavedMediaVariant, mediaName: String) {
        guard canAddStep, let url = videoLibrary.variantURL(for: variant) else { return }
        switch variant.kind {
        case .image:
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
            addLibraryImageStep(image, name: mediaName)
        case .video:
            addLibraryVideoStep(url, name: mediaName)
        }
    }

    /// Drops a saved media item's variants straight into the sequence.
    func loadSavedVideoIntoSequence(_ video: SavedVideo) {
        let variants = video.allVariants.prefix(maxSequenceSteps - sequence.count)
        if !variants.isEmpty {
            for variant in variants where canAddStep {
                addMediaVariantStep(variant, mediaName: video.name)
            }
            return
        }
        if let frontURL = videoLibrary.frontVideoURL(for: video) ?? videoLibrary.backVideoURL(for: video), canAddStep {
            let step = SequenceStep(kind: .video, displayName: video.name)
            sequence.append(step)
            assignLibraryVideo(frontURL, for: step.id)
        }
    }

    func removeStep(_ stepID: UUID) {
        guard let idx = sequence.firstIndex(where: { $0.id == stepID }) else { return }
        let step = sequence[idx]
        if step.ownsVideoFile, let url = step.videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        imageSchemeHandler.setStepImageSource(nil, id: stepID.uuidString)
        schemeHandler.setStepVideoURL(nil, id: stepID.uuidString)
        schemeHandler.setStepChunkData(nil, id: stepID.uuidString)
        payloadCache.removePayload(for: stepID)
        payloadGenerationByStepID.removeValue(forKey: stepID)
        chunkReadyStepIDs.remove(stepID)
        chunkGenerationByStepID.removeValue(forKey: stepID)
        sequence.remove(at: idx)
        if sequence.isEmpty {
            disableMedia()
            isOverlayActive = false
        }
        bumpVersion()
        pushSequence()
    }

    func moveStep(from source: IndexSet, to destination: Int) {
        sequence.move(fromOffsets: source, toOffset: destination)
        bumpVersion()
        pushSequence()
    }

    func resetPosition() {
        pointer = 0
        lastServedStepID = nil
        lastAction = ""
        bumpVersion()
        pushSequence()
    }

    /// Whether a step is a media step the toolbar should advance to: photo/video
    /// with actual media loaded and not still converting. Block and empty
    /// placeholder steps are live-surface instructions, not media the user would
    /// want to manually switch to.
    private func isMediaStepForAdvance(_ step: SequenceStep) -> Bool {
        guard (step.kind == .photo || step.kind == .video),
              !step.isConverting,
              step.image != nil || step.videoURL != nil else { return false }
        return true
    }

    /// Manually advances the live sequence to the next servable step. Called by
    /// the "Next Media" toolbar button. Computes the next index using the same
    /// skip-non-servable logic as the JS `firstLiveIndexFrom` — skips block and
    /// empty steps, wraps per `endBehavior` — then pushes the new pointer to the
    /// page via `window.fslSetPointer` WITHOUT bumping the sequence version.
    @discardableResult
    func advanceSequence() -> Bool {
        guard isMediaActive, sequence.count > 1 else { return false }

        let currentIdx = min(max(0, pointer), sequence.count - 1)
        let startIdx = currentIdx + 1

        // Find the next servable media step. This mirrors the JS
        // firstLiveIndexFrom: block/webrtcBlock and empty placeholders are
        // live-surface instructions (not media the toolbar should switch to),
        // so we skip them and only advance to a photo/video step that carries
        // actual media. A converting step is also skipped — the page has no
        // payload for it yet, so serving it would black out the camera.
        var nextIdx = -1
        for i in startIdx..<sequence.count {
            if isMediaStepForAdvance(sequence[i]) { nextIdx = i; break }
        }
        if nextIdx < 0 {
            // Wrap to the beginning and search from 0 up to currentIdx.
            for i in 0...currentIdx {
                if isMediaStepForAdvance(sequence[i]) { nextIdx = i; break }
            }
        }

        guard nextIdx >= 0, nextIdx != currentIdx else {
            // Nothing else to advance to. For refuse/holdLast, no-op. For loop,
            // if we somehow couldn't find anything different, also no-op.
            return false
        }

        // HoldLast clamps at the end — don't wrap.
        if endBehavior == .holdLast && nextIdx <= currentIdx {
            return false
        }
        // Refuse stops at the end — don't wrap.
        if endBehavior == .refuse && nextIdx <= currentIdx {
            return false
        }
        // RealCamera stops at the end and does NOT wrap — wrapping would
        // replay media when the user chose to hand the real camera back.
        if endBehavior == .realCamera && nextIdx <= currentIdx {
            return false
        }

        let previousPointer = pointer
        let previousServedStepID = lastServedStepID
        let previousAction = lastAction
        pointer = nextIdx
        let step = sequence[nextIdx]
        lastServedStepID = step.id
        lastAction = "manualAdvance"
        bumpVersion()

        // Push the new pointer to the page AND bump the sequence version.
        // callAsyncJavaScript waits for fslSetPointer's Promise, unlike a plain
        // evaluation, so a failed active-stream swap can restore this optimistic
        // UI state instead of leaving the toolbar out of sync with the page.
        guard let webView else { return true }
        manualAdvanceAttemptID &+= 1
        let attemptID = manualAdvanceAttemptID
        let nextVersion = sequenceVersion

        webView.callAsyncJavaScript(
            "return window.fslSetPointer(pointer, sequenceVersion);",
            arguments: ["pointer": nextIdx, "sequenceVersion": nextVersion],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, self.manualAdvanceAttemptID == attemptID else { return }
            guard case .failure = result else { return }
            // A page bridge message may already have authoritatively advanced the
            // pointer while this error was in flight. Only roll back our own
            // untouched optimistic state.
            guard self.pointer == nextIdx, self.lastAction == "manualAdvance" else { return }
            self.pointer = previousPointer
            self.lastServedStepID = previousServedStepID
            self.lastAction = previousAction
            self.bumpVersion() // Invalidate bad state
            self.mediaDeliveryStatus = .needsAttention
            self.mediaDeliveryDetail = "The page could not switch to the selected media. The previous selection remains active."
        }
        return true
    }

    func setAdvanceMode(_ mode: SequenceAdvanceMode) {
        advanceMode = mode
        bumpVersion()
        pushSequence()
    }

    func setEndBehavior(_ behavior: SequenceEndBehavior) {
        endBehavior = behavior
        pushSequence()
    }

    /// Empties the sequence, tears down any live feed, and returns the page to
    /// the real camera — no refresh required.
    func clearSequence() {
        for step in sequence where step.ownsVideoFile {
            if let url = step.videoURL { try? FileManager.default.removeItem(at: url) }
        }
        sequence.removeAll()
        imageSchemeHandler.clearStepSources()
        schemeHandler.clearStepSources()
        payloadCache.removeAll()
        payloadGenerationByStepID.removeAll()
        chunkReadyStepIDs.removeAll()
        chunkGenerationByStepID.removeAll()
        pointer = 0
        lastServedStepID = nil
        lastAction = ""
        disableMedia()
        isOverlayActive = false
        overlayOpacity = 1.0
        resetLiveFeedReadout()
        bumpVersion()
        updateUserScripts()
        teardownInjectionOnPage()
    }

    /// Pushes the recorder flag as part of the same versioned state snapshot as
    /// the sequence, preventing a recorder toggle from racing a media update.
    func syncFailureRecorderState() {
        syncMediaToPage()
    }

    /// Flips media serving from the toolbar. Reports whether it actually
    /// changed, so the caller can open the media list instead of silently doing
    /// nothing when there is nothing to serve.
    @discardableResult
    func toggleMediaServing() -> Bool {
        let next = !isMediaActive
        guard hasServableStep || !next else { return false }
        if next {
            enableMedia()
        } else {
            disableMedia()
        }
        return true
    }

    func setMediaActive(_ active: Bool) {
        guard hasServableStep || !active else { return }
        // Passthrough means "use the real camera." Turning Enable Media on with
        // passthrough selected would set s.a=true but every JS gate routes to
        // real hardware, so the toggle would look on while nothing changes.
        // Warn the user and let them choose to switch to Auto instead.
        if active && activeInjectionProfile == .passthrough {
            showPassthroughWarning = true
            return
        }
        if active {
            enableMedia()
        } else {
            disableMedia()
        }
    }

    /// Called by the passthrough warning dialog when the user confirms they want
    /// to use the real camera with media enabled (s.a=true, method=passthrough).
    func confirmPassthroughActivation() {
        showPassthroughWarning = false
        enableMedia()
    }

    /// Called by the passthrough warning dialog when the user chooses to switch
    /// to Auto and start serving queued media.
    func switchToAutoAndActivate() {
        showPassthroughWarning = false
        activeInjectionProfile = .auto
        UserDefaults.standard.set(InjectionMethodKind.auto.rawValue, forKey: injectionProfileKey)
        enableMedia()
    }

    func enableMedia() {
        isMediaActive = true
        runtimeStateVersion &+= 1
        updateUserScripts()
        // D-05: Ensure photo payloads are prepared before pushing state so the
        // page has inline bytes available, then arm the safety timer as a
        // fallback if async extraction stalls.
        rebuildAllPhotoPayloads()
        armMediaActivationSafetyTimer()
        syncMediaToPage()
        verifyEngineArmed()
    }

    func disableMedia() {
        isMediaActive = false
        mediaActivationSafetyTask?.cancel()
        mediaActivationSafetyTask = nil
        resetLiveFeedReadout()
        resetCameraRequestState()
        mediaDeliveryStatus = .idle
        mediaDeliveryDetail = "Media serving is off."
        syncMediaToPage()
    }

    /// Confirms the camera-takeover interception is armed in the page and
    /// self-heals it if the engine state loaded but the takeover is missing.
    /// Called after media turns on and each time a page settles. Only meaningful
    /// while actually injecting, so it no-ops otherwise.
    func verifyEngineArmed() {
        guard let webView, isMediaActive, hasServableStep else {
            resetEngineArmReadout()
            return
        }
        guard !isVerifyingArm else { return }
        isVerifyingArm = true
        let sessionID = navigationSessionID
        Task { [weak self] in
            guard let self else { return }
            let raw = try? await self.runtimeCoordinator.evaluate(StyleSheetProvider.engineArmCheckScript)
            guard self.navigationSessionID == sessionID, self.webView === webView else {
                self.isVerifyingArm = false
                return
            }
            self.isVerifyingArm = false
            guard let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.engineArmed = false
                self.engineArmError = "Couldn't read the camera engine — reload the site."
                self.engineArmChecked = true
                self.mediaDeliveryStatus = .needsAttention
                self.mediaDeliveryDetail = self.engineArmError ?? ""
                return
            }
            let present = (obj["present"] as? Bool) ?? ((obj["present"] as? NSNumber)?.boolValue ?? false)
            let armed = (obj["armed"] as? Bool) ?? ((obj["armed"] as? NSNumber)?.boolValue ?? false)
            let rawError = obj["error"] as? String ?? ""
            self.engineArmed = present && armed
            let failureText = (present && armed) ? "" : Self.armFailureText(present: present, rawError: rawError)
            self.engineArmError = failureText
            self.engineArmChecked = true
            ConnectionLogService.shared.log(.engineArm, "Engine arm check \u{2014} present=\(present) armed=\(armed) error=\(rawError) session=\(sessionID)")
            if !present || !armed {
                self.mediaDeliveryStatus = .needsAttention
                self.mediaDeliveryDetail = failureText
                ConnectionLogService.shared.error("Engine arm failed \u{2014} present=\(present) armed=\(armed) error=\(rawError) session=\(sessionID)")
            }
        }
    }

    /// Clears the engine-armed readout so the indicator hides when not injecting.
    private func resetEngineArmReadout() {
        engineArmChecked = false
        engineArmed = true
        engineArmError = ""
    }

    static func armFailureText(present: Bool, rawError: String) -> String {
        if !present { return "The camera engine hasn't loaded on this page yet — reload the site." }
        if rawError.isEmpty { return "The camera takeover didn't install. Reload the site to re-arm it." }
        return "The camera takeover didn't fully install (\(rawError)). Reload the site to re-arm it."
    }

    /// Clears the live feed engine readout (no feed engaged yet).
    private func resetLiveFeedReadout() {
        liveFeedRaw = ""
        liveFeedLaneRaw = ""
        liveFeedDowngraded = false
        liveFeedReasonRaw = ""
        liveFeedEngineRaw = ""
    }

    /// Handles the native camera hand-off lifecycle reported by the page so the
    /// app can show a real camera-style screen for the capture window and record
    /// the outcome instead of failing silently.
    /// Presents a paused camera request. If the user has already chosen "always do
    /// this for this site", the remembered answer is applied immediately so the
    /// page is never held up.
    func presentCameraRequest(
        token: String,
        kindRaw: String,
        facing: String,
        width: Int?,
        height: Int?,
        frameRate: Int?,
        origin: String,
        isFrame: Bool
    ) {
        let kind = CameraRequestKind(rawValue: kindRaw) ?? .nativeCamera
        // Key the remembered answer off the address that ACTUALLY made the request,
        // so an embedded frame is never judged by the top-level host.
        let host = Self.host(fromOrigin: origin) ?? currentURL?.host() ?? ""
        if let remembered = cameraPrompt.rule(for: host) {
            resolveCameraRequest(token: token, action: remembered, rememberForSite: false)
            return
        }
        // A second request while one is already showing takes the configured
        // default rather than silently replacing the visible prompt.
        if pendingCameraRequest != nil {
            resolveCameraRequest(
                token: token,
                action: cameraPrompt.settings.defaultAction,
                rememberForSite: false
            )
            return
        }
        pendingCameraRequest = PendingCameraRequest(
            id: token,
            kind: kind,
            facing: facing,
            requestedWidth: width,
            requestedHeight: height,
            requestedFrameRate: frameRate,
            origin: origin,
            isFrame: isFrame,
            receivedAt: Date()
        )
        Haptics.selection()
    }

    /// Applies the user's decision to a paused request and releases the page.
    /// When `stepID` is supplied the engine serves that exact queued item for this
    /// one request instead of taking the next in line.
    func resolveCameraRequest(
        token: String,
        action: CameraRequestAction,
        rememberForSite: Bool,
        stepID: UUID? = nil
    ) {
        // Remember against the address that made the request, not whatever the
        // top-level page happens to be.
        let requestHost = Self.host(fromOrigin: pendingCameraRequest?.id == token
            ? (pendingCameraRequest?.origin ?? "")
            : "")
        if rememberForSite {
            let host = requestHost ?? currentURL?.host() ?? ""
            if !host.isEmpty {
                cameraPrompt.remember(action, for: host)
                // A newly saved rule has to reach the page that is already open.
                syncCameraPromptState()
            }
        }
        if pendingCameraRequest?.id == token {
            pendingCameraRequest = nil
        }
        let frame = requestFrames.removeValue(forKey: token)
        let safeToken = token.replacingOccurrences(of: "'", with: "")
        let pickArg = stepID.map { ",'\($0.uuidString)'" } ?? ""
        let js = "(function(){try{var s=window[Symbol.for('fsl')];"
            + "if(s&&s._resolveAsk)s._resolveAsk('\(safeToken)','\(action.jsValue)'\(pickArg));}catch(e){}})();"
        // Answer the frame that asked. A request from an embedded frame is never
        // resolvable from the main frame, so this is what unblocks it.
        if let frame, !frame.isMainFrame, let webView {
            Task { @MainActor in
                _ = try? await webView.evaluateJavaScript(js, in: frame, in: .page)
            }
        } else {
            runtimeCoordinator.evaluate(js)
        }
        // Reflect the outcome in the visible activity readout.
        switch action {
        case .serveNext: break
        case .block: lastAction = "blockWebRTC"
        case .realCamera: lastAction = "realCamera"
        }
    }

    /// The page told us a paused request timed out and applied the default action.
    /// Clearing the card here is what stops a stale, undismissable prompt from
    /// blocking every later request.
    func cameraRequestTimedOut(token: String) {
        requestFrames.removeValue(forKey: token)
        guard pendingCameraRequest?.id == token else { return }
        pendingCameraRequest = nil
    }

    /// Remembers which frame a paused request arrived from.
    func noteCameraRequestFrame(_ frame: WKFrameInfo?, token: String) {
        guard let frame else { return }
        requestFrames[token] = frame
    }

    /// Tracks frames that have talked to us so state pushes can reach them.
    func noteActiveFrame(_ frame: WKFrameInfo?, context: MediaBridgeContext) {
        guard let frame, !frame.isMainFrame else { return }
        guard context.navigationSessionID == self.navigationSessionID else { return }
        
        let tracked = TrackedFrame(
            frameInfo: frame,
            navigationSessionID: context.navigationSessionID,
            origin: context.origin
        )
        if !knownTrackedFrames.contains(where: { $0.id == tracked.id }) {
            knownTrackedFrames.append(tracked)
            if knownTrackedFrames.count > 8 {
                knownTrackedFrames.removeFirst(knownTrackedFrames.count - 8)
            }
        }
    }

    /// Drops per-page request/frame bookkeeping on a fresh navigation.
    func resetCameraRequestState() {
        requestFrames.removeAll()
        knownTrackedFrames.removeAll()
        pendingCameraRequest = nil
        activeNativeCaptureToken = nil
        isNativeCaptureActive = false
        nativeCaptureDidFire = false
    }

    /// Camera-request policy now travels with the same versioned runtime state as
    /// the media sequence, including every known embedded requester.
    func syncCameraPromptState() {
        syncMediaToPage()
    }

    /// Queue items that can actually answer a given request kind, so the question
    /// card never offers an item that could not (or should not) be served to it.
    func servableSteps(for kind: CameraRequestKind) -> [SequenceStep] {
        sequence.filter { step in
            guard step.image != nil || step.videoURL != nil, !step.isConverting else { return false }
            switch kind {
            case .liveCamera:
                return step.requestSurface != .nativeCamera
            case .nativeCamera, .filePick:
                return step.requestSurface != .liveCamera
            }
        }
    }

    /// Host of a page/frame origin string, when it parses.
    nonisolated static func host(fromOrigin origin: String) -> String? {
        guard !origin.isEmpty,
              let url = URL(string: origin),
              let host = url.host,
              !host.isEmpty else { return nil }
        return host
    }

    func handleNativeCameraEvent(
        _ action: String,
        token: String,
        origin: String,
        isFrame: Bool
    ) {
        switch action {
        case "show":
            guard !token.isEmpty else { return }
            activeNativeCaptureToken = token
            nativeCaptureFailure = ""
            nativeCaptureDidFire = false
            isNativeCaptureActive = true
            Haptics.selection()
        case "hide":
            guard activeNativeCaptureToken == token else { return }
            isNativeCaptureActive = false
        case "served":
            // Only trust a completion tied to the capture currently visible in the
            // app. A stale frame or post-navigation message cannot fake success.
            guard activeNativeCaptureToken == token, isNativeCaptureActive else { return }
            nativeCaptureDidFire = true
            Haptics.success()
            recordNativeCameraOutcome(succeeded: true)
        case "realCamera":
            // The user deliberately asked for the real camera, so this is not a
            // delivery failure and must never be logged as one.
            guard token.isEmpty || activeNativeCaptureToken == token else { return }
            isNativeCaptureActive = false
            nativeCaptureDidFire = false
            activeNativeCaptureToken = nil
            nativeCaptureFailure = "The real camera was requested for this site. If it does not open, tap the site's camera button once more."
            lastAction = "realCamera"
            Haptics.selection()
        case "retry", "fail":
            // Empty tokens are used by an asynchronous Ask Me decision, where no
            // capture overlay was opened. A tokened event must match exactly.
            guard token.isEmpty || activeNativeCaptureToken == token else { return }
            isNativeCaptureActive = false
            nativeCaptureDidFire = false
            activeNativeCaptureToken = nil
            nativeCaptureFailure = "The queued photo was not delivered. Tap the site's camera button again to open the system camera with a fresh user gesture."
            lastAction = "nativePickerRetry"
            if !token.isEmpty { recordNativeCameraOutcome(succeeded: false) }
            Haptics.selection()
        default:
            break
        }
    }

    func dismissNativeCaptureFailure() {
        nativeCaptureFailure = ""
    }

    /// Records every native camera hand-off in the camera-response log and site
    /// history, so a site that refuses one is visible instead of failing silently.
    private func recordNativeCameraOutcome(succeeded: Bool) {
        let site = currentURL?.absoluteString ?? ""
        guard !site.isEmpty else { return }
        let result = succeeded
            ? "Queued photo delivered as a native capture"
            : "Hand-off did not complete — a fresh user gesture is required to retry"
        constraintLog.addEntry(ConstraintLogEntry(
            siteURL: site,
            requestedConstraints: "Native camera capture (file input)",
            negotiatedResult: result,
            fallbackReason: succeeded ? nil : "The native FileList hand-off could not be proven; no automatic system-camera fallback was claimed",
            wasSuccessful: succeeded
        ))
        siteHistory.addEntries([SiteHistoryEntry(
            siteURL: site,
            requestedConstraints: "Native camera capture",
            actualSettings: result,
            profileUsed: activeInjectionProfile.label,
            wasSuccessful: succeeded
        )])
    }

    func updateSequenceProgress(
        pointer ptr: Int,
        pickerPointer: Int? = nil,
        surface: String = "live",
        servedID: String?,
        action: String,
        feed: String = "",
        lane: String = "",
        downgraded: Bool = false,
        reason: String = "",
        engine: String = ""
    ) {
        if surface == "native" {
            nativePickerPointer = pickerPointer ?? nativePickerPointer
        } else {
            pointer = ptr
        }
        // Record which feed engine actually engaged for the live stream. Only
        // update when the page reports an engaged feed (a live getUserMedia /
        // srcObject serve); block / real / picker actions carry no feed and leave
        // the last known readout intact.
        if !feed.isEmpty {
            liveFeedRaw = feed
            liveFeedLaneRaw = lane
            liveFeedDowngraded = downgraded
            liveFeedReasonRaw = reason
            liveFeedEngineRaw = engine
        }
        // A diagnostic self-test restores the sequence position when it finishes
        // so a test run never advances the user's live progress. Sync pointers and
        // the live highlight without disturbing the visible last action.
        if action == "progressSync" {
            if let servedID, let uuid = UUID(uuidString: servedID) {
                lastServedStepID = uuid
            } else {
                lastServedStepID = nil
            }
            return
        }
        if (action == "serve" || action == "manualAdvance"), let servedID, !servedID.isEmpty, let uuid = UUID(uuidString: servedID) {
            lastServedStepID = uuid
            // A successful serve clears any stale refusal note.
            if surface != "native" { liveRequestNotice = "" }
        } else if action == "real" || action == "refuse" || action == "realCamera" || action == "blockWebRTC" || action == "blockNative" || action == "nativePicker" || action == "nativePickerFail" || action == "nativePickerRetry" || action == "deny" || action == "hardBlock" {
            lastServedStepID = nil
        }
        noteLiveRequestOutcome(action: action, surface: surface)
        lastAction = action
    }

    /// Turns a live-surface refusal into a visible, plain-language explanation.
    private func noteLiveRequestOutcome(action: String, surface: String) {
        guard surface != "native" else { return }
        switch action {
        case "blockWebRTC", "refuse":
            liveRequestNotice = hasServableStep
                ? "This site's camera request was blocked by a block step in your media list."
                : "This site asked for the camera and your media list had nothing to serve, so it was blocked."
        case "hardBlock":
            liveRequestNotice = "This site's camera request could not be answered from your media list, so it was refused rather than exposing the real camera. Add a photo or video, or turn Serve Media off to allow the real camera."
        case "deny":
            liveRequestNotice = "This site asked for the other camera side, which is not due yet in your media list."
        case "realCamera":
            liveRequestNotice = "The real camera was handed to this site because a saved answer for it says to. Clear it with Reset Injection Defaults in the media panel."
        default:
            break
        }
    }

    func dismissLiveRequestNotice() {
        liveRequestNotice = ""
    }

    /// Clears every remembered behaviour that can divert or refuse a request:
    /// saved per-site answers, ask-me settings, and learned per-site methods.
    /// The one-tap way out when a site is stuck.
    func resetInjectionDefaults() {
        cameraPrompt.resetToWorkingDefaults()
        siteMemory.clearAll()
        activeInjectionProfile = .auto
        activeNetworkBackend = NetworkBackendOptions()
        UserDefaults.standard.set(InjectionMethodKind.auto.rawValue, forKey: injectionProfileKey)
        saveNetworkBackend()
        liveRequestNotice = ""
        nativeCaptureFailure = ""
        latestDetectedSystem = nil
        activeMediaRequestID = ""
        activeMediaRequestOrigin = ""
        mediaDeliveryStatus = isMediaActive ? .preparing : .idle
        mediaDeliveryDetail = "Defaults reset. The current page will receive a fresh media state."
        updateUserScripts()
        syncMediaToPage()
        Haptics.success()
    }

    // MARK: - Saved sequences & templates

    func saveCurrentSequence(name: String, asTemplate: Bool) {
        _ = sequenceLibrary.save(
            name: name,
            steps: sequence,
            advanceMode: advanceMode,
            endBehavior: endBehavior,
            asTemplate: asTemplate
        )
    }

    func loadSaved(_ record: SavedMediaSequence) {
        clearSequence()
        advanceMode = record.advanceMode
        endBehavior = record.endBehavior

        // Assemble every step in one pass: suppress the per-step page push so a
        // 10-step sequence rebuilds the user scripts once at the end instead of
        // once per step (the old O(N²) behavior). Async media conversions still
        // push individually when they finish, which is spaced out and fine.
        suppressSequencePush = true
        for saved in record.steps.prefix(maxSequenceSteps) {
            let step = SequenceStep(
                id: saved.id,
                kind: saved.kind,
                blockMode: saved.blockMode,
                liveCamera: saved.liveCamera ?? .serveLive,
                requestSurface: saved.requestSurface ?? .either,
                displayName: saved.displayName
            )
            sequence.append(step)

            guard !record.isTemplate else { continue }
            if let fileName = saved.mediaFileName, let url = sequenceLibrary.existingFileURL(for: fileName) {
                switch saved.kind {
                case .photo:
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                        setStepImage(image, for: saved.id)
                    }
                case .video:
                    assignLibraryVideo(url, for: saved.id)
                case .webRTCBlock, .block:
                    break
                }
            }
        }
        suppressSequencePush = false
        bumpVersion()
        pushSequence()
    }

    func deleteSaved(_ record: SavedMediaSequence) {
        sequenceLibrary.delete(record)
    }

    // MARK: - Page injection

    /// While true, `pushSequence()` is a no-op so batch operations (e.g.
    /// loading a saved sequence) can assemble every step and push exactly once.
    private var suppressSequencePush = false

    private func pushSequence() {
        guard !suppressSequencePush else { return }
        updateUserScripts()
        syncMediaToPage()
        // Any successful push means the safety timer is no longer needed.
        cancelMediaActivationSafetyTimer()
    }

    /// Sends an inactive runtime snapshot instead of removing scripts. The
    /// document can then cleanly stop media work without losing its stable bridge.
    private func teardownInjectionOnPage() {
        syncMediaToPage()
    }

    /// Returns true when every photo step with an image has at least one cached
    /// inline payload field, so the page can draw without falling back to a
    /// CSP-vulnerable custom-scheme fetch. Vacuously true when there are no photo
    /// steps (e.g. video-only sequences), so those push immediately as before.
    func allPhotoPayloadsReady() -> Bool {
        for step in sequence where step.kind == .photo && step.image != nil && !step.isConverting {
            guard let entry = payloadCache.entry(for: step.id),
                  entry.pixelBase64 != nil || entry.jpegBase64 != nil || entry.strippedJpegBase64 != nil
            else { return false }
        }
        return true
    }

    /// Safety net: if no `populateStepCache` completion fires within 2 seconds of
    /// activation (every async extraction failed or was superseded), force a
    /// state push so the page is never left without an active-state snapshot.
    private func armMediaActivationSafetyTimer() {
        cancelMediaActivationSafetyTimer()
        let sessionID = navigationSessionID
        mediaActivationSafetyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.navigationSessionID == sessionID, self.isMediaActive else { return }
                self.mediaActivationSafetyTask = nil
                self.syncMediaToPage()
            }
        }
    }

    private func cancelMediaActivationSafetyTimer() {
        mediaActivationSafetyTask?.cancel()
        mediaActivationSafetyTask = nil
    }

    /// The WebKit configuration is immutable for the life of a web view. Runtime
    /// sequence/profile changes travel through the versioned reply bridge instead
    /// of deleting document-start scripts during an active page session.
    func updateUserScripts() {
        syncContentFilter()
    }

    /// Applies one monotonic runtime snapshot to the main document and every
    /// known embedded requester. A delayed WebKit evaluation cannot overwrite a
    /// newer snapshot because the page rejects lower runtime versions.
    func syncMediaToPage() {
        guard let webView else { return }

        if let profile = activeProfile {
            runtimeCoordinator.evaluate(
                StyleSheetProvider.profileApplyScript(
                    from: profile,
                    method: effectiveInjectionMethod,
                    sensorRealism: SensorRealismStore.shared.isEnabled,
                    sdkWrap: SdkInterceptionStore.shared.isEnabled
                )
            )
        }

        if let profile = activeProfile {
            let profileScript = StyleSheetProvider.profileApplyScript(
                from: profile,
                method: effectiveInjectionMethod,
                sensorRealism: SensorRealismStore.shared.isEnabled,
                sdkWrap: SdkInterceptionStore.shared.isEnabled
            )
            runtimeCoordinator.evaluate(profileScript)
            for tracked in knownTrackedFrames where tracked.navigationSessionID == navigationSessionID {
                Task { @MainActor in
                    _ = try? await webView.evaluateJavaScript(profileScript, in: tracked.frameInfo, in: .page)
                }
            }
        }

        runtimeStateVersion &+= 1
        let capturedVersion = runtimeStateVersion
        let mainState = makeRuntimeState(runtimeVersion: runtimeStateVersion, targetOrigin: currentURL?.host)
        
        do {
            let mainScript = StyleSheetProvider.runtimeStateApplyScript(serializedState: try mainState.serializedJSON())
            applyRuntimeState(mainScript, to: webView, frame: nil, sessionID: navigationSessionID, capturedVersion: capturedVersion)
            
            var validFrames: [TrackedFrame] = []
            for tracked in knownTrackedFrames where tracked.navigationSessionID == navigationSessionID {
                let subframeState = makeRuntimeState(runtimeVersion: runtimeStateVersion, targetOrigin: tracked.origin)
                if let subScript = try? StyleSheetProvider.runtimeStateApplyScript(serializedState: subframeState.serializedJSON()) {
                    applyRuntimeState(subScript, to: webView, frame: tracked.frameInfo, sessionID: navigationSessionID, capturedVersion: capturedVersion)
                    validFrames.append(tracked)
                }
            }
            knownTrackedFrames = validFrames
        } catch {
            ConnectionLogService.shared.error("Failed to serialize media runtime state for sync.")
        }
    }

    /// Returns the current runtime snapshot to a fresh document through
    /// `WKScriptMessageHandlerWithReply`.
    func runtimeStateJSON() throws -> String {
        return try makeRuntimeState(runtimeVersion: runtimeStateVersion, targetOrigin: currentURL?.host).serializedJSON()
    }

    private func applyRuntimeState(
        _ script: String,
        to webView: WKWebView,
        frame: WKFrameInfo?,
        sessionID: String,
        capturedVersion: Int
    ) {
        let markFailure: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.navigationSessionID == sessionID, self.isMediaActive else { return }
            guard capturedVersion == self.runtimeStateVersion else { return }
            self.mediaDeliveryStatus = .needsAttention
            self.mediaDeliveryDetail = "The page could not apply the latest media state. Reload it, then retry the request."
        }
        if let frame, !frame.isMainFrame {
            webView.evaluateJavaScript(script, in: frame, in: .page) { result in
                if case .failure = result { markFailure() }
            }
        } else {
            runtimeCoordinator.evaluate(script) { _, error in
                if error != nil { markFailure() }
            }
        }
    }

    private func makeRuntimeState(runtimeVersion: Int, targetOrigin: String? = nil) -> MediaRuntimeState {
        var runtimeSteps: [MediaRuntimeStep] = []
        var runtimePayloads: [String: MediaRuntimePayload] = [:]
        for step in sequence.prefix(maxSequenceSteps) {
            let id = step.id.uuidString
            var imageURL: String?
            var videoURL: String?
            var isEmpty = false
            var pixelBase64: String? = nil
            var pixelWidth: Int? = nil
            var pixelHeight: Int? = nil
            var jpegBase64: String? = nil
            var strippedJpegBase64: String? = nil
            var firstFrameBase64: String? = nil
            var firstFrameMime: String? = nil
            var chunksURL: String? = nil
            var hasPayload = false

            switch step.kind {
            case .webRTCBlock, .block:
                break
            case .photo:
                if step.isConverting || step.image == nil {
                    isEmpty = true
                } else {
                    imageURL = "fslimage://step/\(id)"
                    if let entry = payloadCache.entry(for: step.id) {
                        pixelBase64 = entry.pixelBase64
                        pixelWidth = entry.pixelWidth
                        pixelHeight = entry.pixelHeight
                        jpegBase64 = entry.jpegBase64
                        strippedJpegBase64 = entry.strippedJpegBase64
                        hasPayload = pixelBase64 != nil || jpegBase64 != nil || strippedJpegBase64 != nil
                    }
                }
            case .video:
                if step.isConverting || step.videoURL == nil {
                    isEmpty = true
                } else {
                    videoURL = "fslvideo://step/\(id)"
                    if let entry = payloadCache.entry(for: step.id) {
                        firstFrameBase64 = entry.firstFrameBase64
                        firstFrameMime = entry.firstFrameMime
                    }
                    chunksURL = chunkReadyStepIDs.contains(step.id) ? "fslvideo://chunks/\(id)" : nil
                    hasPayload = firstFrameBase64 != nil || chunksURL != nil
                }
            }

            if hasPayload {
                runtimePayloads[id] = MediaRuntimePayload(
                    resourceID: id,
                    hash: "v1-\(step.kind.jsValue)-\(id)",
                    version: 1,
                    chunksURL: chunksURL,
                    pixelBase64: pixelBase64,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    jpegBase64: jpegBase64,
                    strippedJpegBase64: strippedJpegBase64,
                    firstFrameBase64: firstFrameBase64,
                    firstFrameMime: firstFrameMime
                )
            }
            runtimeSteps.append(MediaRuntimeStep(
                id: id,
                kind: step.kind.jsValue,
                block: step.blockMode.jsValue,
                live: step.liveCamera.jsValue,
                surface: step.requestSurface.jsValue,
                imageURL: imageURL,
                videoURL: videoURL,
                isEmpty: isEmpty
            ))
        }

        let settings = cameraPrompt.settings
        let permissionReset: String
        switch settings.isEnabled ? settings.permissionReset : .never {
        case .never: permissionReset = "never"
        case .whenFeedEnds: permissionReset = "feed"
        case .afterEveryRequest: permissionReset = "request"
        }
        var askKinds: [String] = []
        if settings.isEnabled {
            if settings.askForLiveCamera { askKinds.append("liveCamera") }
            if settings.askForNativeCamera { askKinds.append("nativeCamera") }
            if settings.askForFilePick { askKinds.append("filePick") }
        }
        let originHost = targetOrigin ?? currentURL?.host ?? ""
        let rememberedAction = cameraPrompt.rule(for: originHost)?.jsValue ?? ""
        let active = isMediaActive && hasServableStep

        return MediaRuntimeState(
            runtimeVersion: runtimeVersion,
            navigationSessionID: navigationSessionID,
            sequenceVersion: sequenceVersion,
            payloadVersion: payloadCache.version,
            sequence: runtimeSteps,
            payloads: runtimePayloads,
            mode: advanceMode.jsValue,
            end: endBehavior.jsValue,
            method: effectiveInjectionMethod.jsValue,
            isActive: active,
            isAuto: isAutoResolving,
            photoMotion: servesPhotosAsMotion,
            eyedeekitMode: eyedeekitMode,
            documentHoldMinimumMs: docHoldRange?.lowerBound,
            documentHoldMaximumMs: docHoldRange?.upperBound,
            askEnabled: settings.isEnabled,
            askKinds: askKinds.joined(separator: ","),
            askTimeoutMs: max(3, settings.timeoutSeconds) * 1_000,
            askDefault: settings.defaultAction.jsValue,
            askRule: rememberedAction,
            permissionReset: permissionReset,
            traceEnabled: InjectionTraceRecorder.shared.isEnabled
        )
    }

    /// Eyedeekit-only page state, appended to every sequence push. Emits the mode
    /// flag and the doc hand-off window; both default to "off" values so a normal
    /// session pushes behavior identical to before this feature existed.
    private func eyedeekitStateJS() -> String {
        var out = "s._edk=\(eyedeekitMode ? "true" : "false");"
        if let range = docHoldRange {
            out += "s._docHoldMin=\(range.lowerBound);s._docHoldMax=\(range.upperBound);"
        } else {
            out += "s._docHoldMin=null;s._docHoldMax=null;"
        }
        out += cameraPromptStateJS()
        return out
    }

    /// Ask-me-every-request page state. All values are "off" unless the user has
    /// explicitly enabled the mode, so a normal session behaves exactly as before.
    private func cameraPromptStateJS() -> String {
        let settings = cameraPrompt.settings
        // The permission-release policy applies whenever the mode is on, and is
        // 'never' (a no-op) otherwise.
        let policy: String
        switch settings.isEnabled ? settings.permissionReset : .never {
        case .never: policy = "never"
        case .whenFeedEnds: policy = "feed"
        case .afterEveryRequest: policy = "request"
        }
        let permJS = "s._permReset='\(policy)';" + (policy == "never" ? "s._permReleased=false;" : "")
        let host = currentURL?.host() ?? ""
        // A remembered per-site answer is applied as a real ACTION by the engine —
        // a saved block blocks and a saved allow-real opens the real camera —
        // rather than silently switching asking off and serving anyway.
        let ruleJS: String
        if let remembered = cameraPrompt.rule(for: host) {
            ruleJS = "s._askRule='\(remembered.jsValue)';"
        } else {
            ruleJS = "s._askRule='';"
        }
        guard settings.isEnabled else {
            return permJS + ruleJS + "s._askOn=false;s._askKinds='';"
        }
        var kinds: [String] = []
        if settings.askForLiveCamera { kinds.append("liveCamera") }
        if settings.askForNativeCamera { kinds.append("nativeCamera") }
        if settings.askForFilePick { kinds.append("filePick") }
        let timeoutMs = max(3, settings.timeoutSeconds) * 1000
        return permJS + ruleJS + "s._askOn=true;s._askKinds='\(kinds.joined(separator: ","))';"
            + "s._askTimeout=\(timeoutMs);s._askDefault='\(settings.defaultAction.jsValue)';"
    }

    func burnEverything() async {
        isBurning = true

        clearSequence()

        bookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: bookmarksKey)

        let dataStore = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: allTypes)
        await dataStore.removeData(ofTypes: allTypes, for: records)

        let cookieStore = dataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies {
            await cookieStore.deleteCookie(cookie)
        }

        URLCache.shared.removeAllCachedResponses()

        if let cookiesURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Cookies") {
            try? FileManager.default.removeItem(at: cookiesURL)
        }

        webView?.configuration.userContentController.removeAllUserScripts()

        goHome()

        isBurning = false
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        }
        seedDefaultBookmarkIfNeeded()
    }

    /// Puts the KYC test site at the top of the list once, keeping every
    /// bookmark already saved. Seeded a single time so deleting it sticks.
    private func seedDefaultBookmarkIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: defaultBookmarkSeededKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultBookmarkSeededKey)
        guard !bookmarks.contains(where: { $0.urlString == Self.defaultBookmarkURL }) else { return }
        bookmarks.insert(
            Bookmark(title: "KYC Test", urlString: Self.defaultBookmarkURL),
            at: 0
        )
        saveBookmarks()
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: bookmarksKey)
    }

    // MARK: - Constraint Log Integration

    private func parseJSTimestamp(from entry: [String: Any]) -> Date {
        if let ts = entry["timestamp"] as? Double {
            return Date(timeIntervalSince1970: ts / 1000.0)
        }
        return Date()
    }

    func fetchConstraintLogs(completion: (() -> Void)? = nil) {
        guard let webView else { completion?(); return }
        runtimeCoordinator.evaluate(StyleSheetProvider.constraintLogReadScript) { [weak self] result, _ in
            guard let self, let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !entries.isEmpty else {
                Task { @MainActor in completion?() }
                return
            }

            let profileName = self.activeProfile?.name ?? "Unknown"
            let logEntries = entries.map { entry -> ConstraintLogEntry in
                ConstraintLogEntry(
                    timestamp: self.parseJSTimestamp(from: entry),
                    siteURL: entry["url"] as? String ?? "",
                    requestedConstraints: entry["constraints"] as? String ?? "",
                    negotiatedResult: entry["result"] as? String ?? "",
                    fallbackReason: entry["fallbackReason"] as? String,
                    wasSuccessful: entry["wasSuccessful"] as? Bool ?? false
                )
            }
            let siteEntries = entries.map { entry -> SiteHistoryEntry in
                SiteHistoryEntry(
                    siteURL: entry["url"] as? String ?? "",
                    timestamp: self.parseJSTimestamp(from: entry),
                    requestedConstraints: entry["constraints"] as? String ?? "",
                    actualSettings: entry["result"] as? String ?? "",
                    profileUsed: profileName,
                    wasSuccessful: entry["wasSuccessful"] as? Bool ?? false
                )
            }

            Task { @MainActor in
                self.constraintLog.addEntries(logEntries)
                self.siteHistory.addEntries(siteEntries)
                self.refreshLearnedResponseMap(from: logEntries)
                self.refreshCameraRequestInsights(from: logEntries)
                completion?()
            }

            self.runtimeCoordinator.evaluate(StyleSheetProvider.constraintLogClearScript)
        }
    }

    private func refreshLearnedResponseMap(from entries: [ConstraintLogEntry]) {
        guard !entries.isEmpty, var profile = activeProfile else { return }
        let learned = CameraResponseCalibrationService.learnedMap(from: entries, existing: profile.cameraResponseMap)
        profile.cameraResponseMap = learned
        activeProfile = profile
        onActiveProfileUpdated?(profile)
    }

    private func refreshCameraRequestInsights(from entries: [ConstraintLogEntry]) {
        let newInsights = CameraResponseCalibrationService.insights(
            from: entries,
            profile: activeProfile,
            activeProfile: activeInjectionProfile
        )
        guard !newInsights.isEmpty else { return }
        cameraRequestInsights.insert(contentsOf: newInsights, at: 0)
        if cameraRequestInsights.count > 80 {
            cameraRequestInsights = Array(cameraRequestInsights.prefix(80))
        }
        latestCameraRequestInsight = cameraRequestInsights.first
    }

    /// Opens the unified Analyze Site sheet and runs both halves of the analysis
    /// — the injection/security inspection (which also classifies the detection
    /// system) and the front/back request probe — replacing the three separate
    /// Scan / Inspect / Probe actions.
    func analyzeSite() {
        guard webView != nil else { return }
        Haptics.selection()
        showAnalyzeSite = true
        refreshSiteAnalysis()
    }

    /// Re-runs both analysis passes if they are not already in flight.
    func refreshSiteAnalysis() {
        if !isInspectingCurrentSite { inspectCurrentSite() }
        if !isProbingCurrentSite { probeCurrentSiteRequests() }
    }

    func inspectCurrentSite() {
        guard let webView, !isInspectingCurrentSite else { return }
        isInspectingCurrentSite = true
        inspectionStatus = "Testing this site…"
        Task { [weak self] in
            guard let self else { return }
            let report = await self.injectionInspector.inspectCurrentPage(
                in: webView,
                mediaWasActive: self.isMediaActive,
                sequenceLength: self.sequence.count
            )
            await MainActor.run {
                self.inspectionStatus = report?.verdictTitle ?? "Inspection finished"
                self.isInspectingCurrentSite = false
                if let report {
                    self.runDetectionScan(on: report)
                }
                self.pushSequence()
            }
        }
    }

    /// Classifies a finished inspection report into a detected system and blends
    /// the recommendation with learning memory. Also auto-guesses the outcome of
    /// the currently-applied profile from the page's signals.
    func runDetectionScan(on report: InjectionInspectionReport) {
        var detected = detectionScanner.scan(report: report)
        let blended = siteMemory.recommendation(
            forHost: report.host,
            category: detected.category,
            deviceDefault: activeProfile?.recommendedMethod,
            scannerDefault: detected.baseRecommendation
        )
        detected.recommendedProfile = blended.profile
        detected.memoryInformed = blended.memoryInformed
        latestDetectedSystem = detected
        autoGuessOutcome(from: report)
    }

    private func autoGuessOutcome(from report: InjectionInspectionReport) {
        let host = report.host.isEmpty ? (currentURL?.host() ?? "") : report.host
        guard !host.isEmpty, siteMemory.record(for: host) != nil else { return }
        if report.hasBlockingEvidence {
            siteMemory.autoGuess(.failed, for: host)
        } else if report.warningCount == 0 {
            siteMemory.autoGuess(.worked, for: host)
        }
    }

    private func targetDimensions() -> (width: Int, height: Int) {
        if let cam = canonicalCamera(), let profile = activeProfile {
            let spec = profile.conversionSpec(for: cam)
            return (spec.targetWidth, spec.targetHeight)
        }
        return (640, 480)
    }

    private func pixelBudgetedDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let rawBytes = width * height * 4
        guard rawBytes > maxInlineRawPixelBytes else { return (width, height) }
        let scale = sqrt(Double(maxInlineRawPixelBytes) / Double(max(rawBytes, 1)))
        return (max(Int(Double(width) * scale), 1), max(Int(Double(height) * scale), 1))
    }

    private func nextPayloadGeneration(for stepID: UUID) -> Int {
        let next = (payloadGenerationByStepID[stepID] ?? 0) + 1
        payloadGenerationByStepID[stepID] = next
        return next
    }

    private func nextChunkGeneration(for stepID: UUID) -> Int {
        let next = (chunkGenerationByStepID[stepID] ?? 0) + 1
        chunkGenerationByStepID[stepID] = next
        return next
    }

    /// Demuxes a step's video into WebCodecs-ready encoded chunks off the main
    /// thread and registers them for the new frame engine. Best-effort: a clip
    /// that can't be demuxed simply leaves that step on the element-backed feed,
    /// so this never blocks or breaks the camera.
    private func cacheVideoChunks(for stepID: UUID, videoURL: URL) {
        let idString = stepID.uuidString
        let handler = schemeHandler
        let generation = nextChunkGeneration(for: stepID)
        handler.setStepChunkData(nil, id: idString)
        chunkReadyStepIDs.remove(stepID)
        Task.detached { [weak self] in
            guard let data = await VideoChunkExportService.exportChunksJSON(from: videoURL) else { return }
            await MainActor.run {
                guard let self,
                      self.chunkGenerationByStepID[stepID] == generation,
                      self.sequence.contains(where: { $0.id == stepID && $0.videoURL == videoURL }) else { return }
                handler.setStepChunkData(data, id: idString)
                self.chunkReadyStepIDs.insert(stepID)
                // Refresh payloads so the page can pick up the chunks URL. Do NOT
                // bump the sequence version — that resets the advance pointers.
                self.pushSequence()
            }
        }
    }
    private func cacheFirstFramePayload(for stepID: UUID, videoURL: URL) {
        let dims = targetDimensions()
        let converter = mediaConverter
        let maxBytes = maxInlineJPEGBytes
        let generation = nextPayloadGeneration(for: stepID)
        Task.detached { [weak self] in
            guard let data = Self.firstFrameJPEG(
                videoURL: videoURL,
                width: dims.width,
                height: dims.height,
                converter: converter
            ), data.count <= maxBytes else { return }
            let base64 = data.base64EncodedString()
            await MainActor.run {
                guard let self,
                      self.payloadGenerationByStepID[stepID] == generation,
                      self.sequence.contains(where: { $0.id == stepID && $0.videoURL == videoURL }) else { return }
                self.payloadCache.setFirstFramePayload(stepID: stepID, base64: base64, mime: "image/jpeg")
                // Refresh payloads only — do NOT bump the sequence version. A
                // version bump resets the in-page advance pointers, which would
                // restart the sequence just because a derived cache finished.
                self.pushSequence()
            }
        }
    }

    private nonisolated static func firstFrameJPEG(
        videoURL: URL,
        width: Int,
        height: Int,
        converter: MediaConverterService
    ) -> Data? {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            let rendered = converter.renderImage(uiImage, width: width, height: height, mode: .fillCrop)
            return rendered.jpegData(compressionQuality: 0.86)
        } catch {
            return nil
        }
    }

    /// Rebuilds every photo payload with the current upright pixel extractor so a
    /// live session never keeps serving a previously cached upside-down buffer.
    /// Existing entries are preserved until the async re-extraction overwrites
    /// them, so the page always has inline payload data available while the
    /// rebuild is in flight (the generation guard in `populateStepCache`
    /// ensures only the latest extraction wins).
    func rebuildAllPhotoPayloads() {
        // Synchronous fast-path: produce a stripped JPEG immediately so the
        // native camera hand-off always has inline bytes (sb64) available
        // before the async full-resolution extraction completes. This matters
        // most on strict-CSP sites where the fslimage:// fallback is blocked.
        let handler = imageSchemeHandler
        let maxBytes = maxInlineJPEGBytes
        for step in sequence where step.kind == .photo && step.image != nil && !step.isConverting {
            let idJS = step.id.uuidString
            if payloadCache.entry(for: step.id)?.strippedJpegBase64 == nil,
               let stripped = handler.strippedJPEGDataForStep(idJS, maxBytes: maxBytes) {
                payloadCache.setStrippedPayloadOnly(
                    stepID: step.id,
                    strippedJpegBase64: stripped.base64EncodedString()
                )
            }
        }
        // Async full-resolution extraction (pixel data, full JPEG, stripped JPEG).
        for step in sequence where step.kind == .photo && step.image != nil && !step.isConverting {
            populateStepCache(for: step.id)
        }
    }

    /// Pre-computes and caches base64-encoded pixel data (putImageData path)
    /// and JPEG data (createImageBitmap fallback) outside observable sequence
    /// state, off the main thread so a sequence push never blocks on heavy
    /// resize / encode / base64 work for a multi-megapixel still.
    private func populateStepCache(for stepID: UUID) {
        guard let step = sequence.first(where: { $0.id == stepID }) else { return }
        let idJS = stepID.uuidString
        let dims = targetDimensions()
        let pixelDims = pixelBudgetedDimensions(width: dims.width, height: dims.height)
        let handler = imageSchemeHandler
        let maxPixelBytes = maxInlineRawPixelBytes
        let maxJPEGBytes = maxInlineJPEGBytes
        let generation = nextPayloadGeneration(for: stepID)
        Task.detached { [weak self] in
            var pixelBase64: String?
            var pixelWidth: Int?
            var pixelHeight: Int?
            var jpegBase64: String?
            var jpegMime: String?
            var strippedJpegBase64: String?

            if let pixel = handler.rgbaPixelDataForStep(idJS, targetWidth: pixelDims.width, targetHeight: pixelDims.height),
               pixel.data.count <= maxPixelBytes {
                pixelBase64 = pixel.data.base64EncodedString()
                pixelWidth = pixel.width
                pixelHeight = pixel.height
            }

            if let jpegData = handler.jpegDataForStep(idJS), jpegData.count <= maxJPEGBytes {
                jpegBase64 = jpegData.base64EncodedString()
                jpegMime = "image/jpeg"
            }

            // Stripped, re-encoded variant for native camera captures (Safari
            // drops EXIF on a capture hand-off). Kept separate so library picks
            // still serve the full-EXIF bytes.
            //
            // This variant is ALWAYS produced small enough to be carried inside the
            // page: a camera capture must never fall back to the app-address route a
            // locked-down site refuses, nor to the full-metadata original.
            if let stripped = handler.strippedJPEGDataForStep(idJS, maxBytes: maxJPEGBytes) {
                strippedJpegBase64 = stripped.base64EncodedString()
            }

            await MainActor.run {
                guard let self,
                      self.payloadGenerationByStepID[stepID] == generation,
                      self.sequence.contains(where: { $0.id == stepID }) else { return }
                self.payloadCache.setPhotoPayload(
                    stepID: stepID,
                    pixelBase64: pixelBase64,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    jpegBase64: jpegBase64,
                    jpegMime: jpegMime,
                    strippedJpegBase64: strippedJpegBase64
                )
                // Refresh payloads only; never bump the sequence version here.
                self.pushSequence()
            }
        }
    }

    func probeCurrentSiteRequests() {
        guard let webView, !isProbingCurrentSite else { return }
        isProbingCurrentSite = true
        probeStatus = "Probing camera responses…"
        // Body for callAsyncJavaScript — the probe issues real getUserMedia calls
        // and must be awaited so the constraint log is populated before we read it.
        let body = """
        const s=window[Symbol.for('fsl')];
        const restoreActive=s?s.a:false;
        if(s)s.a=false;
        const requests=[
          {video:{facingMode:{ideal:'user'},width:{ideal:640},height:{ideal:480},frameRate:{ideal:30}},audio:false},
          {video:{facingMode:{ideal:'user'},width:{ideal:1280},height:{ideal:720},frameRate:{ideal:30}},audio:false},
          {video:{facingMode:{ideal:'environment'},width:{ideal:1280},height:{ideal:720},frameRate:{ideal:30}},audio:false},
          {video:{facingMode:{ideal:'environment'},width:{ideal:1920},height:{ideal:1080},frameRate:{ideal:30}},audio:false}
        ];
        let completed=0;
        try{
          for(const constraints of requests){
            try{
              const stream=await navigator.mediaDevices.getUserMedia(constraints);
              try{stream.getTracks().forEach(t=>t.stop());}catch(e){}
            }catch(e){}
            completed++;
            await new Promise(r=>setTimeout(r,180));
          }
        }finally{
          if(s)s.a=restoreActive;
        }
        return completed;
        """
        Task { [weak self] in
            guard let self, let webView = self.webView else { return }
            let result = try? await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
            let completed = (result as? Int) ?? (result as? NSNumber)?.intValue ?? 0
            self.probeStatus = "Reading captured requests…"
            self.fetchConstraintLogs { [weak self] in
                guard let self else { return }
                if let insight = self.latestCameraRequestInsight {
                    self.probeStatus = "Latest: \(insight.target.label) \(insight.requestedLabel)"
                } else if completed > 0 {
                    self.probeStatus = "Probed \(completed) request shape\(completed == 1 ? "" : "s") — none captured by the page"
                } else {
                    self.probeStatus = "Probe finished — the site made no camera request"
                }
                self.isProbingCurrentSite = false
            }
        }
    }
}
