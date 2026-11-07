import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

// The recorder is a card over the list. It opens on the held row's cell and draws the row's own
// content in the same places, so its mark, time and second line swap in their own slots, then it
// grows over the dimmed rows. The cell itself never changes height. See Talk to the Lead in
// docs/spec.md.

extension View {
    /// The row's mark, which becomes the recorder's mic and then the done check.
    func talkMark(_ recorder: TalkRecorder?, emphasized: Bool) -> some View {
        modifier(TalkMarkSlot(recorder: recorder, emphasized: emphasized))
    }

    /// The row's last-activity time, which becomes the counter on the same baseline and trailing
    /// edge, and marks where the row's text ends.
    func talkTime(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkTimeSlot(recorder: recorder))
    }

    /// The row's trailing column, the chevron and attention mark, which leaves its space empty
    /// until the card lands.
    func talkFades(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkFades(recorder: recorder))
    }

    /// The row's second line, which gives way to the waveform while the recorder is open.
    func talkLine(_ recorder: TalkRecorder?) -> some View {
        modifier(TalkLineSlot(recorder: recorder))
    }

    /// Offers Talk on a channel row when `offered`, and dims the row while another row records.
    /// The row shows its bottom `line` whenever the recorder doesn't hide it.
    func talkRow(_ channelID: String, recorder: TalkRecorder, offered: Bool = true, line: Visibility = .automatic,
                 start: @escaping () -> Void) -> some View {
        modifier(TalkRow(channelID: channelID, recorder: recorder, offered: offered, line: line, start: start))
    }

    /// Floats the recorder over the list from the held row, drawn by `row`. Holds the list still
    /// while recording, and ends the note as a draft when anything in `context` changes, such as
    /// opening a channel, Search or Settings, or when the held channel leaves `channelIDs`. Pass
    /// `onGlass` for the unfolded Liquid Glass sidebar, which no opaque base can match.
    func talkList<Row: View>(_ recorder: TalkRecorder, channelIDs: [String], onGlass: Bool = false,
                             endsWhenChanging context: [AnyHashable?],
                             @ViewBuilder row: @escaping (String) -> Row) -> some View {
        modifier(TalkList(recorder: recorder, channelIDs: channelIDs, onGlass: onGlass, context: context, row: row))
    }
}

private struct TalkGrownKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TalkTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// True once the card has grown from the row, so the list's own row and the card's first frame
    /// both draw the ordinary row.
    fileprivate var talkGrown: Bool {
        get { self[TalkGrownKey.self] }
        set { self[TalkGrownKey.self] = newValue }
    }

    /// How far before the row's trailing edge the card's content ends, 12 points inside the card.
    fileprivate var talkTrailingInset: CGFloat {
        get { self[TalkTrailingInsetKey.self] }
        set { self[TalkTrailingInsetKey.self] = newValue }
    }
}

/// Where the row's text ends: the time's trailing edge, or nil when the time leads its own line.
private struct TalkTextEndKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// The recorder: a card over the list that opens on the held row's cell, draws the row's own
/// content in the same places, then grows over the dimmed rows.
private struct TalkCard<Row: View>: View {
    let recorder: TalkRecorder
    /// The held row's content, in the card's space.
    let cell: CGRect
    /// How far before the cell's trailing edge the row's text ends.
    let textInset: CGFloat
    /// The list's visible area, inside the safe area and any bottom bar.
    let bounds: CGRect
    let onGlass: Bool
    @ViewBuilder let row: Row
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var headingFocused: Bool
    @ViewState private var note = TalkNote.Size()
    /// The height of five lines of the words' own text, as laid out.
    @ViewState private var fiveLines: CGFloat?

    /// The room the card keeps from the visible area's ends.
    private static var inset: CGFloat { 8 }
    /// The card's sides sit this far outside the row's text.
    private static var margin: CGFloat { 12 }

