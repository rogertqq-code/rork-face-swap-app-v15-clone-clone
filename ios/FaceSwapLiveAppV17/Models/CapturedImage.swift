import UIKit

nonisolated struct CapturedImage: Identifiable {
    let id: UUID = UUID()
    let image: UIImage
}
