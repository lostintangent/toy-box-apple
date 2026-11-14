import ChannelClient
import ChannelKit
import SwiftUI

// The recorder is a card over the list. It opens on the held row's cell and draws the row's own
// content in the same places, so its mark, time and second line swap in their own slots, then it
// grows over the dimmed rows. As it lands, it hands back to the list's own row, which carries the
// check, the note's time and the card's fill in its own ink. The cell itself never changes height.
// Both apps share it, the Mac at its own sizes. See Talk to the Lead in docs/spec.md.

extension View {
    /// The row's mark, which becomes the recorder's mic and then the done check.
    package func talkMark(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkSlot(kind: .mark, recorder: recorder))
    }

    /// The row's last-activity time, which becomes the counter on the same baseline and trailing
    /// edge, and marks where the row's text ends.
    package func talkTime(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkSlot(kind: .time, recorder: recorder))
    }

    /// The row's trailing column, the chevron and attention mark, which leaves its space empty
    /// until the card lands.
    package func talkFades(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkSlot(kind: .trailing, recorder: recorder))
    }

    /// The row's second line, which gives way to the waveform while the card is lifted.
    package func talkLine(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkSlot(kind: .line, recorder: recorder))
    }

    /// The row's accessibility value, its `details`, which the note's state replaces while the
    /// recorder is on the row.
    package func talkValue(_ recorder: TalkRecorder?, details: String) -> some View {
        accessibilityValue(recorder?.rowValue(details: details) ?? details)
    }

    /// Offers Talk on a channel row when `offered`, and dims the row while another row records.
    /// The row shows its bottom `line` whenever the recorder doesn't hide it.
    package func talkRow(_ target: ChannelTarget, recorder: TalkRecorder, offered: Bool = true, line: Visibility = .automatic,
                 start: @escaping () -> Void) -> some View {
        modifier(TalkRow(target: target, recorder: recorder, offered: offered, line: line, start: start))
    }

    /// Floats the recorder over the list from the held row, drawn by `row`. Holds the list while the
    /// card is lifted, and ends the note as a draft when anything in `context` changes, such as
    /// opening a channel, Search or Settings, or when the held channel leaves `targets`. Pass
    /// `onGlass` for the unfolded Liquid Glass sidebar, which no opaque base can match.
    package func talkList<Row: View>(_ recorder: TalkRecorder, targets: [ChannelTarget], onGlass: Bool = false,
                             endsWhenChanging context: [AnyHashable?],
                             @ViewBuilder row: @escaping (ChannelTarget) -> Row) -> some View {
        modifier(TalkList(recorder: recorder, targets: targets, onGlass: onGlass, context: context, row: row))
    }
}

private struct TalkGrownKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TalkTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// True once the card has grown from the row, so the card's first frame draws the ordinary row.
    /// The list's own row follows from Send, so it already wears the card's check and time when the
    /// card hands it back.
    fileprivate var talkGrown: Bool {
        get { self[TalkGrownKey.self] }
        set { self[TalkGrownKey.self] = newValue }
    }

    /// How far before line 2's trailing edge the card's content ends.
    fileprivate var talkTrailingInset: CGFloat {
        get { self[TalkTrailingInsetKey.self] }
        set { self[TalkTrailingInsetKey.self] = newValue }
    }
}

/// Where the row's text ends, the time's trailing edge or nil when the time leads its own line, and
/// where its second line ends.
private struct TalkEndsKey: PreferenceKey {
    struct Ends {
        var text: Anchor<CGPoint>?
        var line: Anchor<CGPoint>?
    }

    static let defaultValue = Ends()
    static func reduce(value: inout Ends, nextValue: () -> Ends) {
        let next = nextValue()
        value = Ends(text: value.text ?? next.text, line: value.line ?? next.line)
    }
}