    var body: some View {
        let open = recorder.isGrown && recorder.isOpen
        let room = bounds.insetBy(dx: 0, dy: Self.inset)
        let left = max(bounds.minX, cell.minX - Self.margin)
        let right = min(bounds.maxX, cell.maxX - textInset + Self.margin)
        // The counter, waveform, words and Send all end 12 points inside the card.
        let contentEnd = right - Self.margin
        // The trailing column returns as the card lands, past the card's edge, where the card is
        // already invisible.
        let overflow = recorder.hidesTrailingColumn ? 0 : max(cell.maxX - right, 0) + Self.margin
        let lines = fiveLines ?? 5 * TalkNote.lineHeight(dynamicTypeSize)
        let chrome = note.height - note.words
        let placement = TalkRecorder.Placement(row: cell, room: room)
        // The highest the card rises, at its tallest, with five lines of words.
        let highest = placement.top(height: cell.height + chrome + lines)
        let wordsLimit = max(lines / 5, min(lines, room.maxY - highest - cell.height - chrome))
        let card = VStack(alignment: .leading, spacing: 0) {
            row
                .frame(width: cell.width, height: cell.height)
                .accessibilityActions {
                    if recorder.canResume { Button("Resume", action: recorder.resume) }
                }
                .accessibilityFocused($headingFocused)
            TalkNote(recorder: recorder, wordsLimit: wordsLimit, size: $note)
                .frame(width: max(contentEnd - cell.minX, 0))
                .fixedSize(horizontal: false, vertical: true)
                .opacity(open ? 1 : 0)
                .transaction(value: open) { if !open { $0.animation = .easeOut(duration: 0.15) } }
                .accessibilityHidden(!recorder.isOpen)
        }
        .padding(.leading, cell.minX - left)
        .frame(width: max(right - left, 0), alignment: .leading)
        // Sized by layout rather than a measurement, so the card's edge always moves in the same
        // transaction as the controls.
        .frame(maxHeight: max(open ? room.maxY - highest : cell.height, 0), alignment: .top)
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
        .background { TalkSurface(recorder: recorder, lifted: open, onGlass: onGlass) }
        .environment(\.talkGrown, recorder.isGrown)
        .environment(\.talkTrailingInset, cell.maxX - contentEnd)
        .allowsHitTesting(recorder.isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(recorder.isOpen ? .isModal : [])
        // Grows once the note has measured, in one transaction with every slot's swap.
        .onChange(of: note.height > 0) { _, measured in
            if measured, !recorder.isGrown { withAnimation(TalkRecorder.motion(.open)) { recorder.isGrown = true } }
        }
        .onChange(of: recorder.phase == .sent) { _, sent in
            if sent { headingFocused = true }
        }
        CardLayout(placement: placement, x: left, isOpen: open) { card }
    }
}

private struct TalkFades: ViewModifier {
    let recorder: TalkRecorder?
    @Environment(\.talkGrown) private var grown

    func body(content: Content) -> some View {
        let fades = grown && recorder?.hidesTrailingColumn == true
        // Fades out with the time, and back as the wash fades.
        content
            .opacity(fades ? 0 : 1)
            .animation(fades ? .easeIn(duration: 0.15) : .easeOut(duration: 0.4), value: fades)
    }
}

private struct TalkMarkSlot: ViewModifier {
    let recorder: TalkRecorder?
    let emphasized: Bool

    func body(content: Content) -> some View {
        // The recorder's mark starts with the channel's own face, so the swap itself is invisible
        // and the glyph can morph into the mic.
        ZStack {
            if let recorder {
                TalkMark(recorder: recorder, emphasized: emphasized).transition(.identity)
            } else {
                content.transition(.identity)
            }
        }
    }
}

/// The mic while recording, the done check once sent, then the channel's own mark as the row
/// settles.
private struct TalkMark: View {
    let recorder: TalkRecorder
    let emphasized: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.talkGrown) private var grown

    private enum Face { case mic, check, channel }

    private var face: Face {
        guard grown else { return .channel }
        return switch recorder.phase {
        case .sent, .landed: .check
        case .settling, nil: .channel
        case .recording, .sending, .failed: .mic
        }
    }

