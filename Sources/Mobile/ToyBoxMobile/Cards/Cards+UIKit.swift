import SwiftUI
import UIKit

/// UIKit's list reads each row's separators only when it lays out, and nothing lays it out as the
/// talk card starts shrinking, so a changed `listRowSeparator` waits for some unrelated update. This
/// lays the row's list out again whenever its line changes.
struct TalkRowLine: UIViewRepresentable {
    let isHidden: Bool

    final class Coordinator {
        var isHidden: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        defer { context.coordinator.isHidden = isHidden }
        guard let wasHidden = context.coordinator.isHidden, wasHidden != isHidden else { return }
        // After this update, so the list has the row's new separator when it asks.
        Task { @MainActor [weak view] in
            var ancestor = view?.superview
            while let candidate = ancestor, !(candidate is UICollectionView) { ancestor = candidate.superview }
            (ancestor as? UICollectionView)?.collectionViewLayout.invalidateLayout()
        }
    }
}