/// The held row as the list lays it out, which the card opens on and returns to. The list keeps it
/// while the recorder holds a row, and the row reports where it sits. It's keyed by channel, so
/// talking again on a row that still wears the check keeps its card, and the check swaps straight
/// to the mic.
@MainActor @Observable private final class TalkHold {
    /// The held row's frame in the window, and how far before its trailing edge the row's text
    /// ends, which is the time's trailing edge unless the time leads its own line, and its second
    /// line ends.
    struct Cell: Equatable {
        #if os(macOS)
        /// The Mac's card takes the row highlight's frame, which sits 6 points outside the row, and
        /// its content ends on the time's trailing edge.
        static let cardLeading: CGFloat = 6
        static let cardMargin: CGFloat = 14
        #else
        /// The card's sides sit this far outside the row's text.
        static let cardLeading: CGFloat = 12
        static let cardMargin: CGFloat = 12
        #endif

        var target: ChannelTarget
        var frame: CGRect
        var textInset: CGFloat
        var lineInset: CGFloat
    }

    var cell: Cell?
    /// The row whose card has grown. The card's growth, every slot's swap and the list's dim follow
    /// it, so they run in the card's own spring, since the swipe action's transaction doesn't animate.
    var grown: ChannelTarget?

    func isGrown(_ target: ChannelTarget?) -> Bool { target != nil && grown == target }

    /// Lets go of the row once the recorder does, so the next note grows afresh.
    func release() {
        cell = nil
        grown = nil
    }
}

/// The recorder: a card over the list that opens on the held row's cell, draws the row's own
/// content in the same places, then grows over the dimmed rows to reveal the note below the row's
/// first two lines, its words, any notice and the controls.
private struct TalkCard<Row: View>: View {
    let recorder: TalkRecorder
    let hold: TalkHold
    /// The held row's content, in the card's space.
    let cell: CGRect
    /// How far before the cell's trailing edge the row's text ends.
    let textInset: CGFloat
    /// How far before the cell's trailing edge the row's second line ends.
    let lineInset: CGFloat
    /// The list's visible area, inside the safe area and any bottom bar.
    let bounds: CGRect
    let onGlass: Bool
    @ViewBuilder let row: Row
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @AccessibilityFocusState private var wordsFocused: Bool
    /// The note's height besides its words, once it has measured, which tells the card its room
    /// for five lines.
    @ViewState private var chrome: CGFloat?
    /// The words' height as laid out, which runs past what they show once they pass the limit.
    @ViewState private var wordsHeight: CGFloat?
    /// The height of five lines of the words' own text, as laid out.
    @ViewState private var fiveLines: CGFloat?
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    /// The room the card keeps from the visible area's ends.
    private static var inset: CGFloat { 8 }

    /// Where the channel's name starts in its row.
    #if os(macOS)
    private static var nameInset: CGFloat { 48 }
    #else
    private static var nameInset: CGFloat { 40 }
    #endif