    var body: some View {
        let level = recorder.isListening ? recorder.dictation.level : 0
        Button(action: recorder.resume) { glyph }
            .buttonStyle(TalkMarkButtonStyle())
            // A disabled button grays its accent, so the mic only stops taking taps.
            .allowsHitTesting(recorder.canResume)
            .background {
                // Each face keeps its own fill so the change cross-fades instead of jumping. The
                // check brings its own circle.
                ZStack {
                    Circle()
                        .fill(emphasized ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(ChannelMark.cyan.gradient))
                        .opacity(face == .channel ? 1 : 0)
                    Circle().fill(Color.accentColor.opacity(0.15)).opacity(face == .mic ? 1 : 0)
                }
                .frame(width: 28, height: 28)
            }
            .background {
                if face == .mic {
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
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .animation(.linear(duration: 0.08), value: level)
            .sensoryFeedback(.success, trigger: face == .check) { _, sent in sent }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            // At this size the check's circle fills the mark's 28 points, with its check knocked out.
            .font(.system(size: face == .check ? 27.4 : 28 * 14 / 30, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(ink)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 28, height: 28)
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

/// Undimmed while disabled, since the mic is only a button once listening stops.
private struct TalkMarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .frame(width: 28, height: 28)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The voice's halo: a ring outside the mic that widens with the level and vanishes at silence.
private struct TalkHalo: Shape {
    var scale: Double

    var animatableData: Double {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let grow = rect.width * (scale - 1) / 2
        var path = Path(ellipseIn: rect.insetBy(dx: -grow, dy: -grow))
        path.addEllipse(in: rect)
        return path
    }
}

private struct TalkTimeSlot: ViewModifier {
    let recorder: TalkRecorder?
    @Environment(\.talkGrown) private var grown
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let face = grown ? recorder?.timeFace : nil
        let replaced = face != nil
        // The time trails the title, or leads its own line below it at accessibility sizes.
        let edge: HorizontalAlignment = dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
        // Each face leaves with a blur and fade, then the next fades in, so two never show together.
        ZStack(alignment: Alignment(horizontal: edge, vertical: .firstTextBaseline)) {
            content
                .modifier(TalkFaceExit(gone: replaced))
                .animation(replaced ? TalkTime.exit : TalkTime.entry, value: replaced)
            if let recorder, let face {
                TalkTime(recorder: recorder, face: face)
                    .id(face)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(TalkTime.entry),
                        removal: .modifier(active: TalkFaceExit(gone: true), identity: TalkFaceExit(gone: false))
                            .animation(TalkTime.exit)))
            }
        }
        .anchorPreference(key: TalkTextEndKey.self, value: .trailing) { anchor in
            recorder != nil && !dynamicTypeSize.isAccessibilitySize ? anchor : nil
        }
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

private struct TalkTime: View {
    let recorder: TalkRecorder
    let face: TalkRecorder.TimeFace
    @Environment(\.backgroundProminence) private var prominence

    static let exit = Animation.easeIn(duration: 0.15)
    static let entry = Animation.easeOut(duration: 0.15).delay(0.15)

    var body: some View {
        Group {
            switch face {
            case .counter: counter
            case .offline: Text("Offline")
            case .failed(let failure): Text(failure.label)
            case .noteTime:
                // The note is the channel's new last activity, in the row's own format.
                Text(ChannelActivityTime.label(for: recorder.sentAt ?? .now, now: .now))
            }
        }
        .font(.caption)
        .foregroundStyle(ChannelInk.secondary(for: prominence))
        .lineLimit(1)
        .fixedSize()
    }

    private var counter: some View {
        TimelineView(.periodic(from: recorder.listeningSince ?? .now, by: 1)) { context in
            let seconds = Int(recorder.elapsed(at: context.date))
            Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: seconds)
        }
    }
}

private struct TalkLineSlot: ViewModifier {
    let recorder: TalkRecorder?
    @Environment(\.talkGrown) private var grown
    @Environment(\.talkTrailingInset) private var trailingInset

    func body(content: Content) -> some View {
        let shows = grown && recorder?.isOpen == true
        content
            .modifier(TalkFaceExit(gone: shows))
            // Line 2 leaves quickly, and returns over the second half of Sent's collapse.
            .animation(shows ? .easeOut(duration: 0.15) : .easeIn(duration: 0.175).delay(0.175), value: shows)
            .frame(minHeight: shows ? 18 : nil)
            // The waveform overflows line 2's slot instead of resizing it, so the mark stays put. It
            // ends where Send's circle does.
            .overlay(alignment: .leading) {
                if let recorder, shows {
                    TalkWaveform(recorder: recorder)
                        .padding(.trailing, trailingInset)
                        .transition(.asymmetric(
                            insertion: .modifier(active: TalkRise(scale: 0.2), identity: TalkRise(scale: 1))
                                .combined(with: .opacity),
                            removal: .opacity.animation(.easeOut(duration: 0.15))))
                }
            }
    }
}

private struct TalkRise: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: scale)
    }
}

/// Bars that flow out of the mic down the row, newest at the leading edge.
private struct TalkWaveform: View {
    let recorder: TalkRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = recorder.isListening
        TalkBars(levels: reduceMotion ? steadyLevels : recorder.levels, amplitude: listening ? 1 : 0)
            .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.25)],
                                 startPoint: .leading, endPoint: .trailing))
            .animation(.easeOut(duration: 0.2), value: listening)
            .frame(height: 24)
    }

    /// Under Reduce Motion, the bars stay in place and only their heights follow the level.
    private var steadyLevels: [Double] {
        let level = recorder.isListening ? recorder.dictation.level : 0
        return (0..<TalkRecorder.sampleCount).map { index in
            level * (0.45 + 0.55 * abs(sin(Double(index) * 0.9)))
        }
    }
}

