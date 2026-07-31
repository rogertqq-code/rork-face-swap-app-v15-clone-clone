import AVFoundation
import Observation
import UIKit

/// Runs app-owned, offline-capable verification checks. It intentionally does not
/// claim that a remote site, browser permission prompt, or third-party flow has
/// been verified; those remain separately marked until observed by a mounted
/// app-owned browser fixture or a real user confirmation.
@MainActor
@Observable
final class OfflineVerificationService {
    var isRunning: Bool = false
    var progress: Double = 0
    var progressLabel: String = ""

    func runAutomaticChecks(profile: DeviceProfile) async -> OfflineVerificationReport {
        isRunning = true
        progress = 0
        progressLabel = "Checking the device profile…"
        defer {
            isRunning = false
            progress = 1
            progressLabel = "Offline checks complete"
        }

        var checks: [OfflineVerificationCheck] = []

        let cameraSpecs = profile.cameras.filter {
            $0.activeWidth > 0 && $0.activeHeight > 0 && $0.activeFrameRate > 0
        }
        checks.append(OfflineVerificationCheck(
            id: .profileShape,
            status: cameraSpecs.isEmpty ? .needsAttention : .passed,
            summary: cameraSpecs.isEmpty
                ? "No camera profile with a usable size and frame rate was found."
                : "\(cameraSpecs.count) camera profile\(cameraSpecs.count == 1 ? "" : "s") include usable dimensions and frame rates.",
            evidence: "cameras=\(profile.cameras.count), valid=\(cameraSpecs.count)",
            isRequired: true
        ))

        progress = 0.20
        progressLabel = "Checking camera permission…"
        await Task.yield()

        let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        checks.append(permissionCheck(
            id: .cameraPermission,
            authorization: cameraAuthorization,
            label: "Camera",
            isRequired: true
        ))

        progress = 0.38
        progressLabel = "Checking microphone readiness…"
        await Task.yield()

        let microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        let usableMicrophones = profile.microphones.filter {
            $0.sampleRate > 0 && $0.channelCount > 0
        }
        let hasRecordedAudio = profile.microphones.contains {
            ($0.testSampleRate ?? 0) > 0 && ($0.testChannelCount ?? 0) > 0
        }
        let microphoneStatus: OfflineVerificationCheckStatus
        let microphoneSummary: String
        if usableMicrophones.isEmpty {
            microphoneStatus = .needsAttention
            microphoneSummary = "No microphone profile reported a usable sample rate and channel count."
        } else if microphoneAuthorization != .authorized {
            microphoneStatus = .needsUserConfirmation
            microphoneSummary = "Microphone access still needs confirmation before its recorded profile can be trusted."
        } else if hasRecordedAudio {
            microphoneStatus = .passed
            microphoneSummary = "\(usableMicrophones.count) microphone profile\(usableMicrophones.count == 1 ? "" : "s") are ready with a recorded audio sample."
        } else {
            microphoneStatus = .needsAttention
            microphoneSummary = "Microphone hardware was found, but no valid recorded sample is available yet."
        }
        checks.append(OfflineVerificationCheck(
            id: .microphoneReadiness,
            status: microphoneStatus,
            summary: microphoneSummary,
            evidence: "microphones=\(profile.microphones.count), usable=\(usableMicrophones.count), sample=\(hasRecordedAudio)",
            isRequired: true
        ))

        progress = 0.58
        progressLabel = "Preparing a local test image…"
        await Task.yield()

        checks.append(mediaPreparationCheck())

        progress = 0.76
        progressLabel = "Checking the guided camera step…"
        await Task.yield()

        let canOpenCamera = CameraCaptureView.isCameraAvailable
        checks.append(OfflineVerificationCheck(
            id: .guidedCameraCapture,
            status: canOpenCamera ? .needsUserConfirmation : .unavailable,
            summary: canOpenCamera
                ? "Take one real test photo to confirm the system camera returns media to the app."
                : "No system camera is currently available on this device. This check cannot be completed here.",
            evidence: "cameraAvailable=\(canOpenCamera)",
            isRequired: true
        ))

        // The user explicitly chose offline verification. Do not turn an absence of
        // external-site evidence into a false pass.
        checks.append(OfflineVerificationCheck(
            id: .browserCompatibility,
            status: .needsUserConfirmation,
            summary: "External browser permissions and strict third-party-site behavior are not proven by offline checks.",
            evidence: "offline-only verification",
            isRequired: false
        ))

        progress = 0.92
        progressLabel = "Preparing your verification summary…"
        await Task.yield()

        return makeReport(profile: profile, checks: checks)
    }

    /// Updates a run after the user completes the real system camera step. The
    /// photo stays in memory only long enough to verify the local processing path.
    func recordGuidedCameraCapture(
        image: UIImage,
        source: CameraCaptureView.Source,
        in report: OfflineVerificationReport
    ) -> OfflineVerificationReport {
        var checks = report.checks
        let nextCheck: OfflineVerificationCheck

        guard source == .camera else {
            nextCheck = OfflineVerificationCheck(
                id: .guidedCameraCapture,
                status: .unavailable,
                summary: "The system camera was unavailable, so the photo library was used instead. This does not verify a real camera capture.",
                evidence: "source=photoLibrary",
                isRequired: true
            )
            replace(check: nextCheck, in: &checks)
            return makeReport(profileID: report.profileID, basedOn: report, checks: checks)
        }

        let bytes = EXIFMetadataService().strippedJPEGData(image: image, maxBytes: 1_400_000)
        if let bytes, !bytes.isEmpty, bytes.count <= 1_400_000 {
            nextCheck = OfflineVerificationCheck(
                id: .guidedCameraCapture,
                status: .passed,
                summary: "A real system-camera photo returned to the app and completed local media preparation.",
                evidence: "source=camera, bytes=\(bytes.count)",
                isRequired: true
            )
        } else {
            nextCheck = OfflineVerificationCheck(
                id: .guidedCameraCapture,
                status: .needsAttention,
                summary: "The camera returned a photo, but the app could not prepare a valid local test image.",
                evidence: "source=camera, preparation=failed",
                isRequired: true
            )
        }
        replace(check: nextCheck, in: &checks)
        return makeReport(profileID: report.profileID, basedOn: report, checks: checks)
    }