    var body: some View {
        let grown = hold.isGrown(recorder.target)
        let lifted = grown && recorder.isLifted
        let landed = recorder.phase == .landed
        let margin = TalkHold.Cell.cardMargin
        let room = bounds.insetBy(dx: 0, dy: Self.inset)
        let left = max(bounds.minX, cell.minX - TalkHold.Cell.cardLeading)
        let right = min(bounds.maxX, cell.maxX - textInset + margin)
        // The counter, waveform, words and Send all end on the time's trailing edge.
        let contentEnd = right - margin
        // Cancel's trailing column returns as the card lands, past the card's edge, where the card
        // is already invisible.
        let overflow = recorder.hidesTrailingColumn ? 0 : max(cell.maxX - right, 0) + margin
        let lines = fiveLines ?? 5 * Self.lineHeight(dynamicTypeSize)
        let chrome = self.chrome ?? 0
        let placement = CardPlacement(row: cell, room: room)
        // The highest the card rises, at its tallest, with five lines of words.
        let highest = placement.top(height: cell.height + chrome + lines)
        let wordsLimit = max(lines / 5, min(lines, room.maxY - highest - cell.height - chrome))
        let card = VStack(alignment: .leading, spacing: 0) {
            row
                .frame(width: cell.width, height: cell.height)
                .environment(\.cardMarkTaps, false)
                .accessibilityActions {
                    if recorder.canResume { Button("Resume", action: recorder.resume) }
                }
                .accessibilityFocused($headingFocused)
            note(grown: grown, wordsLimit: wordsLimit)
                .frame(width: max(contentEnd - cell.minX, 0))
                .fixedSize(horizontal: false, vertical: true)
                .opacity(lifted ? 1 : 0)
                .transaction(value: lifted) { if !lifted { $0.animation = .easeOut(duration: 0.15) } }
                .accessibilityHidden(!recorder.isLifted)
        }
        .padding(.leading, cell.minX - left)
        .frame(width: max(right - left, 0), alignment: .leading)
        // Sized by layout rather than a measurement, so the card's edge always moves in the same
        // transaction as the controls.
        .frame(maxHeight: max(lifted ? room.maxY - highest : cell.height, 0), alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // Reveals the note as the card grows, and clips everything the card draws to its shape.
        .clipShape(CardShape(overflow: overflow))
        .background {
            // SwiftUI spaces body lines wider than the font's own line height, so the limit comes
            // from laying out five real lines.
            Text(verbatim: "A\nA\nA\nA\nA")
                .font(.body)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fiveLines = $0 }
        }
        .background { surface(grown: grown, lifted: lifted) }
        .environment(\.talkGrown, grown)
        .environment(\.talkTrailingInset, cell.maxX - lineInset - contentEnd)
        .allowsHitTesting(recorder.isLifted)
        // Hands back to the list's own row, which draws the same frame beneath it, in one frame.
        .animation(nil) { $0.opacity(landed ? 0 : 1) }
        .accessibilityHidden(landed)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(recorder.isLifted ? .isModal : [])
        // Grows once the note has measured, in one transaction with every slot's swap.
        .onChange(of: self.chrome != nil) { _, measured in
            if measured, !grown {
                withAnimation(CardMotion.open.animation(reduceMotion: reduceMotion)) { hold.grown = recorder.target }
            }
        }
        .onChange(of: recorder.phase == .sent) { _, sent in
            if sent { headingFocused = true }
        }
        // Talking again from the check reuses the card, so focus follows each opening.
        .onChange(of: recorder.isLifted, initial: true) { _, lifted in
            if lifted { wordsFocused = true }
            #if os(macOS)
            focused = lifted
            #endif
        }
        #if os(macOS)
        // Takes key focus, so the list's arrows and typing wait while Return sends and Escape cancels.
        .focusable(recorder.isLifted)
        .focusEffectDisabled()
        .focused($focused)
        #endif
        CardLayout(placement: placement, x: left, isLifted: lifted) { card }
    }

