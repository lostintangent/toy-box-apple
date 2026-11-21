import SwiftUI
import ToyBoxUI

extension View {
    /// Runs `action` with the view's global frame each time the view lays out at a new size, and not
    /// while it only moves. A global frame differs in its size's last digits from one position to
    /// the next as a list scrolls, so the size comes from the view's own layout.
    func onResize(action: @escaping (CGRect) -> Void) -> some View {
        modifier(ResizeChange(action: action))
    }
}

private struct ResizeChange: ViewModifier {
    let action: (CGRect) -> Void
    @ViewState private var size: CGSize?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { CGRect(origin: $0.frame(in: .global).origin, size: $0.size) } action: { frame in
            guard frame.size != size else { return }
            size = frame.size
            action(frame)
        }
    }
}
