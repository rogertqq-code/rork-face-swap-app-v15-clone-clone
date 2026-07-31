import SwiftUI

/// Drives the eyedeekit verification template. Holds the chosen variant, the
/// media assigned to each slot, and the opt-in document-timing preference, then
/// assembles the flow into a dedicated `BrowserViewModel` on launch.
///
/// This is entirely additive: it only ever configures its own browser session
/// and never touches the main Browser tab.
@Observable
@MainActor
final class EyedeekitViewModel {
    /// Eyedeekit-only native document hand-off window when realistic timing is on.
    static let realisticDocHold: ClosedRange<Int> = 1000...2000

    var variant: EyedeekitVariant = .licence {
        didSet { if oldValue != variant { clearAssignments() } }
    }

    /// Front-facing selfie video reused for the silent captures and liveness.
    private(set) var frontSelfieURL: URL?
    /// Captured/loaded document images keyed by their slot.
    private(set) var documentImages: [EyedeekitDocument: UIImage] = [:]

    /// When on, the native document hand-off lands in a realistic ~1–2s window.
    /// Off by default; only affects the eyedeekit browser session.
    var realisticDocTiming: Bool = false

    // MARK: - Assignment

    func assignSelfie(url: URL) {
        frontSelfieURL = url
    }

    func assignDocument(_ image: UIImage, for document: EyedeekitDocument) {
        documentImages[document] = image
    }

    func clearSlot(_ slot: EyedeekitSlot) {
        switch slot {
        case .frontSelfie:
            frontSelfieURL = nil
        case .document(let doc):
            documentImages[doc] = nil
        }
    }

    private func clearAssignments() {
        frontSelfieURL = nil
        documentImages = [:]
    }

    // MARK: - Validation

    func isFilled(_ slot: EyedeekitSlot) -> Bool {
        switch slot {
        case .frontSelfie:
            return frontSelfieURL != nil
        case .document(let doc):
            return documentImages[doc] != nil
        }
    }

    func documentImage(_ document: EyedeekitDocument) -> UIImage? {
        documentImages[document]
    }

    var missingSlots: [EyedeekitSlot] {
        variant.slots.filter { !isFilled($0) }
    }

    var canLaunch: Bool {
        missingSlots.isEmpty
    }

    var filledCount: Int {
        variant.slots.filter { isFilled($0) }.count
    }

    // MARK: - Build

    /// Assembles the ordered flow into the given (dedicated) browser session and
    /// turns media on. Front selfie video is added first so `holdCurrent` always
    /// serves it to the live camera (silent + liveness), while the native
    /// document picker walks the photo steps in order.
    func build(into vm: BrowserViewModel) {
        vm.clearSequence()
        vm.advanceMode = .holdCurrent
        vm.endBehavior = .holdLast
        vm.activeInjectionProfile = .canvasPipeline
        vm.eyedeekitMode = true
        vm.docHoldRange = realisticDocTiming ? Self.realisticDocHold : nil

        if let url = frontSelfieURL, let id = vm.addStep(kind: .video) {
            vm.setStepVideo(url, for: id)
            vm.setStepLiveCamera(.serveLive, for: id)
        }

        for document in variant.documentOrder {
            guard let image = documentImages[document], let id = vm.addStep(kind: .photo) else { continue }
            vm.setStepImage(image, for: id)
        }

        vm.setMediaActive(true)
    }
}
