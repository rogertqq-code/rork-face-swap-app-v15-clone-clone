import SwiftUI

/// Resolves the model-layer color names (kept SwiftUI-free) into SwiftUI colors.
extension Color {
    init(themeName: String) {
        switch themeName {
        case "teal": self = .teal
        case "blue": self = .blue
        case "purple": self = .purple
        case "gray": self = .gray
        case "orange": self = .orange
        case "red": self = .red
        case "pink": self = .pink
        case "green": self = .green
        case "yellow": self = .yellow
        case "cyan": self = .cyan
        case "indigo": self = .indigo
        default: self = .accentColor
        }
    }
}

// MARK: - Injection method picker

struct InjectionProfilePicker: View {
    @Bindable var viewModel: BrowserViewModel

    private var activeMethod: InjectionMethodKind { viewModel.activeInjectionProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Method grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(InjectionMethodKind.displayOrder) { method in
                    Button {
                        viewModel.setInjectionProfile(method)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: method.icon)
                                .font(.caption.weight(.bold))
                            Text(method.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if method.isExperimental {
                                Image(systemName: "flask.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .opacity(0.9)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(activeMethod == method ? Color.black : Color(themeName: method.tintName))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(activeMethod == method ? Color(themeName: method.tintName) : Color(themeName: method.tintName).opacity(0.13), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("browser.injection.method.\(method.rawValue)")
                    .accessibilityValue(activeMethod == method ? "selected" : "available")
                }
            }

            // Active method description
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(themeName: activeMethod.tintName).opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: activeMethod.icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(themeName: activeMethod.tintName))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeMethod.label)
                            .font(.subheadline.weight(.semibold))
                        if activeMethod.isExperimental {
                            Text("EXPERIMENTAL")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(themeName: activeMethod.tintName))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(themeName: activeMethod.tintName).opacity(0.15), in: .capsule)
                        }
                        if activeMethod == .passthrough && viewModel.isMediaActive {
                            Text("media paused")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: .capsule)
                        }
                    }
                    Text(activeMethod.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            networkBackendControls
            engineArmedStatus
            liveFeedStatus
        }
        .padding(.vertical, 2)
        .animation(.spring(duration: 0.3), value: activeMethod)
        .animation(.spring(duration: 0.3), value: viewModel.activeNetworkBackend)
        .animation(.spring(duration: 0.3), value: viewModel.liveFeedRaw)
        .animation(.spring(duration: 0.3), value: viewModel.liveFeedLaneRaw)
        .animation(.spring(duration: 0.3), value: viewModel.liveFeedDowngraded)
        .animation(.spring(duration: 0.3), value: viewModel.engineArmed)
        .animation(.spring(duration: 0.3), value: viewModel.engineArmChecked)
        .sensoryFeedback(.selection, trigger: activeMethod)
        .sensoryFeedback(.selection, trigger: viewModel.activeNetworkBackend)
        .accessibilityIdentifier("browser.injection.picker")
        .accessibilityValue("method=\(activeMethod.rawValue);blockScripts=\(viewModel.activeNetworkBackend.blockDetectionScripts);rewriteProxy=\(viewModel.activeNetworkBackend.useRewriteProxy);engine=\(viewModel.engineArmed);feed=\(viewModel.liveFeedRaw)")
    }

    private var networkBackendControls: some View {
        let backend = viewModel.activeNetworkBackend
        let proxy = NetworkRewriteProxyService.shared
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Network backend", systemImage: backend.isEnabled ? "network.badge.shield.half.filled" : "network")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(backend.isEnabled ? .indigo : .secondary)
                Spacer(minLength: 0)
                if backend.isEnabled {
                    Text("reload needed")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.14), in: .capsule)
                }
            }

            networkToggleRow(
                title: "Block detection scripts",
                subtitle: "Blocks known detection and fingerprint scripts before they run. May break sites that depend on them; reload after changing.",
                icon: "shield.lefthalf.filled",
                tint: .indigo,
                isOn: Binding(
                    get: { viewModel.activeNetworkBackend.blockDetectionScripts },
                    set: { viewModel.setBlockDetectionScriptsEnabled($0) }
                )
            )

            networkToggleRow(
                title: "Rewrite proxy",
                subtitle: "Routes readable pages through the local proxy to strip security policies. HTTPS is tunneled; reload after changing.",
                icon: "arrow.triangle.swap",
                tint: .teal,
                isOn: Binding(
                    get: { viewModel.activeNetworkBackend.useRewriteProxy },
                    set: { viewModel.setRewriteProxyEnabled($0) }
                ),
                status: proxy.statusText,
                isHealthy: proxy.isRunning
            )
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func networkToggleRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        isOn: Binding<Bool>,
        status: String? = nil,
        isHealthy: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Label(status, systemImage: isHealthy ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                        .font(.caption2)
                        .foregroundStyle(isHealthy ? Color.green : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(tint)
                .accessibilityIdentifier("browser.injection.network.\(title.replacingOccurrences(of: " ", with: "_"))")
                .accessibilityValue(isOn.wrappedValue ? "on" : "off")
        }
    }

    /// Honest readout of whether the in-page camera takeover is genuinely armed.
    /// Stays hidden until we've actually checked while injecting; a green line
    /// confirms a healthy engine, and a prominent red warning calls out the exact
    /// failure that would let the real camera pass through every method.
    @ViewBuilder
    private var engineArmedStatus: some View {
        let injecting = viewModel.isMediaActive && viewModel.hasServableStep
        if injecting && viewModel.engineArmChecked {
            if viewModel.engineArmed {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(width: 18)
                    Text("Camera engine armed")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.green.opacity(0.1), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier("browser.injection.engineStatus")
                .accessibilityValue("armed")
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Camera engine not armed")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                        Text(viewModel.engineArmError.isEmpty ? "The real camera may pass through. Reload the site to re-arm the takeover." : viewModel.engineArmError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.red.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier("browser.injection.engineStatus")
                .accessibilityValue("notArmed:\(viewModel.engineArmError)")
            }
        }
    }

    /// Live readout of which feed engine actually engaged for the in-page stream
    /// — clean background track vs Canvas — and, on a genuine downgrade, why.
    @ViewBuilder
    private var liveFeedStatus: some View {
        if viewModel.liveFeedEngaged {
            let clean = viewModel.liveFeedIsClean
            let privateLane = viewModel.liveFeedIsPrivateLane
            let privateLaneFallback = viewModel.liveFeedReasonRaw == "private-lane-fallback"
            let downgraded = viewModel.liveFeedDidDowngrade
            let intentional = viewModel.liveFeedIntentionalCanvas
            let tint: Color = clean ? (privateLaneFallback ? .orange : .green) : (downgraded ? .orange : (intentional ? .cyan : .secondary))
            let icon = clean ? (privateLaneFallback ? "exclamationmark.triangle.fill" : "checkmark.seal.fill") : (downgraded ? "arrow.down.right.circle.fill" : "paintbrush.pointed.fill")
            let title = clean ? (privateLane ? "Clean feed · private lane" : (privateLaneFallback ? "Clean feed · private fallback" : "Clean feed live")) : (downgraded ? "Downgraded to Canvas" : (intentional ? "Canvas draw (photo step)" : "Canvas feed live"))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    if (downgraded || intentional || privateLaneFallback), !viewModel.liveFeedReasonText.isEmpty {
                        Text(viewModel.liveFeedReasonText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if clean {
                        Text(privateLane ? "Running the clean feed through the private lane — no canvas tell." : "Running a clean background track — no canvas tell.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if clean, !viewModel.liveFeedEngineText.isEmpty {
                        Text(viewModel.liveFeedEngineText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
            .accessibilityIdentifier("browser.injection.liveFeedStatus")
            .accessibilityValue("raw=\(viewModel.liveFeedRaw);lane=\(viewModel.liveFeedLaneRaw);downgraded=\(viewModel.liveFeedDowngraded);reason=\(viewModel.liveFeedReasonRaw)")
        }
    }
}

// MARK: - Camera request insight

struct CameraRequestInsightCard: View {
    let insight: CameraRequestInsight?

    var body: some View {
        if let insight {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(tint.opacity(0.16))
                            .frame(width: 36, height: 36)
                        Image(systemName: insight.target == .front ? "person.crop.rectangle" : (insight.target == .back ? "camera.aperture" : "camera.viewfinder"))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latest camera request")
                            .font(.subheadline.weight(.bold))
                        Text(insight.host.isEmpty ? "Current site" : insight.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(insight.target.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: .capsule)
                }

                VStack(spacing: 6) {
                    metricRow("Requested", insight.requestedLabel)
                    metricRow("Predicted phone result", insight.predictedLabel)
                    metricRow("Aspect", insight.aspectLabel)
                    metricRow("Audio", insight.audioRequested ? "Requested" : "No audio")
                    metricRow("Source", insight.dimensionSource.label)
                }

                if !insight.warnings.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6)], spacing: 6) {
                        ForEach(insight.warnings.prefix(4)) { warning in
                            warningChip(warning)
                        }
                    }
                }

                if !insight.notes.isEmpty {
                    Text(insight.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("browser.cameraInsight")
            .accessibilityValue("id=\(insight.id.uuidString);host=\(insight.host);target=\(insight.target.rawValue);requested=\(insight.requestedLabel);predicted=\(insight.predictedLabel);audio=\(insight.audioRequested)")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("No camera request observed yet")
                    .font(.subheadline.weight(.semibold))
                Text("Open a site that asks for video, then the requested size, camera side, predicted phone response, and warnings will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var tint: Color {
        guard let insight else { return .gray }
        switch insight.target {
        case .front: return .cyan
        case .back: return .green
        case .any: return .gray
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func warningChip(_ warning: CameraRequestWarning) -> some View {
        let color = Color(themeName: warning.kind.tintName)
        return VStack(alignment: .leading, spacing: 3) {
            Text(warning.kind.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(warning.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 9))
    }
}

// MARK: - Detection scan card

struct DetectionScanCard: View {
    @Bindable var viewModel: BrowserViewModel

    var body: some View {
        if let detected = viewModel.latestDetectedSystem {
            resultCard(detected)
        } else {
            scanPrompt
        }
    }

    private var scanPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Scan this site")
                .font(.subheadline.weight(.semibold))
            Text("Identify the camera or anti-spoof system in front of you and get a recommended injection method.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            scanButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func resultCard(_ detected: DetectedSystem) -> some View {
        let tint = Color(themeName: detected.category.tintName)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(tint.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: detected.category.icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(detected.systemName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(detected.category.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if detected.host != (viewModel.currentURL?.host() ?? detected.host) {
                        Text("for \(detected.host)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                confidenceBadge(detected)
            }

            if !detected.signals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(detected.signals.prefix(4).enumerated()), id: \.offset) { _, signal in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                            Text(signal)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            recommendationRow(detected)

            Button {
                Haptics.success()
                viewModel.confirmRecommendedProfile()
            } label: {
                Label(
                    viewModel.activeInjectionProfile == detected.recommendedProfile ? "Applied — remember for this site" : "Use \(detected.recommendedProfile.label)",
                    systemImage: viewModel.activeInjectionProfile == detected.recommendedProfile ? "checkmark.circle.fill" : "wand.and.stars"
                )
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(themeName: detected.recommendedProfile.tintName))
            .accessibilityIdentifier("browser.detection.recommendation.apply")
            .accessibilityValue(detected.recommendedProfile.rawValue)

            Divider()
            SiteOutcomeControl(viewModel: viewModel)
            scanButton
        }
        .padding(.vertical, 2)
    }

    private func recommendationRow(_ detected: DetectedSystem) -> some View {
        let tint = Color(themeName: detected.recommendedProfile.tintName)
        return HStack(spacing: 10) {
            Image(systemName: detected.recommendedProfile.icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recommended: \(detected.recommendedProfile.label)")
                    .font(.caption.weight(.semibold))
                Text(detected.memoryInformed ? "Adjusted from your history for this kind of site." : detected.recommendedProfile.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func confidenceBadge(_ detected: DetectedSystem) -> some View {
        let bandColor = Color(themeName: detected.confidenceBand.tintName)
        return VStack(spacing: 1) {
            Text("\(detected.confidence)%")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(bandColor)
            Text(detected.confidenceBand.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(bandColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(bandColor.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var scanButton: some View {
        Button {
            viewModel.inspectCurrentSite()
        } label: {
            if viewModel.isInspectingCurrentSite {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.inspectionStatus.isEmpty ? "Scanning…" : viewModel.inspectionStatus)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            } else {
                Label(viewModel.latestDetectedSystem == nil ? "Scan Current Site" : "Re-scan", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.currentURL == nil || viewModel.isInspectingCurrentSite)
        .accessibilityIdentifier("browser.detection.scan")
        .accessibilityValue(viewModel.isInspectingCurrentSite ? "running" : "ready")
    }
}

// MARK: - Site outcome (thumbs up / down)

struct SiteOutcomeControl: View {
    @Bindable var viewModel: BrowserViewModel

    private var outcome: SiteOutcome { viewModel.currentSiteRecord?.outcome ?? .untested }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Did this method work here?")
                    .font(.caption.weight(.medium))
                if let record = viewModel.currentSiteRecord, record.autoGuessed, record.outcome != .untested {
                    Text("Auto-guessed \(record.outcome.label.lowercased()) — confirm or change")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            thumb(.worked, filled: "hand.thumbsup.fill", outline: "hand.thumbsup", tint: .green)
            thumb(.failed, filled: "hand.thumbsdown.fill", outline: "hand.thumbsdown", tint: .red)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: outcome)
    }

    private func thumb(_ value: SiteOutcome, filled: String, outline: String, tint: Color) -> some View {
        Button {
            Haptics.impact(.light)
            viewModel.setCurrentSiteOutcome(value)
        } label: {
            Image(systemName: outcome == value ? filled : outline)
                .font(.subheadline)
                .foregroundStyle(outcome == value ? tint : .secondary)
                .frame(width: 36, height: 30)
                .background((outcome == value ? tint : Color.gray).opacity(0.12), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentURL == nil)
        .accessibilityIdentifier("browser.siteOutcome.\(value.rawValue)")
        .accessibilityValue(outcome.rawValue)
    }
}