/// 3-point bars with 3-point gaps, 3 to 22 points tall.
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
            let height = 3 + 19 * level
            let bar = CGRect(x: rect.minX + CGFloat(index) * pitch, y: rect.midY - height / 2, width: 3, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 1.5, height: 1.5))
        }
        return path
    }
}

/// The words, any notice and the controls, which the card reveals below the row's first two lines.
private struct TalkNote: View {
    let recorder: TalkRecorder
    /// The most the words show before the oldest line slides under the fade.
    let wordsLimit: CGFloat
    @Binding var size: Size
    @Environment(\.talkGrown) private var grown
    @AccessibilityFocusState private var wordsFocused: Bool
    @ViewState private var wordsHeight: CGFloat?

    /// The note's height, and the part of it the words take, which tell the card its room for
    /// five lines.
    struct Size: Equatable {
        var height: CGFloat = 0
        var words: CGFloat = 0
    }

    static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
    }

    var body: some View {
        let shownWords = shownWordsHeight
        VStack(alignment: .trailing, spacing: 4) {
            words
            if let notice, hasWords {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(ChannelInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls
                .padding(.trailing, -6)
                .opacity(grown ? 1 : 0)
                .scaleEffect(grown ? 1 : 0.9, anchor: .trailing)
                .animation(TalkRecorder.motion(.open).delay(0.06), value: grown)
        }
        // Lines up with the channel's name, and ends where the card's content does.
        .padding(.leading, 40)
        .padding(.bottom, 6)
        // The words' share is their shown height, so the room for everything else holds still as
        // lines arrive.
        .onGeometryChange(for: Size?.self) { proxy in
            shownWords.map { Size(height: proxy.size.height, words: $0) }
        } action: { measured in
            guard let measured else { return }
            withAnimation(grown ? .smooth(duration: 0.25) : nil) { size = measured }
        }
        .dictationAccessSheet(recorder.dictation)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.magicTap) { send() }
        .accessibilityAction(.escape) { recorder.cancel() }
        // Talking again from the check reuses the card, so focus follows each opening.
        .onChange(of: recorder.isOpen, initial: true) { _, open in
            if open { wordsFocused = true }
        }
    }

    private var shownWordsHeight: CGFloat? { wordsHeight.map { min($0, wordsLimit) } }

    private var hasWords: Bool { !recorder.finalizedWords.isEmpty || !recorder.tentativeWords.isEmpty }

    private var notice: String? {
        if let access = recorder.dictation.accessOff, recorder.canResume {
            return access == .microphone ? "Microphone access is off." : "Speech recognition access is off."
        }
        return recorder.dictation.notice?.text
    }

    private var placeholder: String {
        if let notice { return notice }
        return recorder.canResume ? "Paused" : "Listening…"
    }

    private var words: some View {
        let finalized = recorder.finalizedWords
        let tentative = recorder.tentativeWords
        let shownHeight = shownWordsHeight
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

    private var isFailed: Bool {
        if case .failed = recorder.phase { return true }
        return false
    }

    private var controls: some View {
        CardControls(canCancel: recorder.phase != .sending, canSend: recorder.canSend,
                     isSending: recorder.phase == .sending, showsProgress: recorder.showsProgress,
                     isFailed: isFailed, sendLabel: "Send to Lead", cancel: recorder.cancel, send: send)
    }

    private func send() {
        Task { await recorder.send() }
    }
}

/// The card's surface: opaque, so the dimmed rows never show through, under the phone's own-message
/// fill. The edge and shadow show only while the card is lifted, and the fill stays through Sent as
/// a wash until the row settles.
private struct TalkSurface: View {
    let recorder: TalkRecorder
    let lifted: Bool
    let onGlass: Bool
    @Environment(\.talkGrown) private var grown

    var body: some View {
        let landed = recorder.phase == .landed
        // Once the card is back on the row, the cell's own background, separator or selection
        // shows through it again.
        let based = !landed && recorder.phase != .settling
        // Glass can't be matched, so there the row steps once to the card's own color.
        let filled = (grown || onGlass) && based
        // The card lands about 0.2 seconds into its shrink, so the edge and shadow, and Cancel's
        // fill, fade from there. The sent card's wash fades once it has landed.
        let lands = Animation.easeOut(duration: 0.2).delay(0.2)
        let unfill: Animation = landed ? .easeOut(duration: 0.4) : lands
        let lift: Animation = lifted ? .easeInOut(duration: 0.2) : lands
        // Folded, the base matches the list's own background, so it's solid from the first frame
        // and the dimmed rows never show through. Only the wash fades in.
        CardSurface(surface: .user, tint: .accentColor, base: based, wash: filled, edge: lifted, shadow: lifted,
                    animations: .init(base: based ? nil : unfill,
                                      wash: filled ? (onGlass ? nil : .easeInOut(duration: 0.2)) : unfill,
                                      edge: lift, shadow: lift))
    }
}

private struct TalkRow: ViewModifier {
    let channelID: String
    let recorder: TalkRecorder
    let offered: Bool
    let line: Visibility
    let start: () -> Void
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        let isHeld = recorder.channelID == channelID
        // The card draws this row while it's up, so the cell's own content hides beneath it.
        let isCovered = isHeld && recorder.cell != nil
        // Dims with the card's growth, since rows don't animate in the swipe action's transaction.
        let isDimmed = recorder.isOpen && recorder.isGrown && !isHeld
        let offersTalk = offered && recorder.isAvailable && !recorder.isOpen
        let hidesLine = recorder.hidesLine(under: channelID)
        content
            .opacity(isCovered ? 0 : isDimmed ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.25), value: isDimmed)
            // Only the held row hides its selection, which returns as the Sent wash fades or as
            // Cancel's card lands. The open channel's row keeps its band while it dims.
            .selectionDisabled(isHeld && (recorder.isOpen || recorder.phase == .sent))
            .accessibilityHidden(isCovered)
            .accessibilityFocused($focused)
            .backgroundPreferenceValue(TalkTextEndKey.self) { textEnd in
                // Only the held row reports its frame, which it does as soon as the recorder holds it.
                if isHeld {
                    Color.clear.onGeometryChange(for: TalkRecorder.Cell.self) { proxy in
                        let width = proxy.size.width
                        return TalkRecorder.Cell(frame: proxy.frame(in: .global),
                                                 textInset: textEnd.map { max(width - proxy[$0].x, 0) } ?? 0)
                    } action: { cell in
                        recorder.cell = cell
                    }
                }
            }
            // Focus comes back to the row once the card hands it back.
            .onChange(of: isHeld ? recorder.phase : nil) { old, new in
                if old == .settling, new == nil { focused = true }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if offersTalk {
                    Button("Talk", systemImage: "mic.fill", action: start)
                        .tint(.accentColor)
                        .accessibilityLabel("Talk to Lead")
                }
            }
            .listRowSeparator(hidesLine ? .hidden : line, edges: .bottom)
            .background { TalkRowLine(isHidden: hidesLine) }
    }
}

