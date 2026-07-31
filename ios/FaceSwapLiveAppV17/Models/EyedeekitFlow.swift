import Foundation

/// The eyedeekit ID-verification variants. Each describes the ordered logical
/// stages the verification site runs and the distinct media slots the user
/// must fill before launching. Pure value data — no app state.
nonisolated enum EyedeekitVariant: String, CaseIterable, Identifiable, Sendable {
    case licence
    case passport

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .licence: "Driver's Licence"
        case .passport: "Passport"
        }
    }

    nonisolated var flowSummary: String {
        switch self {
        case .licence: "Silent · Front · Silent · Back · Liveness"
        case .passport: "Silent · Photo page · Liveness"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .licence: "creditcard.fill"
        case .passport: "book.closed.fill"
        }
    }

    /// The ordered logical stages, shown so the user understands the real flow.
    nonisolated var stages: [EyedeekitStage] {
        switch self {
        case .licence:
            [.silent(1), .document(.licenceFront), .silent(2), .document(.licenceBack), .liveness]
        case .passport:
            [.silent(1), .document(.passportPhoto), .liveness]
        }
    }

    /// The distinct media slots the user fills. All front stages (silent +
    /// liveness) share a single selfie clip, so there is only one front slot.
    nonisolated var slots: [EyedeekitSlot] {
        var result: [EyedeekitSlot] = [.frontSelfie]
        result.append(contentsOf: documentOrder.map { EyedeekitSlot.document($0) })
        return result
    }

    /// Document capture order the native picker walks through.
    nonisolated var documentOrder: [EyedeekitDocument] {
        switch self {
        case .licence: [.licenceFront, .licenceBack]
        case .passport: [.passportPhoto]
        }
    }
}

/// A single document image the flow captures via the native camera.
nonisolated enum EyedeekitDocument: String, Sendable, Identifiable, Equatable, CaseIterable {
    case licenceFront
    case licenceBack
    case passportPhoto

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .licenceFront: "Licence — Front"
        case .licenceBack: "Licence — Back"
        case .passportPhoto: "Passport — Photo Page"
        }
    }
}

/// One ordered stage of the flow, used purely for the read-only flow preview.
nonisolated enum EyedeekitStage: Sendable, Identifiable, Equatable {
    case silent(Int)
    case document(EyedeekitDocument)
    case liveness

    nonisolated var id: String {
        switch self {
        case .silent(let n): "silent-\(n)"
        case .document(let doc): "doc-\(doc.rawValue)"
        case .liveness: "liveness"
        }
    }

    nonisolated var title: String {
        switch self {
        case .silent: "Silent Capture"
        case .document(let doc): doc.title
        case .liveness: "Liveness"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .silent: "Front camera — the site quietly grabs selfie frames (~1s)."
        case .document: "Your phone's native camera launches to shoot the ID."
        case .liveness: "Front camera — live face compared to the ID and the silent frames."
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .silent: "eye.slash.fill"
        case .document: "doc.viewfinder.fill"
        case .liveness: "face.smiling.fill"
        }
    }

    nonisolated var usesFrontCamera: Bool {
        switch self {
        case .silent, .liveness: true
        case .document: false
        }
    }
}

/// A media slot the user fills. The front selfie is a video (served to the live
/// camera for the silent captures and liveness); documents are photos (served
/// to the native document picker in order).
nonisolated enum EyedeekitSlot: Sendable, Identifiable, Equatable {
    case frontSelfie
    case document(EyedeekitDocument)

    nonisolated var id: String {
        switch self {
        case .frontSelfie: "frontSelfie"
        case .document(let doc): "doc-\(doc.rawValue)"
        }
    }

    nonisolated var isVideo: Bool {
        switch self {
        case .frontSelfie: true
        case .document: false
        }
    }

    nonisolated var title: String {
        switch self {
        case .frontSelfie: "Selfie Clip"
        case .document(let doc): doc.title
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .frontSelfie: "Front-facing video reused for the silent captures and the final liveness check."
        case .document: "Photo of the ID document, fed to the native camera."
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .frontSelfie: "person.crop.square.badge.video.fill"
        case .document: "doc.text.image.fill"
        }
    }
}