    func skippedReport(for profile: DeviceProfile) -> OfflineVerificationReport {
        let checks = OfflineVerificationCheckID.allCases.map { id in
            OfflineVerificationCheck(
                id: id,
                status: .skipped,
                summary: "This check was skipped and can be rerun from the device profile.",
                evidence: "user-skipped",
                isRequired: id != .browserCompatibility && id != .browserFixture
            )
        }
        return OfflineVerificationReport(
            profileID: profile.id,
            hardwareSignature: OfflineVerificationReport.hardwareSignature(for: profile),
            capabilities: capabilitySummary(for: profile),
            checks: checks,
            outcome: .skipped
        )
    }

    nonisolated static func outcome(for checks: [OfflineVerificationCheck]) -> OfflineVerificationOutcome {
        guard !checks.isEmpty else { return .inconclusive }
        if checks.allSatisfy({ $0.status == .skipped }) { return .skipped }

        let requiredChecks = checks.filter(\.isRequired)
        guard !requiredChecks.isEmpty else { return .inconclusive }
        if requiredChecks.contains(where: { $0.status == .needsAttention }) {
            return .needsAttention
        }
        if requiredChecks.contains(where: {
            $0.status == .unavailable || $0.status == .needsUserConfirmation || $0.status == .skipped
        }) {
            return .inconclusive
        }
        return requiredChecks.allSatisfy { $0.status == .passed } ? .verified : .inconclusive
    }

    private func permissionCheck(
        id: OfflineVerificationCheckID,
        authorization: AVAuthorizationStatus,
        label: String,
        isRequired: Bool
    ) -> OfflineVerificationCheck {
        switch authorization {
        case .authorized:
            return OfflineVerificationCheck(
                id: id,
                status: .passed,
                summary: "\(label) permission is granted.",
                evidence: "authorized",
                isRequired: isRequired
            )
        case .notDetermined:
            return OfflineVerificationCheck(
                id: id,
                status: .needsUserConfirmation,
                summary: "\(label) permission has not been requested yet.",
                evidence: "notDetermined",
                isRequired: isRequired
            )
        case .denied, .restricted:
            return OfflineVerificationCheck(
                id: id,
                status: .needsAttention,
                summary: "\(label) permission is not available. Enable it in Settings, then run this check again.",
                evidence: authorization == .denied ? "denied" : "restricted",
                isRequired: isRequired
            )
        @unknown default:
            return OfflineVerificationCheck(
                id: id,
                status: .unavailable,
                summary: "\(label) permission returned an unsupported state.",
                evidence: "unknown",
                isRequired: isRequired
            )
        }
    }

    private func mediaPreparationCheck() -> OfflineVerificationCheck {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor(red: 0.05, green: 0.68, blue: 0.76, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        guard let data = EXIFMetadataService().strippedJPEGData(image: image, maxBytes: 80_000),
              !data.isEmpty,
              data.count <= 80_000,
              UIImage(data: data) != nil
        else {
            return OfflineVerificationCheck(
                id: .mediaPreparation,
                status: .needsAttention,
                summary: "The app could not prepare a small local media payload.",
                evidence: "local-jpeg=failed",
                isRequired: true
            )
        }
        return OfflineVerificationCheck(
            id: .mediaPreparation,
            status: .passed,
            summary: "A local image was prepared inside the hand-off size budget.",
            evidence: "local-jpeg-bytes=\(data.count)",
            isRequired: true
        )
    }

    private func makeReport(
        profile: DeviceProfile,
        checks: [OfflineVerificationCheck]
    ) -> OfflineVerificationReport {
        OfflineVerificationReport(
            profileID: profile.id,
            hardwareSignature: OfflineVerificationReport.hardwareSignature(for: profile),
            capabilities: capabilitySummary(for: profile),
            checks: checks,
            outcome: Self.outcome(for: checks)
        )
    }

    private func makeReport(
        profileID: UUID,
        basedOn report: OfflineVerificationReport,
        checks: [OfflineVerificationCheck]
    ) -> OfflineVerificationReport {
        OfflineVerificationReport(
            profileID: profileID,
            hardwareSignature: report.hardwareSignature,
            capabilities: report.capabilities,
            checks: checks,
            outcome: Self.outcome(for: checks),
            fixtureMethod: report.fixtureMethod,
            fixtureSummary: report.fixtureSummary
        )
    }

    private func capabilitySummary(for profile: DeviceProfile) -> OfflineVerificationCapabilitySummary {
        OfflineVerificationCapabilitySummary(
            modelIdentifier: profile.deviceHardware.modelIdentifier,
            systemVersion: profile.deviceHardware.systemVersion,
            cameraCount: profile.cameras.count,
            microphoneCount: profile.microphones.count,
            cameraAuthorized: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    private func replace(check: OfflineVerificationCheck, in checks: inout [OfflineVerificationCheck]) {
        if let index = checks.firstIndex(where: { $0.id == check.id }) {
            checks[index] = check
        } else {
            checks.append(check)
        }
    }
}