/// UIKit's list reads each row's separators only when it lays out, and nothing lays it out as the
/// card starts shrinking, so a changed `listRowSeparator` waits for some unrelated update. This
/// lays the row's list out again whenever its line changes.
private struct TalkRowLine: UIViewRepresentable {
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

private struct TalkList<Row: View>: ViewModifier {
    let recorder: TalkRecorder
    let channelIDs: [String]
    let onGlass: Bool
    let context: [AnyHashable?]
    let row: (String) -> Row
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .scrollDisabled(recorder.isOpen)
            .accessibilityHidden(recorder.isOpen)
            .overlay {
                GeometryReader { proxy in
                    // The dimmed rows ignore taps, so the open channel's row can keep its selection.
                    if recorder.isOpen {
                        Color.clear.contentShape(Rectangle())
                    }
                    if let channelID = recorder.channelID, let cell = recorder.cell {
                        let origin = proxy.frame(in: .global).origin
                        TalkCard(recorder: recorder, cell: cell.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                                 textInset: cell.textInset, bounds: CGRect(origin: .zero, size: proxy.size),
                                 onGlass: onGlass) {
                            row(channelID)
                        }
                    }
                }
            }
            .onChange(of: context) { recorder.leave() }
            .onChange(of: recorder.channelID.map { !channelIDs.contains($0) } ?? false) { _, isGone in
                if isGone { recorder.leave() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { recorder.leave() }
            }
            .onAppear { recorder.activate() }
            .onDisappear { recorder.deactivate() }
            .task(id: scenePhase) {
                if scenePhase == .active { await recorder.dictation.refreshLanguageSupport() }
            }
    }
}
