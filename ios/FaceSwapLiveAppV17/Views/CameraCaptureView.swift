import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
    enum Source: Sendable, Equatable {
        case camera
        case photoLibrary
    }

    let source: Source
    let onSelected: (UIImage, Source) -> Void
    let onCancel: () -> Void

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.mediaTypes = ["public.image"]
        picker.sourceType = resolvedSourceType
        if picker.sourceType == .camera {
            picker.cameraCaptureMode = .photo
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    private var resolvedSourceType: UIImagePickerController.SourceType {
        switch source {
        case .camera where Self.isCameraAvailable:
            .camera
        case .camera, .photoLibrary:
            .photoLibrary
        }
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            let resolvedSource: Source = picker.sourceType == .camera ? .camera : .photoLibrary
            parent.onSelected(image, resolvedSource)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
