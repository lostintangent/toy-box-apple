import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The tray's bookmarks list, newest first. Like a menu, it's one keyboard target: the pointer and
/// the arrow keys share one highlight, a click, Return or Space shows the row's message, and Delete
/// removes its bookmark. Opening it pages history back through the oldest bookmark, so every row
/// can preview its message.
struct ComposerBookmarksPopover: View {
    static let width: CGFloat = 360
    static let inset: CGFloat = 16
    /// Keeps the popover within 420 points, with room for the title and insets.
    static let maxListHeight: CGFloat = 360

    let store: ChannelStore
    let onReveal: (Int) -> Void
    @ViewState private var highlight = Highlight()
    @ViewState private var rowsHeight: CGFloat?
    @ViewState private var loadAttempt = 0
    @ViewState private var loadError: String?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = store.bookmarkList
        let loaded = entries.filter { $0.message != nil }.map(\.sequence)
        let canRemove = store.phase.isConnected
        VStack(alignment: .leading, spacing: 4) {
            Text("Bookmarks").font(.headline)
                .padding(.horizontal, Self.inset)
            if entries.isEmpty {
                // Its own height, not the last row's, so the symbol shows above the title.
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(entries) { entry in
                                if let message = entry.message {
                                    ComposerBookmarkRow(message: message, agents: store.roster,
                                                        preview: entry.preview(agents: store.roster) ?? "",
                                                        isHighlighted: highlight.sequence == entry.sequence,
                                                        canRemove: canRemove,
                                                        onHover: { highlight.sequence = entry.sequence },
                                                        onReveal: { onReveal(entry.sequence) },
                                                        onRemove: { remove(entry.sequence, among: loaded) })
                                        .id(entry.sequence)
                                } else {
                                    ComposerBookmarkPlaceholder()
                                }
                            }
                            if loadError != nil, loaded.count < entries.count { loadFailure }
                        }
                        .padding(.horizontal, Self.inset - ComposerBookmarkRow.padding)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { rowsHeight = $0 }
                    }
                    // A definite height, rather than a flexible one, lets the popover shrink as
                    // rows are removed.
                    .frame(height: rowsHeight.map { min($0, Self.maxListHeight) })
                    .onChange(of: highlight.sequence) { _, sequence in
                        if let sequence { proxy.scrollTo(sequence) }
                    }
                }
            }
        }
        .padding(.vertical, Self.inset)
        .frame(width: Self.width)
        .animation(reduceMotion ? nil : .default, value: entries.map(\.sequence))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .down: highlight.move(by: 1, in: loaded)
            case .up: highlight.move(by: -1, in: loaded)
            default: break
            }
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            guard let sequence = highlight.sequence, loaded.contains(sequence) else { return .ignored }
            onReveal(sequence)
            return .handled
        }
        // The Mac's Delete and Forward Delete keys arrive as delete commands, not `KeyEquivalent.delete`.
        .onDeleteCommand {
            guard canRemove, let sequence = highlight.sequence, loaded.contains(sequence) else { return }
            remove(sequence, among: loaded)
        }
        .task(id: [store.bookmarkList.last?.sequence, loadAttempt]) {
            guard let oldest = store.bookmarkList.last?.sequence else { return }
            loadError = await store.loadHistory(through: oldest)
        }
    }

    private var loadFailure: some View {
        HStack {
            Text("Couldn't load older messages").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Try Again") {
                loadError = nil
                loadAttempt += 1
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(ComposerBookmarkRow.padding)
    }

    private func remove(_ sequence: Int, among sequences: [Int]) {
        highlight.remove(sequence, from: sequences)
        let store = store
        Task { await store.setBookmarked(false, sequence: sequence) }
    }

    /// The one highlight that the pointer and the arrow keys share, over the rows that have loaded.
    struct Highlight: Equatable {
        var sequence: Int?

        /// Like a menu, the first step down highlights the newest row and the first step up the
        /// oldest. After that each step moves one row, stopping at the ends.
        mutating func move(by offset: Int, in sequences: [Int]) {
            guard !sequences.isEmpty else { return }
            guard let index = sequence.flatMap(sequences.firstIndex) else {
                sequence = offset > 0 ? sequences.first : sequences.last
                return
            }
            sequence = sequences[max(0, min(index + offset, sequences.count - 1))]
        }

        /// Removing the highlighted row highlights the next one, or the previous one at the end.
        mutating func remove(_ removed: Int, from sequences: [Int]) {
            guard removed == sequence, let index = sequences.firstIndex(of: removed) else { return }
            let remaining = sequences.filter { $0 != removed }
            sequence = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
    }
}

/// One bookmark: its author, time and the first line of its message. The highlighted row trades
/// its time for a Remove button.
struct ComposerBookmarkRow: View {
    static let padding: CGFloat = 8
    static let avatarSize: CGFloat = 20

    let message: ChannelMessage
    let agents: [ChannelAgent]
    let preview: String
    let isHighlighted: Bool
    let canRemove: Bool
    let onHover: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let date = try? Date(message.timestamp, strategy: .iso8601)
        Button(action: onReveal) {
            HStack(alignment: .bookmarkNameLine, spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if let date {
                            Text(ChannelActivityTime.label(for: date, now: .now))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .opacity(isHighlighted ? 0 : 1)
                        }
                    }
                    .alignmentGuide(.bookmarkNameLine) { $0[VerticalAlignment.center] }
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerBookmarkRowStyle())
        .overlay(alignment: .topTrailing) {
            if isHighlighted {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
                .help("Remove Bookmark")
                .padding([.top, .trailing], Self.padding)
            }
        }
        .onHover { if $0 { onHover() } }
        .contextMenu {
            Button("Remove Bookmark", systemImage: "bookmark.slash", action: onRemove).disabled(!canRemove)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, date.map { ChannelActivityTime.spokenLabel(for: $0, now: .now) }, preview]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onReveal)
        .accessibilityActions {
            if canRemove { Button("Remove Bookmark", action: onRemove) }
        }
    }

    @ViewBuilder private var avatar: some View {
        if let agentId = message.sender.agentId {
            AgentAvatarView(agent: ChannelAgent(id: agentId, in: agents), size: Self.avatarSize)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
        }
    }

    private var name: String {
        message.sender.agentId.map { ChannelAgent(id: $0, in: agents).name } ?? "You"
    }
}

/// A row whose message hasn't loaded yet, at its final size and with no actions.
struct ComposerBookmarkPlaceholder: View {
    var body: some View {
        HStack(alignment: .bookmarkNameLine, spacing: 8) {
            Circle().fill(.quaternary)
                .frame(width: ComposerBookmarkRow.avatarSize, height: ComposerBookmarkRow.avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Name").font(.body.weight(.semibold)).hidden()
                    .overlay(alignment: .leading) { bar.frame(width: 72) }
                    .alignmentGuide(.bookmarkNameLine) { $0[VerticalAlignment.center] }
                Text(verbatim: "Preview").font(.callout).hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { bar.padding(.trailing, 48) }
            }
        }
        .padding(ComposerBookmarkRow.padding)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading bookmark")
    }

    private var bar: some View {
        Capsule().fill(.quaternary).frame(height: 10)
    }
}

/// Rows draw their own highlight, so pressing one doesn't dim it the way `.plain` does.
private struct ComposerBookmarkRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private extension VerticalAlignment {
    /// Centers a bookmark's avatar on its name's line rather than the whole row.
    enum BookmarkNameLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let bookmarkNameLine = VerticalAlignment(BookmarkNameLine.self)
}
