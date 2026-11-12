import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

// What the phone's list cards share: the talk card and the Needs You card draw the same surface,
// hold the list and place themselves above it the same way, and end in the same Cancel and Send.

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

extension View {
    /// Wears `glyph` in place of this 28-point channel avatar. See `CardMark`.
    func cardMark(_ glyph: CardMark.Glyph) -> some View {
        modifier(CardMark(glyph: glyph))
    }
}

/// The mark a card's row wears: the channel's own avatar, the mic while the talk card records, or
/// the done check once a card's message sends. They share the avatar's rounded square, so the mark
/// keeps one shape as the avatar fades and the symbol grows in from half its size, and the way back
/// runs in reverse. Between the mic and the check, the symbol swaps through `.replace` as the
/// tile's tint turns green, and the check arrives with the success tap. The check's solid square
/// is 2 points smaller, since a bright square reads larger than the avatar beside it.
struct CardMark: ViewModifier {
    enum Glyph { case channel, mic, check }

    /// The avatar's corners, as a fraction of its side.
    static let corners = 0.26

    let glyph: Glyph
    /// The symbol the mark last wore, which it fades out on its way back to the avatar.
    @ViewState private var face: Glyph
    /// Whether the mark wore the avatar until now, so a symbol arrives already the new one.
    @ViewState private var fromAvatar: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cardMarkTaps) private var taps
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(glyph: Glyph) {
        self.glyph = glyph
        _face = .init(initialValue: glyph == .channel ? .check : glyph)
        _fromAvatar = .init(initialValue: glyph == .channel)
    }

    func body(content: Content) -> some View {
        let shown = glyph == .channel ? face : glyph
        let side: CGFloat = shown == .check ? 26 : 28
        ZStack {
            content
                .clipShape(CardMarkShape())
                .opacity(glyph == .channel ? 1 : 0)
            ZStack {
                CardMarkShape()
                    .fill(shown == .check ? ChannelTaskColors.changes(in: colorScheme).added : .accentColor.opacity(0.15))
                symbol(shown)
                    .contentTransition(fromAvatar ? .identity : .symbolEffect(.replace))
                    .scaleEffect(glyph == .channel && !reduceMotion ? 0.5 : 1)
                    // The row's accessibility value already says what the note is doing.
                    .accessibilityHidden(true)
            }
            .frame(width: side, height: side)
            // Lets the check knock out only its own square.
            .compositingGroup()
            .opacity(glyph == .channel ? 0 : 1)
        }
        .frame(width: 28, height: 28)
        .onChange(of: glyph) { _, glyph in
            if glyph != .channel { face = glyph }
            fromAvatar = glyph == .channel
        }
        .sensoryFeedback(.success, trigger: glyph == .check) { _, sent in sent && taps }
    }

    private func symbol(_ glyph: Glyph) -> some View {
        let name = glyph == .check ? "checkmark" : "mic.fill"
        // Both layers swap together. The first cuts the symbol out of the tile, and the second
        // fills it back in with the mic's accent, or leaves the check cut out.
        return ZStack {
            Image(systemName: name).blendMode(.destinationOut)
            Image(systemName: name)
                .foregroundStyle(Color.accentColor)
                .opacity(glyph == .mic ? 1 : 0)
        }
        .font(.system(size: glyph == .check ? 15 * 26 / 28 : 28 * 14 / 30, weight: .semibold))
    }
}

/// The avatar's continuous rounded square at any side, so a mark's corners scale with it.
struct CardMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: rect.width * CardMark.corners, style: .continuous).path(in: rect)
    }
}

private struct CardMarkTapsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a mark's check arrives with the success tap. A copy of a row the list also draws
    /// leaves the tap to the list's own.
    var cardMarkTaps: Bool {
        get { self[CardMarkTapsKey.self] }
        set { self[CardMarkTapsKey.self] = newValue }
    }
}

/// The card's corners, extended past its trailing edge by `overflow`, which moves with its view's
/// animation unless `animatesOverflow` is false.
struct CardShape: Shape {
    var overflow: CGFloat = 0
    var animatesOverflow = true

    var animatableData: CGFloat {
        get { animatesOverflow ? overflow : 0 }
        set { if animatesOverflow { overflow = newValue } }
    }

    func path(in rect: CGRect) -> Path {
        var rect = rect
        rect.size.width += overflow
        return RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous).path(in: rect)
    }
}

/// Places a card on its row, or, while lifted, above the list from its own laid-out height, so its
/// top edge moves in the same transaction as its size, and a card growing up holds its bottom still.
struct CardLayout: Layout {
    let placement: CardPlacement
    let x: CGFloat
    let isLifted: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for card in subviews {
            let top = isLifted ? placement.top(height: card.sizeThatFits(.unspecified).height) : placement.row.minY
            card.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + top), proposal: .unspecified)
        }
    }
}

extension View {
    /// Holds the list under its card. While the card is lifted, the list stops scrolling, leaves
    /// VoiceOver to the card and lets its dimmed rows ignore taps. `card` draws over the list from the
    /// list's frame in global space. The card ends through `end` when anything in `context` changes,
    /// the app leaves the foreground or the card's channel leaves `targets`.
    func cardList<Card: View>(isLifted: Bool, target: ChannelTarget?, targets: [ChannelTarget],
                              endsWhenChanging context: [AnyHashable?], end: @escaping @MainActor () -> Void,
                              @ViewBuilder card: @escaping (_ list: CGRect) -> Card) -> some View {
        modifier(CardList(isLifted: isLifted, target: target, targets: targets, context: context,
                          end: end, card: card))
    }
}

private struct CardList<Card: View>: ViewModifier {
    let isLifted: Bool
    let target: ChannelTarget?
    let targets: [ChannelTarget]
    let context: [AnyHashable?]
    let end: @MainActor () -> Void
    let card: (CGRect) -> Card
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isLifted)
            .accessibilityHidden(isLifted)
            .overlay {
                // Inside the safe area and any bar, and above the keyboard while it shows.
                GeometryReader { proxy in
                    // The dimmed rows ignore taps, so the open channel's row keeps its selection.
                    if isLifted {
                        Color.clear.contentShape(Rectangle())
                    }
                    card(proxy.frame(in: .global))
                }
            }
            .onChange(of: context) { end() }
            .onChange(of: target.map { !targets.contains($0) } ?? false) { _, isGone in
                if isGone { end() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { end() }
            }
    }
}

/// A lifted card's Cancel and Send.
struct CardControls: View {
    let canCancel: Bool
    let canSend: Bool
    /// Keeps Send lit for the moment its message is saved, so the circle never flickers gray.
    let isSending: Bool
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
                .accessibilityLabel(sendLabel)
        }
    }

    private var sendFace: some View {
        let active = canSend || isSending
        return Image(systemName: "arrow.up")
            .font(.system(size: 17, weight: .medium))
            .frame(width: 32, height: 32)
            .background(active ? Color.accentColor : Color(uiColor: .quaternaryLabel), in: Circle())
            .foregroundStyle(active ? .white : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

extension CardMotion {
    /// The beat's spring from the spec, or a short ease without bounce under Reduce Motion.
    @MainActor var animation: Animation {
        if UIAccessibility.isReduceMotionEnabled { return .easeInOut(duration: 0.2) }
        return switch self {
        case .open: .spring(duration: 0.4, bounce: 0.12)
        case .sent: .smooth(duration: 0.35)
        case .settle: .easeOut(duration: 0.4)
        }
    }
}

extension CardChecks {
    /// The list's done checks, settling with the spec's springs.
    convenience init() {
        self.init(animate: { withAnimation($0.animation, $1) })
    }
}
