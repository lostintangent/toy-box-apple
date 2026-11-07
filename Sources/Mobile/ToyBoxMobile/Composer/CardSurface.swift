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

/// The mark a card's row wears: the channel's own face, the mic while the talk card records, or the
/// done check once a card's message sends. Each face keeps its own fill, so a change cross-fades,
/// the glyph swaps through `.replace`, and the check arrives with the success tap.
struct CardMark: View {
    enum Face { case channel, mic, check }

    let face: Face
    var emphasized = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: symbol)
            // At this size the check's circle fills the mark's 28 points, with its check knocked out.
            .font(.system(size: face == .check ? 27.4 : 28 * 14 / 30, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(ink)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 28, height: 28)
            .background {
                // The check brings its own circle.
                ZStack {
                    Circle()
                        .fill(emphasized ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(ChannelMark.cyan.gradient))
                        .opacity(face == .channel ? 1 : 0)
                    Circle().fill(Color.accentColor.opacity(0.15)).opacity(face == .mic ? 1 : 0)
                }
            }
            .sensoryFeedback(.success, trigger: face == .check) { _, sent in sent }
    }

    private var symbol: String {
        switch face {
        case .mic: "mic.fill"
        case .check: "checkmark.circle.fill"
        case .channel: "number"
        }
    }

    private var ink: Color {
        switch face {
        case .mic: .accentColor
        case .check: ChannelTaskColors.changes(in: colorScheme).added
        case .channel: .white
        }
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

/// Places a card above the list from its own laid-out height, so its top edge moves in the same
/// transaction as its size, and a card growing up holds its bottom still.
struct CardLayout: Layout {
    let placement: CardPlacement
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
    /// When the card's attempt began posting.
    let postingSince: ContinuousClock.Instant?
    let isFailed: Bool
    /// Send's accessibility label before any failure.
    let sendLabel: String
    let cancel: () -> Void
    let send: () -> Void
    @ViewState private var showsProgress = false

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
        .cardProgress(since: postingSince, $showsProgress)
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

extension View {
    /// Sets `showsProgress` once a card's attempt that began posting at `since` has gone 300 ms
    /// without confirming, as `DelayedProgressView` waits, for a place that swaps its content for
    /// the progress.
    func cardProgress(since: ContinuousClock.Instant?, _ showsProgress: Binding<Bool>) -> some View {
        task(id: since) {
            showsProgress.wrappedValue = false
            guard let since else { return }
            let remaining = DelayedProgressView.delay - since.duration(to: .now)
            if remaining > .zero {
                do { try await Task.sleep(for: remaining) } catch { return }
            }
            showsProgress.wrappedValue = true
        }
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
