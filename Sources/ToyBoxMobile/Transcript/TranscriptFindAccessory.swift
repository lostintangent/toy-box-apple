import ChannelKit
import SwiftUI
import ToyBoxUI

extension TranscriptFindHighlight {
    /// UIKit has no public find color, so this uses the system yellow its own find bar draws. Other
    /// matches show the page through their lighter fill, so their text follows the appearance.
    static func phone(query: String, isCurrent: Bool) -> TranscriptFindHighlight {
        .init(query: query, isCurrent: isCurrent, background: Color(uiColor: .systemYellow),
              foreground: isCurrent ? .black : Color(uiColor: .label))
    }
}

/// Find and the composer swap on one short spring: the leaving bar blurs out and drops a few points
/// while the arriving one rises into the same spot. Reduce Motion crossfades.
enum TranscriptFindSwap {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }
}

extension View {
    func findSwapTransition() -> some View { modifier(FindSwapTransition()) }
}

private struct FindSwapTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : AnyTransition(.blurReplace).combined(with: .offset(y: 8)))
    }
}

/// Find takes the composer's place at the bottom, like Safari's and Notes' find bars, on three
/// Liquid Glass surfaces of one height: a field with its status slot inside, joined Previous and
/// Next, and Close. The caret is its only accent.
struct TranscriptFindAccessory: View {
    @Bindable var find: TranscriptFind
    let channelName: String
    let focusRequest: UUID
    var navigate: (Int) -> Void
    var close: () -> Void
    @FocusState private var isFocused: Bool
    @ViewState private var selection: TextSelection?
    @ViewState private var progressDelayElapsed = false
    @ViewState private var showsError = false
    @ViewState private var keyboardIsVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var height = 44

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        field
                        controls
                    }
                    stacked
                }
            }
        }
        // The composer's frame, which this replaces.
        .padding(.top, 8)
        .padding(.horizontal, sizeClass == .compact ? 12 : 16)
        .padding(.bottom, ComposerBottomSpacing.value(compact: sizeClass == .compact,
                                                      keyboardVisible: keyboardIsVisible))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { event in
            guard let screen = event.object as? UIScreen,
                  let frame = event.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardIsVisible = ComposerBottomSpacing.keyboardIsVisible(frame: frame, in: screen.bounds,
                                                                         safeAreaBottom: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Conversation")
        // A task runs once the bar is in the hierarchy, so the field can take focus.
        .task(id: focusRequest) {
            isFocused = true
            selection = TextSelection(range: find.query.startIndex..<find.query.endIndex)
        }
        .transcriptFindStatusUpdates(find, progressDelayElapsed: $progressDelayElapsed)
        .onChange(of: find.query) { showsError = false }
        .onChange(of: find.error == nil) { if find.error == nil { showsError = false } }
    }

    private var stacked: some View {
        VStack(alignment: .trailing, spacing: 8) {
            field
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            navigation
            closeButton
        }
    }

    private var field: some View {
        TranscriptFindFieldLayout {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(TranscriptInk.secondary)
                    .accessibilityHidden(true)
                query
            }
            if find.hasQuery {
                TranscriptFindStatusView(status: find.status(progressDelayElapsed: progressDelayElapsed),
                                         found: find.partialCountLabel, showsError: $showsError) {
                    showsError = false
                    find.retryHistory()
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minHeight: height)
        .glassEffect(.regular, in: .rect(cornerRadius: height / 2))
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }

    private var query: some View {
        TextField("Find", text: $find.query, selection: $selection)
            .focused($isFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit {
                navigate(1)
                isFocused = true
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                navigate(-1)
                return .handled
            }
            .accessibilityLabel("Find in \(channelName)")
            .accessibilityIdentifier("channel-find-field")
            .frame(minWidth: TranscriptFindFieldLayout.minimumQueryWidth)
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            Button("Previous Match", systemImage: "chevron.up") { navigate(-1) }
                .frame(width: height, height: height)
            Button("Next Match", systemImage: "chevron.down") { navigate(1) }
                .frame(width: height, height: height)
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(find.matches.isEmpty)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.body.weight(.medium))
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Find")
    }
}

/// Keeps the status beside the query while the query keeps its 64-point viewport, and otherwise
/// puts it under the query inside the same growing field, in one layout pass.
struct TranscriptFindFieldLayout: Layout {
    static let minimumQueryWidth: CGFloat = 64
    var spacing: CGFloat = 4

    private struct Arrangement {
        var wraps = false
        var queryWidth: CGFloat?
        var status = CGSize.zero
        var size = CGSize.zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let query = subviews.first else { return }
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        let queryProposal = ProposedViewSize(width: arrangement.queryWidth, height: nil)
        if arrangement.wraps {
            query.place(at: bounds.origin, anchor: .topLeading, proposal: queryProposal)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing,
                              proposal: ProposedViewSize(arrangement.status))
        } else {
            query.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: queryProposal)
            if subviews.count > 1 {
                subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                                  proposal: ProposedViewSize(arrangement.status))
            }
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
        guard let query = subviews.first else { return Arrangement() }
        guard subviews.count > 1 else {
            let size = query.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return Arrangement(queryWidth: width, size: size)
        }
        let status = subviews[1].sizeThatFits(.unspecified)
        let minimum = query.sizeThatFits(ProposedViewSize(width: 0, height: nil))
        // Ideal is the narrowest single line, so ViewThatFits keeps one row whenever the query
        // still gets its 64-point viewport, whatever has been typed.
        guard let width else {
            return Arrangement(queryWidth: minimum.width, status: status,
                               size: CGSize(width: minimum.width + spacing + status.width,
                                            height: max(minimum.height, status.height)))
        }
        let besideWidth = width - spacing - status.width
        if besideWidth >= minimum.width {
            let size = query.sizeThatFits(ProposedViewSize(width: besideWidth, height: nil))
            return Arrangement(queryWidth: besideWidth, status: status,
                               size: CGSize(width: width, height: max(size.height, status.height)))
        }
        let size = query.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return Arrangement(wraps: true, queryWidth: width, status: status,
                           size: CGSize(width: width, height: size.height + spacing + status.height))
    }
}

