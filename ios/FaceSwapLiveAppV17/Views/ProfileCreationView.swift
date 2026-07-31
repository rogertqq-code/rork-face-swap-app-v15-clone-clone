import SwiftUI

struct ProfileCreationView: View {
    let profileManager: DeviceProfileManager
    let onComplete: () -> Void
    @State private var scanner = SetupService()
    @State private var profileName: String = ""
    @State private var createdProfile: DeviceProfile?
    @State private var verificationReport: OfflineVerificationReport?
    @State private var showVerification: Bool = false
    @State private var showMediaTestDetails: Bool = false
    @Environment(OfflineVerificationStore.self) private var verificationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if let profile = createdProfile {
                    scanCompleteView(profile)
                } else {
                    scanningView
                }
            }
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(scanner.isScanning)
                }
            }
        }
        .sheet(isPresented: $showVerification) {
            if let profile = createdProfile {
                OfflineVerificationFlowView(profile: profile) { report in
                    verificationReport = report
                    showVerification = false
                }
            }
        }
    }

    private var scanningView: some View {
        VStack(spacing: 32) {
            Spacer()

            scanAnimationView

            VStack(spacing: 8) {
                Text(scanner.phase.label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.3), value: scanner.phase.label)

                if scanner.isScanning {
                    Text("Scanning device hardware, microphones, and browser baseline data.\nOffline verification follows before this profile is saved…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if scanner.isScanning {
                VStack(spacing: 8) {
                    ProgressView(value: scanner.progress)
                        .tint(.cyan)
                        .animation(.spring(duration: 0.4), value: scanner.progress)

                    Text("\(Int(scanner.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
            }

            if !scanner.isScanning && createdProfile == nil {
                if case .failed(let msg) = scanner.phase {
                    VStack(spacing: 12) {
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(.red)

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }

                Button {
                    startScan()
                } label: {
                    Label("Start Device Scan", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.cyan, in: .rect(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 24)
            }

            Spacer()
        }
    }

    private var scanAnimationView: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(.cyan.opacity(scanner.isScanning ? 0.2 : 0.05), lineWidth: 1.5)
                    .frame(width: CGFloat(100 + i * 40), height: CGFloat(100 + i * 40))
                    .scaleEffect(scanner.isScanning ? 1.1 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.3),
                        value: scanner.isScanning
                    )
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.cyan.opacity(0.3), .cyan.opacity(0.05)],
                        center: .center,
                        startRadius: 10,
                        endRadius: 50
                    )
                )
                .frame(width: 90, height: 90)

            Image(systemName: scanner.isScanning ? "wave.3.right" : "iphone.gen3")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.cyan)
                .symbolEffect(.variableColor.iterative, isActive: scanner.isScanning)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func scanCompleteView(_ profile: DeviceProfile) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                }
                .padding(.top, 20)

                VStack(spacing: 6) {
                    Text("Device Profile Ready")
                        .font(.title3.bold())

                    Text("Review the device scan, then complete the required offline verification before saving.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                nameField

                verificationSummary(profile)

                resultsSummary(profile)

                if let testResult = profile.mediaTestResult {
                    safariCorrelationCard(testResult)
                    mediaMatchBanner(testResult)
                }

                cameraDetailsList(profile)

                microphoneDetailsList(profile)

                if let testResult = profile.mediaTestResult {
                    mediaComparisonSection(testResult)
                }

                saveButton(profile)
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile Name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("e.g. My iPhone 15 Pro", text: $profileName)
                .font(.body)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func resultsSummary(_ profile: DeviceProfile) -> some View {
        VStack(spacing: 0) {
            summaryRow(icon: "cpu", label: "Device", value: profile.deviceHardware.modelIdentifier)
            Divider().padding(.leading, 44)
            summaryRow(icon: "gear", label: "OS", value: "\(profile.deviceHardware.systemName) \(profile.deviceHardware.systemVersion)")
            Divider().padding(.leading, 44)
            summaryRow(icon: "rectangle.stack", label: "Devices", value: "\(profile.cameras.count) detected")
            Divider().padding(.leading, 44)
            summaryRow(icon: "mic.fill", label: "Microphones", value: "\(profile.microphones.count) detected")
            Divider().padding(.leading, 44)
            summaryRow(icon: "display", label: "Screen", value: profile.deviceHardware.screenNativeBounds)
            Divider().padding(.leading, 44)
            summaryRow(icon: "globe", label: "Web Fingerprint", value: "Captured")
            Divider().padding(.leading, 44)
            summaryRow(icon: "memorychip", label: "RAM", value: String(format: "%.1f GB", profile.deviceHardware.physicalMemoryGB))
            Divider().padding(.leading, 44)

            if let test = profile.mediaTestResult {
                summaryRow(
                    icon: "video.badge.checkmark",
                    label: "Media Baseline",
                    value: String(format: "%.0f%% match", test.matchPercentage)
                )
            } else {
                summaryRow(icon: "video.slash", label: "Media Baseline", value: "Not captured")
            }
            Divider().padding(.leading, 44)
            
            if let rec = profile.recommendedMethod {
                summaryRow(icon: "bolt.horizontal.fill", label: "Recommended", value: rec.label)
            } else {
                summaryRow(icon: "bolt.horizontal", label: "Recommended", value: "Pending")
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func safariCorrelationCard(_ result: MediaTestResult) -> some View {
        let matchPct = result.matchPercentage
        let color: Color = matchPct >= 90 ? .green : matchPct >= 70 ? .orange : .red
        let icon = matchPct >= 90 ? "checkmark.seal.fill" : matchPct >= 70 ? "exclamationmark.triangle.fill" : "xmark.seal.fill"
        let matchCount = result.comparisons.filter { $0.matches }.count

        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.title3)
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Safari Correlation")
                        .font(.subheadline.weight(.semibold))
                    Text("Real getUserMedia probe vs injection-served identity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }

            HStack {
                Text("\(matchCount)/\(result.comparisons.count) fields match")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", matchPct))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(color)
            }

            ProgressView(value: matchPct / 100)
                .tint(color)

            if !result.comparisons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.comparisons.prefix(8).enumerated()), id: \.offset) { _, comp in
                        HStack(spacing: 6) {
                            Image(systemName: comp.matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(comp.matches ? .green : .red)
                            Text(comp.field)
                                .font(.system(size: 10).weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Spacer()
                            Text(comp.matches ? "Match" : "Adjusted")
                                .font(.system(size: 9).weight(.semibold))
                                .foregroundStyle(comp.matches ? .green : .orange)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private func mediaMatchBanner(_ result: MediaTestResult) -> some View {
        let matchPct = result.matchPercentage
        let color: Color = matchPct >= 90 ? .green : matchPct >= 70 ? .orange : .red
        let icon = matchPct >= 90 ? "checkmark.seal.fill" : matchPct >= 70 ? "exclamationmark.triangle.fill" : "xmark.seal.fill"

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Loom Media Test")
                        .font(.subheadline.weight(.semibold))
                    Text("\(Int(result.comparisons.filter { $0.matches }.count))/\(result.comparisons.count) fields match between real & processed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(String(format: "%.0f%%", matchPct))
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(color)
            }

            ProgressView(value: matchPct / 100)
                .tint(color)
        }
        .padding(14)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.cyan)
                .frame(width: 28)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func cameraDetailsList(_ profile: DeviceProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Devices")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(profile.cameras) { cam in
                cameraCard(cam)
            }
        }
    }

    private func cameraCard(_ cam: CameraDeviceSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: cam.position == "front" ? "camera.fill" : "camera.badge.ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.cyan)

                Text(cam.label)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(cam.position.capitalized)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                specChip("Max Res", "\(cam.maxWidth)×\(cam.maxHeight)")
                specChip("Active", "\(cam.activeWidth)×\(cam.activeHeight)")
                specChip("FPS", "\(Int(cam.minFrameRate))-\(Int(cam.maxFrameRate))")
                specChip("Type", cam.deviceType)

                if let bitrate = cam.testClipBitrate {
                    specChip("Bitrate", "\(bitrate / 1000)kbps")
                }
                if let codec = cam.testClipCodec {
                    specChip("Codec", codec.uppercased())
                }
                if let colorSpace = cam.activeColorSpace {
                    specChip("Color", colorSpace)
                }
                if let primaries = cam.testClipColorPrimaries {
                    specChip("Primaries", primaries)
                }

                specChip("Flash", cam.hasFlash ? "Yes" : "No")
                specChip("Zoom", String(format: "%.1fx", cam.maxZoomFactor))
                specChip("ISO", "\(Int(cam.minISO))-\(Int(cam.maxISO))")
                specChip("Aperture", String(format: "f/%.1f", cam.lensAperture ?? 0))
                specChip("Formats", "\(cam.supportedFormats.count)")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func microphoneDetailsList(_ profile: DeviceProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone Devices")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(profile.microphones) { mic in
                microphoneCard(mic)
            }
        }
    }

    private func microphoneCard(_ mic: MicrophoneDeviceSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "mic.fill")
                    .font(.subheadline)
                    .foregroundStyle(.cyan)

                Text(mic.label)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(mic.position.capitalized)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                specChip("Sample Rate", "\(Int(mic.sampleRate))Hz")
                specChip("Channels", "\(mic.channelCount)")
                specChip("Type", mic.deviceType)
                specChip("Sources", "\(mic.dataSources.count)")

                if let testSR = mic.testSampleRate {
                    specChip("Test SR", "\(Int(testSR))Hz")
                }
                if let testBD = mic.testBitDepth, testBD > 0 {
                    specChip("Bit Depth", "\(testBD)-bit")
                }
            }

            if !mic.dataSources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Sources")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    ForEach(mic.dataSources, id: \.dataSourceID) { src in
                        HStack(spacing: 6) {
                            Text(src.dataSourceName)
                                .font(.caption2)
                            if let loc = src.location {
                                Text("(\(loc))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let pattern = src.selectedPolarPattern {
                                Text(pattern)
                                    .font(.caption2)
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func mediaComparisonSection(_ result: MediaTestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showMediaTestDetails.toggle()
                }
            } label: {
                HStack {
                    Text("Media Comparison Details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showMediaTestDetails ? 180 : 0))
                }
            }

            if showMediaTestDetails {
                realDescriptorsCard(result.realSnapshot)

                if let processed = result.processedSnapshot {
                    processedDescriptorsCard(processed)
                }

                comparisonTable(result.comparisons)
            }
        }
    }

    private func realDescriptorsCard(_ snapshot: MediaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.blue)
                Text("Real Source (from Loom)")
                    .font(.subheadline.weight(.semibold))
            }

            let videoDevices = snapshot.devices.filter { $0.kind == "videoinput" }
            ForEach(videoDevices) { dev in
                VStack(alignment: .leading, spacing: 4) {
                    descriptorRow("Label", dev.label)
                    descriptorRow("Device ID", String(dev.deviceId.prefix(40)))
                    descriptorRow("Group ID", String(dev.groupId.prefix(40)))
                }
            }

            let audioDevices = snapshot.devices.filter { $0.kind == "audioinput" }
            if !audioDevices.isEmpty {
                Divider()
                Text("Audio Devices")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(audioDevices) { dev in
                    VStack(alignment: .leading, spacing: 4) {
                        descriptorRow("Label", dev.label)
                        descriptorRow("Device ID", String(dev.deviceId.prefix(40)))
                        descriptorRow("Group ID", String(dev.groupId.prefix(40)))
                    }
                }
            }

            if let s = snapshot.trackSettings {
                Divider()
                Text("Track Settings")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                descriptorRow("Resolution", "\(s.width)×\(s.height)")
                descriptorRow("Frame Rate", String(format: "%.1f", s.frameRate))
                descriptorRow("Facing Mode", s.facingMode)
                descriptorRow("Aspect Ratio", String(format: "%.4f", s.aspectRatio))
                descriptorRow("Resize Mode", s.resizeMode)
                descriptorRow("Device ID", String(s.deviceId.prefix(40)))
                descriptorRow("Group ID", String(s.groupId.prefix(40)))
            }

            if let c = snapshot.trackCapabilities {
                Divider()
                Text("Track Capabilities")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                descriptorRow("Width", "\(c.widthMin)-\(c.widthMax)")
                descriptorRow("Height", "\(c.heightMin)-\(c.heightMax)")
                descriptorRow("FPS", String(format: "%.0f-%.0f", c.frameRateMin, c.frameRateMax))
                descriptorRow("Facing Modes", c.facingModes.joined(separator: ", "))
                descriptorRow("Resize Modes", c.resizeModes.joined(separator: ", "))
            }

            Divider()
            descriptorRow("Track Label", snapshot.trackLabel)
            descriptorRow("Ready State", snapshot.trackReadyState)
            descriptorRow("Supported Constraints", "\(snapshot.supportedConstraints.count)")
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func processedDescriptorsCard(_ snapshot: MediaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.purple)
                Text("Processed Source")
                    .font(.subheadline.weight(.semibold))
            }

            let videoDevices = snapshot.devices.filter { $0.kind == "videoinput" }
            ForEach(videoDevices) { dev in
                VStack(alignment: .leading, spacing: 4) {
                    descriptorRow("Label", dev.label)
                    descriptorRow("Device ID", String(dev.deviceId.prefix(40)))
                    descriptorRow("Group ID", String(dev.groupId.prefix(40)))
                }
            }

            if let s = snapshot.trackSettings {
                Divider()
                Text("Track Settings")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                descriptorRow("Resolution", "\(s.width)×\(s.height)")
                descriptorRow("Frame Rate", String(format: "%.1f", s.frameRate))
                descriptorRow("Facing Mode", s.facingMode)
                descriptorRow("Aspect Ratio", String(format: "%.4f", s.aspectRatio))
                descriptorRow("Resize Mode", s.resizeMode)
            }

            if let c = snapshot.trackCapabilities {
                Divider()
                Text("Track Capabilities")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                descriptorRow("Width", "\(c.widthMin)-\(c.widthMax)")
                descriptorRow("Height", "\(c.heightMin)-\(c.heightMax)")
                descriptorRow("FPS", String(format: "%.0f-%.0f", c.frameRateMin, c.frameRateMax))
                descriptorRow("Facing Modes", c.facingModes.joined(separator: ", "))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func comparisonTable(_ comparisons: [MediaComparisonResult]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            comparisonHeader

            ForEach(Array(comparisons.enumerated()), id: \.offset) { _, comp in
                comparisonRow(comp)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var comparisonHeader: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.cyan)
            Text("Field-by-Field Comparison")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func comparisonRow(_ comp: MediaComparisonResult) -> some View {
        let iconName: String = comp.matches ? "checkmark.circle.fill" : "xmark.circle.fill"
        let iconColor: Color = comp.matches ? .green : .red
        let realText: String = comp.realValue.isEmpty ? "\u{2014}" : comp.realValue
        let procText: String = comp.processedValue.isEmpty ? "\u{2014}" : comp.processedValue
        let bgColor: Color = comp.matches ? .clear : Color.red.opacity(0.05)

        return HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(comp.field)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(realText)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(procText)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(bgColor, in: .rect(cornerRadius: 6))
    }

    private func descriptorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private func specChip(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
    }

    private func verificationSummary(_ profile: DeviceProfile) -> some View {
        let report = verificationReport
        let tint: Color = report.map { verificationColor(for: $0.outcome.tintName) } ?? .orange
        let title = report?.outcome.title ?? "Verification required"
        let detail = report == nil
            ? "Run the offline device check before saving. You can explicitly save with a warning if a check is unavailable."
            : "Saved result: \(report?.passCount ?? 0) local checks passed. Browser and external-site compatibility remain separately unverified."

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: report?.outcome.iconName ?? "exclamationmark.shield.fill")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if report != nil {
                    Button("Run Again") { showVerification = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if report == nil {
                Button {
                    showVerification = true
                } label: {
                    Label("Run Device Verification", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding(14)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func verificationColor(for name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }

    private func saveButton(_ profile: DeviceProfile) -> some View {
        Button {
            guard let verificationReport else {
                showVerification = true
                return
            }
            var finalProfile = profile
            if !profileName.trimmingCharacters(in: .whitespaces).isEmpty {
                finalProfile.name = profileName
            }
            profileManager.addProfile(finalProfile)
            verificationStore.append(verificationReport)
            onComplete()
            dismiss()
        } label: {
            Label(
                verificationReport == nil ? "Run Verification to Continue" : "Save & Use Profile",
                systemImage: verificationReport == nil ? "checkmark.shield.fill" : "checkmark.circle.fill"
            )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(verificationReport == nil ? .orange : .cyan, in: .rect(cornerRadius: 14))
                .foregroundStyle(.black)
        }
        .padding(.top, 8)
    }

    private func startScan() {
        Task {
            if let profile = await scanner.runFullScan() {
                profileName = profile.name
                verificationReport = nil
                withAnimation(.spring(duration: 0.4)) {
                    createdProfile = profile
                }
            }
        }
    }
}
