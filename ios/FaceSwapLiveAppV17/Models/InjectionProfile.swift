import Foundation

/// Optional network-side tools that can be layered on top of any camera
/// delivery method. These are intentionally separate from `InjectionMethodKind`
/// so the feed choice (Canvas Pipeline, Raw Frame Pipe, Private Lane, or
/// Passthrough) is never forced back to Canvas just because a network tool is on.
nonisolated struct NetworkBackendOptions: Codable, Sendable, Equatable {
    var blockDetectionScripts: Bool
    var useRewriteProxy: Bool

    init(blockDetectionScripts: Bool = false, useRewriteProxy: Bool = false) {
        self.blockDetectionScripts = blockDetectionScripts
        self.useRewriteProxy = useRewriteProxy
    }

    nonisolated static let off = NetworkBackendOptions()

    nonisolated var isEnabled: Bool { blockDetectionScripts || useRewriteProxy }
}

/// The injection method that determines **how** media is fed into the page
/// when Enable Media is on and a sequence is active.
///
/// Each method represents a different delivery path — from highest
/// compatibility (Canvas Pipeline) through lowest detection surface (Video
/// Direct) to cleanest signal (Raw Frame Pipe). Passthrough always uses the
/// real camera and is only active when Enable Media is explicitly off.
nonisolated enum InjectionMethodKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Paints media onto a hidden canvas and calls `captureStream()` to
    /// create the virtual camera feed. Best compatibility, works everywhere.
    case canvasPipeline

    /// Legacy persisted value from the old method picker. It is no longer shown
    /// as a camera method; loading it migrates to Raw Frame Pipe.
    case videoDirect

    /// Assembles raw frames on a background worker lane and feeds them through a
    /// `VideoTrackGenerator` track (iOS 18+). Works for photos and videos and
    /// honors resize requests. Falls back to the Canvas feed when unsupported.
    case rawFramePipe

    /// No injection at all. The real device camera is used. Only active
    /// when Enable Media is explicitly turned off.
    case passthrough

    /// Legacy persisted value from the old method picker. It is no longer shown
    /// as a camera method; loading it migrates to Canvas Pipeline plus the
    /// Block Detection Scripts network switch.
    case networkFilter

    /// Legacy persisted value from the old method picker. It is no longer shown
    /// as a camera method; loading it migrates to Canvas Pipeline plus both
    /// network backend switches.
    case networkRewrite

    /// Legacy persisted value from the old method picker. It is no longer shown
    /// as a camera method; loading it migrates to Canvas Pipeline.
    ///
    /// Declared last so `allCases` ordering — and the learning-memory fallback
    /// that relies on it — stays byte-for-byte identical.
    case classicCanvas

    /// Default. Live/WebRTC requests are served through the proven Canvas feed,
    /// while native camera-capture requests are always answered from the queue
    /// with the hardened hand-off (in-page bytes, capture simulation, Safari file
    /// shape). Declared after the legacy cases so `allCases` ordering — and the
    /// learning-memory fallback that relies on it — stays stable.
    case auto

    /// Runs the clean worker-backed feed (VideoTrackGenerator, iOS 18+) as the
    /// app-only "private lane" delivery path — the method proven out by the
    /// earlier one-tap viability check. Works for photos and videos and honors
    /// resize requests; frames are verified before commit, and any failure falls
    /// back to the proven Canvas feed. Opt-in only; never auto-recommended.
    ///
    /// Declared last so `allCases` ordering stays stable for the learning-memory
    /// fallback. UI surfaces it via `displayOrder`.
    case privateLane

    nonisolated var id: String { rawValue }

    /// Display order for pickers and the detection guide. Network tools are not
    /// methods anymore, so the old network cases are intentionally excluded,
    /// along with the folded legacy methods.
    nonisolated static var displayOrder: [InjectionMethodKind] {
        [.auto, .canvasPipeline, .rawFramePipe, .privateLane, .passthrough]
    }

    /// Concrete delivery methods a sweep or recommendation can actually name.
    ///
    /// Auto is a routing choice rather than a delivery path — its live feed IS the
    /// Canvas Pipeline — so method sweeps and "steer away from what failed"
    /// recommendations exclude it. Without this, diagnostics would run a duplicate
    /// Canvas row and recommendations would name Auto instead of the method that
    /// actually differs.
    nonisolated static var deliveryMethods: [InjectionMethodKind] {
        displayOrder.filter { $0 != .auto && $0 != .passthrough }
    }

    /// Legacy network values remain decodable so old defaults and site-memory
    /// records can be migrated safely, but they are never recommended or shown.
    nonisolated var isLegacyNetworkBackendMethod: Bool { self == .networkFilter || self == .networkRewrite }

    /// Experimental methods carry honest caveats and are never auto-recommended
    /// as a blind fallback — only user-selected or learned per site.
    nonisolated var isExperimental: Bool { false }

    /// Camera method to use when a legacy network method or folded method is encountered.
    nonisolated var migratedCameraMethod: InjectionMethodKind {
        switch self {
        case .classicCanvas: return .canvasPipeline
        case .videoDirect: return .rawFramePipe
        case _ where isLegacyNetworkBackendMethod: return .canvasPipeline
        default: return self
        }
    }

    /// Network switches implied by a legacy network method, if any.
    nonisolated var migratedNetworkBackend: NetworkBackendOptions? {
        switch self {
        case .networkFilter:
            NetworkBackendOptions(blockDetectionScripts: true, useRewriteProxy: false)
        case .networkRewrite:
            NetworkBackendOptions(blockDetectionScripts: true, useRewriteProxy: true)
        default:
            nil
        }
    }

    /// JS-side identifier pushed into the page state so the engine can branch.
    nonisolated var jsValue: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .auto: "Auto"
        case .canvasPipeline: "Canvas Pipeline"
        case .classicCanvas: "Classic Canvas"
        case .videoDirect: "Video Direct"
        case .rawFramePipe: "Raw Frame Pipe"
        case .privateLane: "Private Lane"
        case .passthrough: "Passthrough"
        case .networkFilter: "Network Filter"
        case .networkRewrite: "Network Rewrite"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .auto: "wand.and.stars"
        case .canvasPipeline: "paintpalette.fill"
        case .classicCanvas: "paintbrush.fill"
        case .videoDirect: "play.rectangle.fill"
        case .rawFramePipe: "waveform.path"
        case .privateLane: "lock.shield.fill"
        case .passthrough: "camera.fill"
        case .networkFilter: "network.badge.shield.half.filled"
        case .networkRewrite: "arrow.triangle.swap"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .auto: "mint"
        case .canvasPipeline: "blue"
        case .classicCanvas: "orange"
        case .videoDirect: "green"
        case .rawFramePipe: "purple"
        case .privateLane: "pink"
        case .passthrough: "gray"
        case .networkFilter: "indigo"
        case .networkRewrite: "teal"
        }
    }

    /// One-line summary shown under the picker.
    nonisolated var summary: String {
        switch self {
        case .auto:
            "Recommended. Streams live camera requests through the proven Canvas feed, and answers native camera captures from your queue like a real photo."
        case .canvasPipeline:
            "Paints media onto a canvas and streams it. Best compatibility — works everywhere."
        case .classicCanvas:
            "The original, most dependable feed. Paints your photo or video onto a hidden surface and streams it as the camera — hardened stealth and camera-paced timing on the proven core."
        case .videoDirect:
            "Streams your video through a clean iOS 18+ background track — no drawing surface, lowest footprint. Photos and older devices use Canvas."
        case .rawFramePipe:
            "Assembles raw frames on a clean iOS 18+ background track. Works for photos and videos; falls back to Canvas when unavailable."
        case .privateLane:
            "Runs the clean feed through an app-only private lane strict verification sites can't police. Confirms real frames before committing; falls back to Canvas if a site refuses it."
        case .passthrough:
            "No injection — uses the real device camera. Only active when media is off."
        case .networkFilter:
            "Legacy Network Filter setting. It is now restored as Canvas Pipeline plus the Block Detection Scripts switch."
        case .networkRewrite:
            "Legacy Network Rewrite setting. It is now restored as Canvas Pipeline plus both network backend switches."
        }
    }

    /// Longer explanation surfaced in the detection guide / detail rows.
    nonisolated var detail: String {
        switch self {
        case .auto:
            "The default. Live in-page camera requests (getUserMedia / WebRTC) are served through the Canvas Pipeline — the most compatible feed, unchanged. Separately, when a site launches your phone's native camera for a photo, that request is always answered from your queue using the hardened hand-off: the photo is carried inside the page so a strict site's security rules can't refuse it, the page freezes and any live feed is interrupted exactly as a real capture does, and the file arrives named and stripped the way Safari hands over a camera shot. If a hand-off ever can't complete, the real camera opens instead of nothing happening."
        case .canvasPipeline:
            "Paints each frame of your selected media onto a hidden canvas and calls captureStream() to produce the virtual feed. This is the most compatible method — it works on virtually every site — but leaves a canvas fingerprint artifact that some consistency checkers may notice."
        case .classicCanvas:
            "The original, most dependable injection: it paints each frame of your selected media onto a hidden canvas and calls captureStream() to produce the virtual feed — the exact proven mechanism, left unchanged. On top of that core it adds drift-free, camera-paced frame delivery (frames arrive at the claimed frame rate with subtle natural variation instead of following the screen's refresh rate), plus the shared hardened native-code disguise and the airtight camera lock. It is opt-in and never auto-recommended, so the scanner's picks are unaffected."
        case .videoDirect:
            "Feeds frames straight from the decoded video into a clean camera track produced on a background worker lane (VideoTrackGenerator, iOS 18+). There is no canvas or video-capture tell, so it is a genuinely lower-footprint feed than Canvas Pipeline. Still-image steps have nothing to decode, so they use the Canvas feed; and on pre-iOS-18 devices or sites that block the worker lane, it falls back to the Canvas feed automatically — the camera never goes dead."
        case .rawFramePipe:
            "Assembles each frame on a background worker lane and pushes it through a clean camera track (VideoTrackGenerator, iOS 18+), with no canvas-capture tell on the page side. It works for both photos and videos and honors resolution and frame-rate change requests. On pre-iOS-18 devices, or sites that block the worker lane, it falls back to the proven Canvas feed automatically — the camera is never left dead."
        case .privateLane:
            "Targets strict verification sites. It runs the clean background camera feed (VideoTrackGenerator, iOS 18+) through an app-only private lane — separate from the site's own page — so a strict site's security rules can't shut the feed engine down the way they do on the page itself. Real frames are confirmed flowing before it commits, so the site never receives a black or frozen feed, and it works for both photos and videos while honoring resolution and frame-rate requests. On sites that aren't strict it behaves like the other clean-feed methods, and if a site refuses even the private lane — or the device is too old to run the clean engine — it automatically falls back to the proven Canvas feed. It is opt-in only: the scanner never recommends it, and it never pretends the clean feed is live when Canvas is actually running."
        case .passthrough:
            "Turns media serving off entirely and hands the site your real device camera. This is the baseline for sites where compatibility matters more than substitution. Enable Media must be off for this to take effect."
        case .networkFilter:
            "Legacy Network Filter setting. The app now migrates this to Canvas Pipeline plus the independent Block Detection Scripts switch, so the feed method and network backend can be chosen separately."
        case .networkRewrite:
            "Legacy Network Rewrite setting. The app now migrates this to Canvas Pipeline plus both independent network backend switches, so the feed method and network backend can be chosen separately."
        }
    }

    /// Whether this method serves media at all. Passthrough never does;
    /// the other three methods all use the selected media.
    nonisolated var servesMedia: Bool {
        self != .passthrough
    }
}

/// Legacy type alias kept for compatibility with persisted user defaults
/// and site memory records. New code should use `InjectionMethodKind`.
typealias InjectionProfileKind = InjectionMethodKind
