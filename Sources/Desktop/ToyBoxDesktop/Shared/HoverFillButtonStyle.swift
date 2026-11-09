import SwiftUI
import ToyBoxUI

/// The Mac's one hover fill, for every custom control and row that answers the pointer: primary at
/// 12% in Dark and 8% in Light, 5% more while pressed, in the control's own shape, or white at 20%
/// on an accent selection. It fades over 120 ms, even with Reduce Motion, since it moves nothing.
/// While lit, a borderless control's secondary ink turns primary. The whole shape takes clicks.
struct HoverFillButtonStyle<Fill: Shape>: ButtonStyle {
    enum Lighting {
        /// The pointer over the control lights it.
        case hover
        /// A highlight the pointer and the keyboard share lights it, rather than the control's own hover.
        case highlight(Bool)
        /// Nothing lights it, as while the control shows a state of its own.
        case off
    }

    let shape: Fill
    var lighting = Lighting.hover
    /// Inks the label secondary at rest and primary while lit. Rows that ink their own text turn it off.
    var inks = true

    func makeBody(configuration: Configuration) -> some View {
        HoverFillButton(configuration: configuration, shape: shape, lighting: lighting, inks: inks)
    }
}

private struct HoverFillButton<Fill: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: Fill
    let lighting: HoverFillButtonStyle<Fill>.Lighting
    let inks: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.windowSnapshot) private var snapshot
    @ViewState private var isHovered = false

    var body: some View {
        let isLit = self.isLit
        configuration.label
            .animation(.easeOut(duration: 0.12)) { label in
                label
                    .modifier(HoverInk(isLit: isLit, isEnabled: isEnabled, inks: inks))
                    .background { shape.fill(fill).opacity(isLit ? 1 : 0) }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    private var isLit: Bool {
        guard isEnabled else { return false }
        switch lighting {
        case .hover: return isHovered || configuration.isPressed || snapshot?.requestedState == "hover-all"
        case .highlight(let highlighted): return highlighted || configuration.isPressed
        case .off: return false
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed ? 0.05 : 0
        if prominence == .increased { return .white.opacity(0.2 + pressed) }
        return .primary.opacity((colorScheme == .dark ? 0.12 : 0.08) + pressed)
    }
}

private struct HoverInk: ViewModifier {
    let isLit: Bool
    let isEnabled: Bool
    let inks: Bool

    func body(content: Content) -> some View {
        if inks {
            content.foregroundStyle(isLit ? .primary : isEnabled ? .secondary : .tertiary)
        } else {
            content
        }
    }
}