    private static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        #if os(macOS)
        NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .body))
        #else
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        #endif
    }

    /// The words, any notice and the controls, where the words show at most `wordsLimit` before
    /// the oldest line slides under the fade.
    private func note(grown: Bool, wordsLimit: CGFloat) -> some View {
        let shownWords = wordsHeight.map { min($0, wordsLimit) }
        let notice = self.notice
        return VStack(alignment: .trailing, spacing: 4) {
            words(grown: grown, notice: notice, shownHeight: shownWords)
            if let notice, hasWords {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(ChannelInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            CardControls(canCancel: recorder.phase != .sending, canSend: recorder.canSend,
                         isSending: recorder.phase == .sending, sendLabel: "Send to Lead",
                         cancel: recorder.cancel, send: send)
                // Send's circle, not its hit target, ends on the card's content.
                .padding([.trailing, .bottom], -(CardMetrics.hitTarget - CardMetrics.control) / 2)
                .opacity(grown ? 1 : 0)
                .scaleEffect(grown ? 1 : 0.9, anchor: .trailing)
                .animation(CardMotion.open.animation(reduceMotion: reduceMotion).delay(0.06), value: grown)
        }
        // Lines up with the channel's name, and ends where the card's content does.
        .padding(.leading, Self.nameInset)
        .padding(.bottom, 12)
        // The words' share is their shown height, so the room for everything else holds still as
        // lines arrive.
        .onGeometryChange(for: CGFloat?.self) { proxy in
            shownWords.map { proxy.size.height - $0 }
        } action: { measured in
            guard let measured else { return }
            withAnimation(grown ? .smooth(duration: 0.25) : nil) { chrome = measured }
        }
        .accessibilityElement(children: .contain)
        #if os(iOS)
        .accessibilityAction(.magicTap) { send() }
        #endif
        .accessibilityAction(.escape) { recorder.cancel() }
    }

    private var hasWords: Bool { !recorder.finalizedWords.isEmpty || !recorder.tentativeWords.isEmpty }

    private var notice: String? {
        if let access = recorder.dictation.accessOff, recorder.canResume {
            return access == .microphone ? "Microphone access is off." : "Speech recognition access is off."
        }
        return recorder.dictation.notice?.text
    }

    private func words(grown: Bool, notice: String?, shownHeight: CGFloat?) -> some View {
        let finalized = recorder.finalizedWords
        let tentative = recorder.tentativeWords
        let placeholder = notice ?? (recorder.canResume ? "Paused" : "Listening…")
        let scrolled = max((wordsHeight ?? 0) - (shownHeight ?? 0), 0)
        return Group {
            if hasWords {
                Text("\(Text(finalized))\(Text(tentative).foregroundStyle(ChannelInk.secondary))")
            } else {
                Text(placeholder).foregroundStyle(ChannelInk.secondary)
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A new line lays out before the words measure it, so until then it waits below the clip,
        // and the lines already shown hold still.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            withAnimation(grown ? .smooth(duration: 0.25) : nil) { wordsHeight = height }
        }
        // Past the limit, the oldest line slides up under a short fade.
        .offset(y: -scrolled)
        .frame(height: shownHeight, alignment: .top)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: scrolled > 1 ? 12 : 0)
                Color.black
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note to Lead")
        .accessibilityValue(hasWords ? DictationTranscript.join(finalized, tentative) : placeholder)
        .accessibilityFocused($wordsFocused)
    }

    private func send() {
        Task { await recorder.send() }
    }

    /// The card's surface: opaque, so the dimmed rows never show through, under the phone's
    /// own-message fill. The edge and shadow show only while the card is lifted, and the fill stays
    /// through Sent until the card hands its row back.
    private func surface(grown: Bool, lifted: Bool) -> some View {
        // Once Cancel's card is back on the row, the cell's own background, separator or selection
        // shows through it again.
        let based = recorder.phase != .cancelled
        // Glass can't be matched, so there the row steps once to the card's own color.
        let filled = (grown || onGlass) && based
        // The card lands about 0.2 seconds into its shrink, so the edge and shadow, and Cancel's
        // fill, fade from there.
        let lands = Animation.easeOut(duration: 0.2).delay(0.2)
        let lift: Animation = lifted ? .easeInOut(duration: 0.2) : lands
        // Folded, the base matches the list's own background, so it's solid from the first frame
        // and the dimmed rows never show through. Only the wash fades in.
        return CardSurface(surface: .user, tint: .accentColor, base: based, wash: filled, edge: lifted, shadow: lifted,
                           animations: .init(base: based ? nil : lands,
                                             wash: filled ? (onGlass ? nil : .easeInOut(duration: 0.2)) : lands,
                                             edge: lift, shadow: lift))
    }
}

/// One of the row's own slots, which the card swaps once it grows from the row: the mark, the time,
/// the second line or the trailing column.
private struct TalkSlot: ViewModifier {
    enum Kind { case mark, time, line, trailing }

    let kind: Kind
    let recorder: TalkRecorder?
    @Environment(\.talkGrown) private var grown
    @Environment(\.talkTrailingInset) private var trailingInset
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var prominence

    /// A slot's old face leaves first, then the new one fades in.
    private static let exit = Animation.easeIn(duration: 0.15)
    private static let entry = Animation.easeOut(duration: 0.15).delay(0.15)

    #if os(macOS)
    private static var waveformHeight: CGFloat { 18 }
    #else
    private static var waveformHeight: CGFloat { 24 }
    #endif

    private static func steadyLevels(_ level: Double) -> [Double] {
        (0..<TalkRecorder.sampleCount).map { level * (0.45 + 0.55 * abs(sin(Double($0) * 0.9))) }
    }

    @ViewBuilder func body(content: Content) -> some View {
        switch kind {
        case .mark: mark(content)
        case .time: time(content)
        case .line: line(content)
        case .trailing: trailing(content)
        }
    }

    /// The mic while recording, the done check once sent, then the channel's own avatar as the row
    /// settles. The recorder's mark starts with the avatar, so the swap itself is invisible and the
    /// avatar can morph into the mic.
    private func mark(_ avatar: Content) -> some View {
        ZStack {
            if let recorder {
                let glyph = self.glyph(recorder)
                let level = recorder.isListening ? recorder.dictation.level : 0
                Button(action: recorder.resume) { avatar.cardMark(glyph) }
                    .buttonStyle(TalkMarkButtonStyle())
                    // A disabled button grays its accent, so the mic only stops taking taps.
                    .allowsHitTesting(recorder.canResume)
                    .background {
                        if glyph == .mic {
                            // The glow is wider than the mark, so the halo keeps the mark's own frame.
                            ZStack {
                                Circle()
                                    .fill(RadialGradient(colors: [.accentColor, .accentColor.opacity(0)],
                                                         center: .center, startRadius: 0, endRadius: 32))
                                    .frame(width: 64, height: 64)
                                    .opacity(0.3 * level)
                                TalkHalo(scale: reduceMotion ? 1.4 : 1 + 0.4 * level)
                                    .fill(Color.accentColor.opacity(0.25), style: FillStyle(eoFill: true))
                                    .opacity(reduceMotion ? level : 1)
                                    .frame(width: CardMetrics.mark, height: CardMetrics.mark)
                            }
                        }
                    }
                    .animation(.linear(duration: 0.08), value: level)
                    .transition(.identity)
            } else {
                avatar.transition(.identity)
            }
        }
    }

    private func glyph(_ recorder: TalkRecorder) -> CardMark.Glyph {
        guard grown else { return .channel }
        return switch recorder.phase {
        case .recording, .sending: .mic
        case .sent, .landed, .cancelled, nil: recorder.isChecked ? .check : .channel
        }
    }

    /// The counter, Offline, or the note's time, in place of the row's time. Each face leaves with a
    /// blur and fade, then the next fades in, so two never show together.
    private func time(_ content: Content) -> some View {
        let face = grown ? recorder?.timeSlot : nil
        let replaced = face != nil
        // The time trails the title, or leads its own line below it at accessibility sizes.
        let edge: HorizontalAlignment = dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
        return ZStack(alignment: Alignment(horizontal: edge, vertical: .firstTextBaseline)) {
            content
                .modifier(TalkFaceExit(gone: replaced))
                .animation(replaced ? Self.exit : Self.entry, value: replaced)
            if let recorder, let face {
                Group {
                    switch face {
                    case .counter:
                        TimelineView(.periodic(from: recorder.listeningSince ?? .now, by: 1)) { context in
                            let seconds = Int(recorder.elapsed(at: context.date))
                            Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                        }
                    case .offline: Text("Offline")
                    case .noteTime:
                        // The note is the channel's new last activity, in the row's own format.
                        Text(ChannelActivityTime.label(for: recorder.sentAt ?? .now, now: .now))
                    }
                }
                #if os(iOS)
                .font(.caption)
                #endif
                // The Mac's counter takes the font its row gives the time.
                .foregroundStyle(ChannelInk.secondary(for: prominence))
                .lineLimit(1)
                .fixedSize()
                .id(face)
                .transition(.asymmetric(
                    insertion: .opacity.animation(Self.entry),
                    removal: .modifier(active: TalkFaceExit(gone: true), identity: TalkFaceExit(gone: false))
                        .animation(Self.exit)))
            }
        }
        .transformAnchorPreference(key: TalkEndsKey.self, value: .trailing) { ends, anchor in
            if recorder != nil, !dynamicTypeSize.isAccessibilitySize { ends.text = anchor }
        }
    }

    /// The waveform in place of the row's second line, as bars that flow out of the mic down the
    /// row, newest at the leading edge.
    private func line(_ content: Content) -> some View {
        let shows = grown && recorder?.isLifted == true
        return content
            .modifier(TalkFaceExit(gone: shows))
            // Line 2 leaves quickly, and returns over the second half of Sent's collapse.
            .animation(shows ? .easeOut(duration: 0.15) : .easeIn(duration: 0.175).delay(0.175), value: shows)
            .frame(minHeight: shows ? 18 : nil)
            .transformAnchorPreference(key: TalkEndsKey.self, value: .trailing) { ends, anchor in
                if recorder != nil { ends.line = anchor }
            }
            // The waveform overflows line 2's slot instead of resizing it, so the mark stays put. It
            // ends where Send's circle does.
            .overlay(alignment: .leading) {
                if let recorder, shows {
                    let listening = recorder.isListening
                    // Under Reduce Motion, the bars stay in place and only their heights follow the level.
                    let levels = reduceMotion
                        ? Self.steadyLevels(listening ? recorder.dictation.level : 0)
                        : recorder.levels
                    TalkBars(levels: levels, amplitude: listening ? 1 : 0)
                        .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.25)],
                                             startPoint: .leading, endPoint: .trailing))
                        .animation(.easeOut(duration: 0.2), value: listening)
                        .frame(height: Self.waveformHeight)
                        .padding(.trailing, trailingInset)
                        .transition(.asymmetric(
                            insertion: .modifier(active: TalkRise(scale: 0.2), identity: TalkRise(scale: 1))
                                .combined(with: .opacity),
                            removal: .opacity.animation(.easeOut(duration: 0.15))))
                }
            }
    }

    /// The chevron and attention mark, which fade out with the time, and back as the wash fades.
    private func trailing(_ content: Content) -> some View {
        let fades = grown && recorder?.hidesTrailingColumn == true
        return content
            .opacity(fades ? 0 : 1)
            .animation(fades ? .easeIn(duration: 0.15) : .easeOut(duration: 0.4), value: fades)
    }
}

