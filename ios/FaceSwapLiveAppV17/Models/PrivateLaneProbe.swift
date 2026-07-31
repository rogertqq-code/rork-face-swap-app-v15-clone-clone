import Foundation

/// Outcome of running the clean-feed engine probe inside a single JS world —
/// either the page's own world (the site's lane) or the app-only isolated
/// content world (the "private lane"). The same routine is captured identically
/// in both worlds so the two can be compared side by side.
nonisolated struct PrivateLaneWorldResult: Codable, Sendable {
    /// The probe body executed and returned a result in this world.
    var ran: Bool
    /// The private-lane document-start marker visible in this world (non-zero
    /// only inside the private lane; proves the lane bootstrap ran there).
    var laneTag: Double
    /// Worker + WebCodecs (VideoFrame) + MediaStream are all available here.
    var capable: Bool
    /// `new Worker(blob:)` did not throw — the security policy allowed the
    /// background engine to start in this world.
    var workerStarted: Bool
    /// The engine produced a real video MediaStreamTrack (live, not ended).
    var trackProduced: Bool
    /// Synthetic frames were accepted by the engine — it is genuinely alive.
    var frameVerified: Bool
    /// Stable error / reason code when the engine couldn't fully start.
    var error: String
    /// Wall-clock duration of the probe in this world (ms).
    var ms: Int
    /// Page CSP read from a `<meta http-equiv>` tag (captured in the page world).
    var metaCSP: String

    init(
        ran: Bool = false,
        laneTag: Double = 0,
        capable: Bool = false,
        workerStarted: Bool = false,
        trackProduced: Bool = false,
        frameVerified: Bool = false,
        error: String = "",
        ms: Int = 0,
        metaCSP: String = ""
    ) {
        self.ran = ran
        self.laneTag = laneTag
        self.capable = capable
        self.workerStarted = workerStarted
        self.trackProduced = trackProduced
        self.frameVerified = frameVerified
        self.error = error
        self.ms = ms
        self.metaCSP = metaCSP
    }
}

/// Status of a single line in the viability checklist. Distinct from the
/// detector self-test status because "blocked in the site's own lane" is the
/// *expected, desirable* control result on a strict site, not a failure.
nonisolated enum PrivateLaneCheckStatus: String, Codable, Sendable {
    case pass         // green — happened as wanted
    case blocked      // orange — blocked (expected for the site lane on strict sites)
    case fail         // red — the decisive thing didn't happen
    case unsupported  // gray — this browser can't run the engine at all
    case info         // cyan — informational only

    nonisolated var label: String {
        switch self {
        case .pass: "Pass"
        case .blocked: "Blocked"
        case .fail: "Fail"
        case .unsupported: "N/A"
        case .info: "Info"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .blocked: "hand.raised.fill"
        case .fail: "xmark.circle.fill"
        case .unsupported: "minus.circle"
        case .info: "info.circle.fill"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .pass: "green"
        case .blocked: "orange"
        case .fail: "red"
        case .unsupported: "gray"
        case .info: "cyan"
        }
    }
}

/// A single line of the viability checklist.
nonisolated struct PrivateLaneCheck: Codable, Sendable, Identifiable {
    var checkID: String
    var title: String
    var status: PrivateLaneCheckStatus
    var detail: String

    nonisolated var id: String { checkID }
}

