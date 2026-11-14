import ToyBoxClient
import ToyBoxKit
import SwiftUI

// What the list cards share: the talk card and the phone's Needs You card draw the same surface,
// hold the list and place themselves above it the same way, and end in the same Cancel and Send.

/// The cards' sizes. The Mac draws them at its sidebar's scale, around its 30-point avatar, where
/// the card takes the row highlight's corners.
package enum CardMetrics {
    #if os(macOS)
    package static let mark: CGFloat = 30
    package static let control: CGFloat = 28
    package static let controlGap: CGFloat = 8
    package static let hitTarget: CGFloat = 28
    package static let cornerRadius: CGFloat = 10
    #else
    package static let mark: CGFloat = 28
    package static let control: CGFloat = 32
    package static let controlGap: CGFloat = 12
    package static let hitTarget: CGFloat = 44
    package static let cornerRadius: CGFloat = 20
    #endif
    /// The done check's solid square is 2 points smaller, since a bright square reads larger than
    /// the avatar beside it.
    package static var check: CGFloat { mark - 2 }
}

/// A card's surface: 20-point continuous corners over an opaque base, washed in a transcript
/// surface's fills, with a thin edge and, while lifted, a shadow. Each layer fades in its own
/// animation, so the surface's size always moves with its card's own transaction.
package struct CardSurface: View {
    package nonisolated static var cornerRadius: CGFloat { CardMetrics.cornerRadius }

    package struct Animations {
        var base: Animation?
        var wash: Animation?
        var edge: Animation?
        var shadow: Animation?

        package init(base: Animation? = nil, wash: Animation? = nil, edge: Animation? = nil, shadow: Animation? = nil) {
            self.base = base
            self.wash = wash
            self.edge = edge
            self.shadow = shadow
        }
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

    package init(surface: TranscriptSurface, tint: Color, base: Bool = false, wash: Bool = true, edge: Bool = true,
                 shadow: Bool = false, animations: Animations = Animations()) {
        self.surface = surface
        self.tint = tint
        self.base = base
        self.wash = wash
        self.edge = edge
        self.shadow = shadow
        self.animations = animations
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        ZStack {
            shape.fill(Self.canvas)
                .animation(animations.base) { $0.opacity(base ? 1 : 0) }
            ZStack {
                ForEach(Array(surface.fills(isDark: isDark, canvasIsBlack: Self.canvasIsBlack).enumerated()), id: \.offset) {
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

    /// The conversation's own canvas, so a card's fills match the person's bubbles beside it.
    private static var canvas: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private static var canvasIsBlack: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

extension View {
    /// Wears `glyph` in place of this channel avatar, at `CardMetrics.mark`. See `CardMark`.
    package func cardMark(_ glyph: CardMark.Glyph) -> some View {
        modifier(CardMark(glyph: glyph))
    }
}

/// The mark a card's row wears: the channel's own avatar, the mic while the talk card records, or
/// the done check once a card's message sends. They share the avatar's rounded square, so the mark
/// keeps one shape as the avatar fades and the symbol grows in from half its size, and the way back
/// runs in reverse. Between the mic and the check, the symbol swaps through `.replace` as the
/// tile's tint turns green, and the check arrives with the success tap. The check's solid square
/// is 2 points smaller, since a bright square reads larger than the avatar beside it.
package struct CardMark: ViewModifier {
    package enum Glyph { case channel, mic, check }

    /// The avatar's corners, as a fraction of its side.
    package static let corners = 0.26

    let glyph: Glyph
    /// The symbol the mark last wore, which it fades out on its way back to the avatar.
    @ViewState private var face: Glyph
    /// Whether the mark wore the avatar until now, so a symbol arrives already the new one.
    @ViewState private var fromAvatar: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cardMarkTaps) private var taps
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(glyph: Glyph) {
        self.glyph = glyph
        _face = .init(initialValue: glyph == .channel ? .check : glyph)
        _fromAvatar = .init(initialValue: glyph == .channel)
    }

    package func body(content: Content) -> some View {
        let shown = glyph == .channel ? face : glyph
        let side = shown == .check ? CardMetrics.check : CardMetrics.mark
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
        .frame(width: CardMetrics.mark, height: CardMetrics.mark)
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
            // A concrete style keeps the Mac sidebar's vibrancy from filling the cutout back in.
            Image(systemName: name).foregroundStyle(.black).blendMode(.destinationOut)
            Image(systemName: name)
                .foregroundStyle(Color.accentColor)
                .opacity(glyph == .mic ? 1 : 0)
        }
        .font(.system(size: glyph == .check ? 15 * CardMetrics.check / 28 : CardMetrics.mark * 14 / 30, weight: .semibold))
    }
}

/// The avatar's continuous rounded square at any side, so a mark's corners scale with it.
package struct CardMarkShape: Shape {
    package init() {}

    package func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: rect.width * CardMark.corners, style: .continuous).path(in: rect)
    }
}

private struct CardMarkTapsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a mark's check arrives with the success tap. A copy of a row the list also draws
    /// leaves the tap to the list's own.
    package var cardMarkTaps: Bool {
        get { self[CardMarkTapsKey.self] }
        set { self[CardMarkTapsKey.self] = newValue }
    }
}

/// The card's corners, extended past its trailing edge by `overflow`, which moves with its view's
/// animation unless `animatesOverflow` is false.
package struct CardShape: Shape {
    var overflow: CGFloat = 0
    var animatesOverflow = true

    package init(overflow: CGFloat = 0, animatesOverflow: Bool = true) {
        self.overflow = overflow
        self.animatesOverflow = animatesOverflow
    }

    package var animatableData: CGFloat {
        get { animatesOverflow ? overflow : 0 }
        set { if animatesOverflow { overflow = newValue } }
    }

    package func path(in rect: CGRect) -> Path {
        var rect = rect
        rect.size.width += overflow
        return RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous).path(in: rect)
    }
}