/// Undimmed while disabled, since the mic is only a button once listening stops.
private struct TalkMarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: CardMetrics.hitTarget, height: CardMetrics.hitTarget)
            .contentShape(Circle())
            .frame(width: CardMetrics.mark, height: CardMetrics.mark)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The voice's halo: a ring around the mark's rounded square that widens with the level and
/// vanishes at silence.
private struct TalkHalo: Shape {
    var scale: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let grow = rect.width * (scale - 1) / 2
        let outer = rect.insetBy(dx: -grow, dy: -grow)
        var path = Path(roundedRect: outer, cornerRadius: outer.width * CardMark.corners, style: .continuous)
        path.addPath(Path(roundedRect: rect, cornerRadius: rect.width * CardMark.corners, style: .continuous))
        return path
    }
}

/// A slot's old face leaving: a 2-point blur and fade. It comes back with only the fade.
private struct TalkFaceExit: ViewModifier {
    let gone: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: gone ? 2 : 0)
            .opacity(gone ? 0 : 1)
    }
}

/// The waveform rising out of line 2's slot.
private struct TalkRise: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: scale)
    }
}

/// 3-point bars with 3-point gaps, from 3 points tall to 2 short of the waveform's height.
private struct TalkBars: Shape {
    var levels: [Double]
    var amplitude: Double

