import SwiftUI
import ToyBoxUI

extension View {
    /// Runs `action` with the view's frame in `space` each time the view lays out at a new size, and
    /// not while it only moves. A frame in a space the view moves through, like global space as a
    /// list scrolls, differs in its size's last digits from one position to the next, so the size
    /// comes from the view's own layout.
    func onResize(in space: some CoordinateSpaceProtocol, action: @escaping (CGRect) -> Void) -> some View {
        modifier(ResizeChange(space: space, action: action))
    }
}

private struct ResizeChange<Space: CoordinateSpaceProtocol>: ViewModifier {
    let space: Space
    let action: (CGRect) -> Void
    @ViewState private var size: CGSize?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { CGRect(origin: $0.frame(in: space).origin, size: $0.size) } action: { frame in
            guard frame.size != size else { return }
            size = frame.size
            action(frame)
        }
    }
}
