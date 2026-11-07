import ChannelClient
import SwiftUI
import ToyBoxUI
import UIKit

// What the phone's list cards share: the talk card and the Needs You card draw the same surface,
// place themselves the same way above the list, and end in the same Cancel and Send.

/// A card's surface: 20-point continuous corners over an opaque base, washed in a transcript
/// surface's fills, with a thin edge and, while lifted, a shadow. Each layer fades in its own
/// animation, so the surface's size always moves with its card's own transaction.
struct CardSurface: View {
    nonisolated static let cornerRadius: CGFloat = 20

    struct Animations {
        var base: Animation?
        var wash: Animation?
        var edge: Animation?
        var shadow: Animation?
    }

    let surface: TranscriptSurface
    /// The edge's color, drawn at 30 percent.
    let tint: Color
    /// The list's own background, so the dimmed rows never show through.
    var base = false
    var wash = true
    var edge = true
    var shadow = false
    var animations = Animations()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        ZStack {
            shape.fill(Color(uiColor: .systemBackground))
                .animation(animations.base) { $0.opacity(base ? 1 : 0) }
            ZStack {
                ForEach(Array(surface.fills(isDark: isDark, canvasIsBlack: true).enumerated()), id: \.offset) {
                    shape.fill($0.element)
                }
            }
            .animation(animations.wash) { $0.opacity(wash ? 1 : 0) }
        }
        .animation(animations.shadow) { $0.shadow(color: .black.opacity(shadow ? (isDark ? 0.3 : 0.12) : 0), radius: 24, y: 8) }
        .overlay {
            Group {
                if contrast == .increased, let edge = surface.increasedContrastEdge {
                    shape.strokeBorder(edge, lineWidth: 1)
                } else {
                    shape.strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
                }
            }
            .animation(animations.edge) { $0.opacity(edge ? 1 : 0) }
        }
    }
}

/// The card's corners, extended past its trailing edge by `overflow`.
struct CardShape: Shape {
    var overflow: CGFloat = 0

    var animatableData: CGFloat {
        get { overflow }
        set { overflow = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var rect = rect
        rect.size.width += overflow
        return RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous).path(in: rect)
    }
}

/// Places a card above the list from its own laid-out height, so its top edge moves in the same
/// transaction as its size, and a card growing up holds its bottom still.
struct CardLayout: Layout {
    let placement: TalkRecorder.Placement
    let x: CGFloat
    let isOpen: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for card in subviews {
            let top = isOpen ? placement.top(height: card.sizeThatFits(.unspecified).height) : placement.row.minY
            card.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + top), proposal: .unspecified)
        }
    }
}

/// A lifted card's Cancel and Send, with Send's progress, or its retry after a failure.
struct CardControls: View {
    let canCancel: Bool
    let canSend: Bool
    let isSending: Bool
    let showsProgress: Bool
    let isFailed: Bool
    /// Send's accessibility label before any failure.
    let sendLabel: String
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCancel)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
            Button(action: send) { sendFace }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(isFailed ? "Send Again" : sendLabel)
        }
    }

    private var sendFace: some View {
        let active = canSend || isSending
        return Group {
            if showsProgress {
                ProgressView().frame(width: 32, height: 32)
            } else {
                Image(systemName: isFailed ? "arrow.clockwise" : "arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(active ? Color.accentColor : Color(uiColor: .quaternaryLabel), in: Circle())
                    .foregroundStyle(active ? .white : .secondary)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}