    var animatableData: Double {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pitch: CGFloat = 6
        let count = min(Int((rect.width + 3) / pitch), levels.count)
        for index in 0..<max(count, 0) {
            let level = min(max(levels[index] * amplitude, 0), 1)
            let height = 3 + (rect.height - 5) * level
            let bar = CGRect(x: rect.minX + CGFloat(index) * pitch, y: rect.midY - height / 2, width: 3, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 1.5, height: 1.5))
        }
        return path
    }
}

private struct TalkRow: ViewModifier {
    let target: ChannelTarget
    let recorder: TalkRecorder
    let offered: Bool
    let line: Visibility
    let start: () -> Void
    @Environment(TalkHold.self) private var hold: TalkHold?
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        let isHeld = recorder.target == target
        let isGrown = isHeld && hold?.isGrown(target) == true
        // The card draws this row until it lands, so the cell's own content hides beneath it.
        let isCovered = isHeld && hold?.cell?.target == target && recorder.phase != .landed
        // Dims with the card's growth, since rows don't animate in the swipe action's transaction.
        let isDimmed = recorder.isLifted && hold?.isGrown(recorder.target) == true && !isHeld
        let offersTalk = offered && recorder.isAvailable && !recorder.isLifted
        let hidesLine = recorder.hiddenLines.contains(target)
        content
            // From Send, the row wears the card's check and time beneath it, and its surface in
            // the card's frame, so it carries them on as the card lands. The surface then fades as
            // a wash over the selection band.
            .environment(\.talkGrown, isGrown && !recorder.isLifted)
            .background {
                if isGrown, let cell = hold?.cell {
                    let washed = recorder.phase == .sent
                    let fade: Animation? = washed ? nil : .easeOut(duration: 0.4)
                    CardSurface(surface: .user, tint: .accentColor, base: washed, wash: washed, edge: false,
                                animations: .init(base: fade, wash: fade))
                        .padding(.leading, -TalkHold.Cell.cardLeading)
                        .padding(.trailing, cell.textInset - TalkHold.Cell.cardMargin)
                }
            }
            .animation(nil) { $0.opacity(isCovered ? 0 : 1) }
            .opacity(isDimmed ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.25), value: isDimmed)
            // The note's time becomes the row's own time without a swap, since both read the same.
            .transaction(value: isHeld) { if !isHeld { $0.disablesAnimations = true } }
            // Only the held row hides its selection, which returns as the Sent wash fades or as
            // Cancel's card lands. The open channel's row keeps its band while it dims.
            .selectionDisabled(isHeld && (recorder.isLifted || recorder.phase == .sent))
            .accessibilityHidden(isCovered)
            .accessibilityFocused($focused)
            .backgroundPreferenceValue(TalkEndsKey.self) { ends in
                // Only the held row reports its frame, which it does as soon as the recorder holds it.
                if isHeld {
                    Color.clear.onGeometryChange(for: TalkHold.Cell.self) { proxy in
                        let inset = { (end: Anchor<CGPoint>?) in end.map { max(proxy.size.width - proxy[$0].x, 0) } ?? 0 }
                        return TalkHold.Cell(target: target, frame: proxy.frame(in: .global),
                                             textInset: inset(ends.text), lineInset: inset(ends.line))
                    } action: { cell in
                        hold?.cell = cell
                    }
                }
            }
            // Focus comes to the row as the card hands it back.
            .onChange(of: isHeld ? recorder.phase : nil) { old, new in
                if new == .landed || old == .cancelled && new == nil { focused = true }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if offersTalk {
                    Button("Talk", systemImage: "mic.fill", action: start)
                        .labelStyle(.iconOnly)
                        .tint(.accentColor)
                        .accessibilityLabel("Talk to Lead")
                }
            }
            .listRowSeparator(hidesLine ? .hidden : line, edges: .bottom)
    }
}