/// The full result of the Stage 1 viability check for one site: the site's
/// security policy, the side-by-side page-world vs private-lane engine starts,
/// and the derived plain-language verdict + checklist.
nonisolated struct PrivateLaneProbeReport: Codable, Sendable, Identifiable {
    var id: UUID
    var host: String
    /// Enforced Content-Security-Policy response header, if the site sent one.
    var cspEnforced: String
    /// Report-only Content-Security-Policy header, if present.
    var cspReportOnly: String
    var page: PrivateLaneWorldResult
    var privateLane: PrivateLaneWorldResult
    var timestamp: Date

    init(
        id: UUID = UUID(),
        host: String,
        cspEnforced: String,
        cspReportOnly: String,
        page: PrivateLaneWorldResult,
        privateLane: PrivateLaneWorldResult,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.cspEnforced = cspEnforced
        self.cspReportOnly = cspReportOnly
        self.page = page
        self.privateLane = privateLane
        self.timestamp = timestamp
    }

    // MARK: - Derived facts

    /// Neither world can even run the engine (no iOS 18+ WebCodecs / Worker).
    nonisolated var deviceIncapable: Bool { !privateLane.capable && !page.capable }

    /// The decisive outcome: the engine started AND produced a live track inside
    /// the private lane.
    nonisolated var isViable: Bool { privateLane.workerStarted && privateLane.trackProduced }

    /// The site blocked the engine in its own lane (the wall the private lane is
    /// meant to get around). Only meaningful when the device is capable.
    nonisolated var siteBlockedNormalLane: Bool { page.capable && !page.workerStarted }

    // MARK: - Verdict

    nonisolated var verdictTintName: String {
        if deviceIncapable { return "gray" }
        if isViable { return siteBlockedNormalLane ? "green" : "teal" }
        if privateLane.workerStarted { return "orange" }
        return "red"
    }

    nonisolated var verdictIcon: String {
        if deviceIncapable { return "iphone.slash" }
        if isViable { return "checkmark.seal.fill" }
        if privateLane.workerStarted { return "exclamationmark.triangle.fill" }
        return "xmark.seal.fill"
    }

    nonisolated var verdictTitle: String {
        if deviceIncapable { return "This device can't run the clean feed engine" }
        if isViable {
            return siteBlockedNormalLane
                ? "Private lane is viable on this site"
                : "Viable — but this site didn't block the normal lane"
        }
        if privateLane.workerStarted { return "Private lane opened the engine, but no live track" }
        return "This site blocks even the private lane"
    }

    nonisolated var verdictReason: String {
        if deviceIncapable {
            return "The background clean-feed engine needs iOS 18 or newer. This browser doesn't expose it, so the private lane can't be proven here."
        }
        if isViable {
            if siteBlockedNormalLane {
                return "The engine was blocked in the site's own lane but started and produced a live camera track in the private lane — exactly the bypass the full build relies on. Green light to proceed."
            }
            return "The engine started in both lanes, so this site isn't strict enough to need the private lane. The lane still works — re-run on a known-strict verification site to prove the bypass against a real wall."
        }
        if privateLane.workerStarted {
            return "The engine started in the private lane but didn't deliver a live track in time (\(Self.reasonText(privateLane.error))). Worth a re-run; if it persists, the lane isn't enough on this site."
        }
        return "The site's security policy blocked the background engine in the private lane too (\(Self.reasonText(privateLane.error))). The private-lane approach won't work here."
    }

    // MARK: - Checklist

    nonisolated var checks: [PrivateLaneCheck] {
        var out: [PrivateLaneCheck] = []

        // 1. Private lane opened.
        let laneOpened = privateLane.laneTag > 0 || privateLane.ran
        let laneDetail: String
        if privateLane.laneTag > 0 {
            laneDetail = "The app-only lane was established at page start, separate from the site's own code."
        } else if privateLane.ran {
            laneDetail = "The private lane ran the check, but the start-of-page marker wasn't found."
        } else {
            laneDetail = "The private lane couldn't be reached on this page."
        }
        out.append(PrivateLaneCheck(
            checkID: "lane-open",
            title: "Private lane opened",
            status: laneOpened ? .pass : .fail,
            detail: laneDetail
        ))

        // 2. Engine start in the site's own lane (the control).
        let siteStatus: PrivateLaneCheckStatus
        let siteDetail: String
        if !page.capable {
            siteStatus = .unsupported
            siteDetail = "The clean-feed engine isn't available to test in the site's lane on this browser."
        } else if page.workerStarted {
            siteStatus = .pass
            siteDetail = "The engine started in the site's own lane — this site doesn't block it, so it isn't a strict site."
        } else {
            siteStatus = .blocked
            siteDetail = "Blocked in the site's own lane — expected on a strict site. This is the wall the private lane is meant to get around."
        }
        out.append(PrivateLaneCheck(
            checkID: "site-lane",
            title: "Engine start in the site's own lane",
            status: siteStatus,
            detail: siteDetail
        ))

        // 3. Engine start in the private lane (the decisive light).
        let privStatus: PrivateLaneCheckStatus
        let privDetail: String
        if !privateLane.capable {
            privStatus = .unsupported
            privDetail = "The clean-feed engine isn't available on this browser (needs iOS 18 or newer)."
        } else if privateLane.workerStarted {
            privStatus = .pass
            privDetail = "The background engine started inside the private lane — the decisive result."
        } else {
            privStatus = .fail
            privDetail = "The engine was blocked in the private lane too (\(Self.reasonText(privateLane.error)))."
        }
        out.append(PrivateLaneCheck(
            checkID: "private-lane",
            title: "Engine start in the private lane",
            status: privStatus,
            detail: privDetail
        ))

        // 4. A real camera track was produced inside the lane.
        let trackStatus: PrivateLaneCheckStatus
        let trackDetail: String
        if !privateLane.capable {
            trackStatus = .unsupported
            trackDetail = "No engine to produce a track on this browser."
        } else if privateLane.trackProduced {
            trackStatus = .pass
            trackDetail = privateLane.frameVerified
                ? "A real, live camera track was produced and accepted real frames inside the lane."
                : "A real, live camera track was produced inside the lane (frame delivery wasn't confirmed in time)."
        } else {
            trackStatus = .fail
            trackDetail = "The lane started the engine but no live track was produced (\(Self.reasonText(privateLane.error)))."
        }
        out.append(PrivateLaneCheck(
            checkID: "track",
            title: "Real camera track produced in the lane",
            status: trackStatus,
            detail: trackDetail
        ))

        return out
    }

    // MARK: - CSP display

    /// The security policy to show: prefer the enforced response header, then a
    /// meta-tag policy read from the page, then a report-only header.
    nonisolated var displayCSP: String {
        if !cspEnforced.isEmpty { return cspEnforced }
        if !page.metaCSP.isEmpty { return page.metaCSP }
        if !cspReportOnly.isEmpty { return cspReportOnly }
        return ""
    }

    nonisolated var cspLabel: String {
        if !cspEnforced.isEmpty { return "Content-Security-Policy (enforced)" }
        if !page.metaCSP.isEmpty { return "Content-Security-Policy (meta tag)" }
        if !cspReportOnly.isEmpty { return "Content-Security-Policy-Report-Only" }
        return "No Content-Security-Policy seen"
    }

    // MARK: - Reason mapping

    /// Maps an internal engine error/reason code to plain language.
    nonisolated static func reasonText(_ code: String) -> String {
        if code.isEmpty { return "no error reported" }
        if code.hasPrefix("worker-blocked") { return "the security policy blocked the background worker" }
        if code.contains("no-videotrackgenerator") { return "no clean-feed engine on this browser" }
        if code.hasPrefix("worker-error") { return "the worker failed to load" }
        if code.hasPrefix("vtg:") { return "the engine reported an internal error" }
        if code == "no-track" { return "the engine never returned a track" }
        if code == "no-worker" { return "background workers aren't available" }
        if code == "no-webcodecs" { return "WebCodecs isn't available (needs iOS 18 or newer)" }
        if code.hasPrefix("post-init") { return "the engine couldn't be started" }
        if code.hasPrefix("stream") { return "the produced track couldn't be wrapped into a stream" }
        return code
    }
}