/// Places a card on its row, or, while lifted, above the list from its own laid-out height, so its
/// top edge moves in the same transaction as its size, and a card growing up holds its bottom still.
package struct CardLayout: Layout {
    let placement: CardPlacement
    let x: CGFloat
    let isLifted: Bool

    package init(placement: CardPlacement, x: CGFloat, isLifted: Bool) {
        self.placement = placement
        self.x = x
        self.isLifted = isLifted
    }

    package func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    package func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
    /// the app leaves the foreground or the card's channel leaves `targets`. On the Mac, the window
    /// resigning key or a click on the dimmed list ends it too.
    package func cardList<Card: View>(isLifted: Bool, target: ChannelTarget?, targets: [ChannelTarget],
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
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isLifted)
            .accessibilityHidden(isLifted)
            .overlay {
                // Inside the safe area and any bar, and above the keyboard while it shows.
                GeometryReader { proxy in
                    // The dimmed rows ignore taps, so the open channel's row keeps its selection.
                    if isLifted {
                        #if os(macOS)
                        Color.clear.contentShape(Rectangle()).onTapGesture { end() }
                        #else
                        Color.clear.contentShape(Rectangle())
                        #endif
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
            #if os(macOS)
            .onChange(of: appearsActive) { _, active in
                if !active { end() }
            }
            #endif
    }
}

/// A lifted card's Cancel and Send, which the Mac sends with Return.
package struct CardControls: View {
    let canCancel: Bool
    let canSend: Bool
    /// Keeps Send lit for the moment its message is saved, so the circle never flickers gray.
    let isSending: Bool
    let sendLabel: String
    let cancel: () -> Void
    let send: () -> Void

    package init(canCancel: Bool, canSend: Bool, isSending: Bool, sendLabel: String,
                 cancel: @escaping () -> Void, send: @escaping () -> Void) {
        self.canCancel = canCancel
        self.canSend = canSend
        self.isSending = isSending
        self.sendLabel = sendLabel
        self.cancel = cancel
        self.send = send
    }

    package var body: some View {
        // The circles keep their gap however far their hit targets reach past them.
        HStack(spacing: CardMetrics.controlGap - (CardMetrics.hitTarget - CardMetrics.control)) {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: CardMetrics.control * 14 / 32, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: CardMetrics.control, height: CardMetrics.control)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .frame(width: CardMetrics.hitTarget, height: CardMetrics.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCancel)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
            Button(action: send) { sendFace }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(Self.sendShortcut)
                .accessibilityLabel(sendLabel)
        }
    }

    private static var sendShortcut: KeyboardShortcut {
        #if os(macOS)
        .defaultAction
        #else
        KeyboardShortcut(.return, modifiers: .command)
        #endif
    }

    private var sendFace: some View {
        let active = canSend || isSending
        return Image(systemName: "arrow.up")
            .font(.system(size: CardMetrics.control * 17 / 32, weight: .medium))
            .frame(width: CardMetrics.control, height: CardMetrics.control)
            .background(active ? Color.accentColor : Self.unavailable, in: Circle())
            .foregroundStyle(active ? .white : .secondary)
            .frame(width: CardMetrics.hitTarget, height: CardMetrics.hitTarget)
            .contentShape(Rectangle())
    }

    private static var unavailable: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color(uiColor: .quaternaryLabel)
        #endif
    }
}

extension CardChecks {
    /// The list's done checks, which play both cards' beats with the spec's springs.
    package convenience init() {
        self.init(animate: { withAnimation($0.animation, $1) })
    }
}

extension CardMotion {
    /// The beat's spring from the spec, or a short ease without bounce under Reduce Motion.
    @MainActor package var animation: Animation {
        #if os(macOS)
        animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        #else
        animation(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        #endif
    }

    /// The beat's spring from the spec, or a short ease without bounce under Reduce Motion.
    package func animation(reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return switch self {
        case .open: .spring(duration: 0.4, bounce: 0.12)
        case .sent: .smooth(duration: 0.35)
        case .settle: .easeOut(duration: 0.4)
        }
    }
}
