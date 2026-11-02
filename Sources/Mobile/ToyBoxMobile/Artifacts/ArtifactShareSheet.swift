import SwiftUI
import UIKit

struct ArtifactShare: Identifiable {
    let file: URL
    var id: URL { file }
}

struct ArtifactShareSheet: UIViewControllerRepresentable {
    let file: URL
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error { onError(error.localizedDescription) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
