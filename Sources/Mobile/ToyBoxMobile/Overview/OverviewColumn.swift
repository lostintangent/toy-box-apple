import SwiftUI
import UIKit

/// Overview's landscape column, in its own hosting controller so its navigation stays inside the column.
/// SwiftUI stretches a NavigationStack over the safe area it touches, so in the window's tree the column's
/// stack would cover the channel's vertical bar and put a pushed page's Back there.
/// A new hosting root starts its own environment, so the caller passes in what the column reads.
struct OverviewColumn<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        // Elevated like the sheet, so every page's system background matches it.
        controller.traitOverrides.userInterfaceLevel = .elevated
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
    }
}

/// The column's elevated background, which carries it under the channel's vertical bar to the screen's
/// edge.
struct OverviewColumnBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.traitOverrides.userInterfaceLevel = .elevated
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
