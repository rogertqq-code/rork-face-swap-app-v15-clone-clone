import SwiftUI

struct ProfileSelectionView: View {
    let profileManager: DeviceProfileManager
    /// True only for the first-run onboarding gate. When shown as the Profile
    /// tab this is false, so the active profile reads as a manager (no leftover
    /// "Continue" button).
    var isOnboarding: Bool = false
    let onProfileSelected: () -> Void
    @State private var showCreateProfile: Bool = false
    @State private var profileToDelete: DeviceProfile?
    @State private var showDeleteConfirm: Bool = false
    @State private var expandedProfileID: UUID?
    @State private var recalibratingProfileID: UUID?
    @State private var calibrationStatus: String = ""
    @State private var verificationProfile: DeviceProfile?
    @Environment(OfflineVerificationStore.self) private var verificationStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    
                    if !profileManager.profiles.isEmpty {
                        existingProfilesSection
                    }

                    createNewButton
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Device Profiles")
            .sheet(isPresented: $showCreateProfile) {
                ProfileCreationView(profileManager: profileManager) {
                    onProfileSelected()
                }
            }
            .sheet(item: $verificationProfile) { profile in
                OfflineVerificationFlowView(profile: profile) { report in
                    verificationStore.append(report)
                    verificationProfile = nil
                }
            }
            .alert("Delete Profile?", isPresented: $showDeleteConfirm, presenting: profileToDelete) { profile in
                Button("Delete", role: .destructive) {
                    withAnimation(.spring(duration: 0.3)) {
                        verificationStore.removeAll(for: profile.id)
                        profileManager.deleteProfile(profile)
                    }
                }
                .accessibilityIdentifier("profile.delete.confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("profile.delete.cancel")
            } message: { profile in
                Text("This will permanently remove \"\(profile.name)\" and all its device data.")
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("profile.screen")
        .accessibilityValue("activeProfile=\(profileManager.activeProfileID?.uuidString ?? "none");count=\(profileManager.profiles.count);onboarding=\(isOnboarding)")
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image("BrandLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 168)
                .clipShape(.rect(cornerRadius: 26))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .cyan.opacity(0.35), radius: 22, y: 8)
                .padding(.top, 20)
                .accessibilityLabel("Fraudomatic KYC")

            VStack(spacing: 6) {
                Text("Device Profiles")
                    .font(.title2.bold())

                Text("Scan your device to capture device specs,\nresolution, bitrate, and web fingerprint data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(AppVersion.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private var existingProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Profiles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(profileManager.profiles) { profile in
                profileCard(profile)
            }
        }
    }

    private func profileCard(_ profile: DeviceProfile) -> some View {
        let isActive = profileManager.activeProfileID == profile.id
        let isExpanded = expandedProfileID == profile.id
        let verificationStatus = verificationStore.status(for: profile)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    if isExpanded {
                        expandedProfileID = nil
                    } else {
                        expandedProfileID = profile.id
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isActive ? Color.cyan.opacity(0.15) : Color(.tertiarySystemFill))
                            .frame(width: 48, height: 48)

                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 20))
                            .foregroundStyle(isActive ? .cyan : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.cyan.opacity(0.15), in: Capsule())
                            }
                        }

                        HStack(spacing: 8) {
                            Label("\(profile.cameras.count)", systemImage: "camera.fill")
                            Text("•")
                            Text(profile.deviceHardware.systemVersion)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Label(verificationStatus.title, systemImage: verificationStatus.iconName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(verificationColor(for: verificationStatus.tintName))
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
            }
            .accessibilityIdentifier("profile.card.\(profile.id.uuidString)")
            .accessibilityValue("name=\(profile.name);active=\(isActive);expanded=\(isExpanded);verification=\(verificationStatus.title)")

            if isExpanded {
                expandedDetails(profile, isActive: isActive)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func expandedDetails(_ profile: DeviceProfile, isActive: Bool) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 10) {
                specRow("Device", profile.deviceHardware.modelIdentifier)
                specRow("OS", "\(profile.deviceHardware.systemName) \(profile.deviceHardware.systemVersion)")
                specRow("Screen", profile.deviceHardware.screenNativeBounds)

                if let front = profile.frontCamera {
                    specRow("Front Cam", "\(front.activeWidth)×\(front.activeHeight) @ \(Int(front.activeFrameRate))fps")
                }
                if let back = profile.backCamera {
                    specRow("Back Cam", "\(back.activeWidth)×\(back.activeHeight) @ \(Int(back.activeFrameRate))fps")
                }

                if let front = profile.frontCamera, let bitrate = front.testClipBitrate {
                    specRow("Bitrate", "\(bitrate / 1000)kbps (\(front.testClipCodec ?? "h264"))")
                }

                if !profile.microphones.isEmpty {
                    let mic = profile.microphones[0]
                    specRow("Microphone", "\(mic.label) (\(Int(mic.sampleRate))Hz)")
                }

                if let test = profile.mediaTestResult {
                    specRow("Loom Media", String(format: "%.0f%% match (%d/%d fields)", test.matchPercentage, test.comparisons.filter { $0.matches }.count, test.comparisons.count))
                }

                verificationSummary(profile)
                responseMapSummary(profile)

                specRow("User Agent", String(profile.webFingerprint.userAgent.prefix(60)) + "…")

                HStack(spacing: 10) {
                    if !isActive {
                        Button {
                            withAnimation(.spring(duration: 0.3)) {
                                profileManager.selectProfile(profile)
                                onProfileSelected()
                            }
                        } label: {
                            Label("Use Profile", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(.cyan, in: .rect(cornerRadius: 10))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.dsPress)
                        .accessibilityIdentifier("profile.select.\(profile.id.uuidString)")
                    } else if isOnboarding {
                        Button {
                            onProfileSelected()
                        } label: {
                            Label("Continue", systemImage: "arrow.right.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(.cyan, in: .rect(cornerRadius: 10))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.dsPress)
                        .accessibilityIdentifier("profile.continue.\(profile.id.uuidString)")
                    } else {
                        Label("Active Profile", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.cyan.opacity(0.14), in: .rect(cornerRadius: 10))
                    }

                    Button {
                        recalibrate(profile)
                    } label: {
                        if recalibratingProfileID == profile.id {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 40, height: 38)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.subheadline)
                                .frame(width: 40, height: 38)
                        }
                    }
                    .buttonStyle(.dsPress)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                    .disabled(recalibratingProfileID != nil)
                    .accessibilityIdentifier("profile.recalibrate.\(profile.id.uuidString)")
                    .accessibilityValue(recalibratingProfileID == profile.id ? calibrationStatus : "ready")

                    Button(role: .destructive) {
                        profileToDelete = profile
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .frame(width: 40, height: 38)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.dsPress)
                    .accessibilityIdentifier("profile.delete.\(profile.id.uuidString)")
                }
                .padding(.top, 4)

                HStack(spacing: 10) {
                    Button {
                        verificationProfile = profile
                    } label: {
                        Label("Run Device Verification", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                    .accessibilityIdentifier("profile.verify.\(profile.id.uuidString)")

                    NavigationLink {
                        OfflineVerificationReportView(profile: profile, store: verificationStore)
                    } label: {
                        Label("View Report", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .accessibilityIdentifier("profile.report.\(profile.id.uuidString)")
                }
            }
            .padding(14)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func verificationSummary(_ profile: DeviceProfile) -> some View {
        let status = verificationStore.status(for: profile)
        let latest = verificationStore.latestReport(for: profile.id)
        let tint = verificationColor(for: status.tintName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: status.iconName)
                    .foregroundStyle(tint)
                Text("Device Verification")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(status.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
            }
            if let latest {
                Text("Last run \(latest.timestamp, style: .relative) ago · \(latest.passCount) local checks passed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Run the offline device check before relying on this profile's recommendation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(tint.opacity(0.09), in: .rect(cornerRadius: 10))
        .accessibilityIdentifier("profile.verificationStatus.\(profile.id.uuidString)")
        .accessibilityValue(status.title)
    }

    private func verificationColor(for name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "cyan": .cyan
        default: .secondary
        }
    }

    private func responseMapSummary(_ profile: DeviceProfile) -> some View {
        let map = profile.cameraResponseMap ?? CameraResponseCalibrationService.responseMap(for: profile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.cyan)
                Text("Device Response Map")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(map.results.count) variants")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.cyan)
            }
            HStack(spacing: 8) {
                responseChip("Front", count: map.frontResults.count, color: .cyan)
                responseChip("Back", count: map.backResults.count, color: .green)
                responseChip("Web", count: map.browserResults.count, color: .blue)
                responseChip("Native", count: map.nativeResults.count, color: .orange)
            }
            if let best = map.results.max(by: { $0.confidence < $1.confidence }) {
                Text("Best: \(best.matchType.label) · \(best.actualLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if recalibratingProfileID == profile.id && !calibrationStatus.isEmpty {
                Text(calibrationStatus)
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.cyan.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func responseChip(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
    }

    private func recalibrate(_ profile: DeviceProfile) {
        recalibratingProfileID = profile.id
        calibrationStatus = "Requesting camera permission…"
        Task {
            let calibration = CameraResponseCalibrationService()
            let map = await calibration.calibrate(profile: profile)
            await MainActor.run {
                var updated = profile
                updated.cameraResponseMap = map
                profileManager.updateProfile(updated)
                calibrationStatus = "Saved \(map.results.count) camera response results"
                recalibratingProfileID = nil
            }
        }
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private var createNewButton: some View {
        Button {
            showCreateProfile = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.cyan.opacity(0.5))
                        .frame(width: 48, height: 48)

                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Create New Profile")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Scan this device's specs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
        .accessibilityIdentifier("profile.create")
    }
}