private struct TalkList<Row: View>: ViewModifier {
    let recorder: TalkRecorder
    let targets: [ChannelTarget]
    let onGlass: Bool
    let context: [AnyHashable?]
    let row: (ChannelTarget) -> Row
    @ViewState private var hold = TalkHold()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(hold)
            .cardList(isLifted: recorder.isLifted, target: recorder.target, targets: targets,
                      endsWhenChanging: context, end: recorder.leave) { list in
                if let target = recorder.target, let cell = hold.cell, cell.target == target {
                    TalkCard(recorder: recorder, hold: hold, cell: cell.frame.offsetBy(dx: -list.minX, dy: -list.minY),
                             textInset: cell.textInset, lineInset: cell.lineInset,
                             bounds: CGRect(origin: .zero, size: list.size),
                             onGlass: onGlass) {
                        row(target)
                    }
                }
            }
            // Talking again on a row that still wears the check keeps the recorder on it, so its card
            // stays up and the check swaps straight to the mic.
            .onChange(of: recorder.target) { _, target in
                if target == nil { hold.release() }
            }
            .onAppear { recorder.activate() }
            .onDisappear { recorder.deactivate() }
            .task(id: scenePhase) {
                if scenePhase == .active { await recorder.dictation.refreshLanguageSupport() }
            }
    }
}

private extension TalkRecorder {
    /// The held row's accessibility value.
    func rowValue(details: String) -> String {
        switch phase {
        case .recording: canResume ? "Paused" : isOffline ? "Recording, offline" : "Recording"
        case .sending: "Sending"
        case .sent, .landed: isChecked ? "Sent to Lead. " + details : details
        case .cancelled, nil: details
        }
    }
}