/// The field's trailing slot keeps one footnote line's size for every nonempty query, so a spinner,
/// count or Incomplete swap never resizes the field. Incomplete's 44-point target overflows it.
struct TranscriptFindStatusView: View {
    let status: TranscriptFindStatus
    let found: String
    @Binding var showsError: Bool
    var retry: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var width = 84

    var body: some View {
        Text(verbatim: " ").font(.footnote).hidden()
            .frame(width: width)
            .overlay(alignment: .trailing) { content }
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .hidden, .blank:
            Color.clear.frame(height: 1).accessibilityHidden(true)
        case .progress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Searching older messages")
        case .result(let result):
            Text(result)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(TranscriptInk.secondary)
                .lineLimit(1)
                .accessibilityLabel("Matching messages: \(result)")
        case .incomplete(let error):
            Button { showsError = true } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        incomplete
                        Text("Incomplete")
                    }
                    incomplete
                }
                .font(.footnote)
                .imageScale(.small)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: .label))
            .accessibilityLabel("Search incomplete")
            .accessibilityHint("Shows why older messages couldn't be searched, with Retry.")
            .popover(isPresented: $showsError) {
                TranscriptFindErrorPopover(error: error, found: found, retry: retry)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var incomplete: some View {
        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
    }
}

private struct TranscriptFindErrorPopover: View {
    let error: String
    let found: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't search older messages").font(.headline)
            Text(error).foregroundStyle(TranscriptInk.secondary)
            Text(found).foregroundStyle(TranscriptInk.secondary)
            Button("Retry", action: retry)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .frame(idealWidth: 280)
        .padding()
    }
}
