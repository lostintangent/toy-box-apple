import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// The channel's bookmarks, newest first. Opening it pages history back through the oldest bookmark,
/// so every row can preview its message. Tapping one shows its message, and swiping removes it.
struct TranscriptBookmarks: View {
    let store: ChannelStore
    let onReveal: (Int) -> Void
    @ViewState private var loadAttempt = 0
    @ViewState private var loadError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = store.bookmarkList
        let canRemove = store.phase.isConnected
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No Bookmarks", systemImage: "bookmark")
                } else {
                    List {
                        Section {
                            ForEach(entries) { entry in
                                if let message = entry.message {
                                    TranscriptBookmarkRow(message: message, agents: store.roster,
                                                          preview: entry.preview(agents: store.roster) ?? "",
                                                          canRemove: canRemove,
                                                          onReveal: { onReveal(entry.sequence) },
                                                          onRemove: { remove(entry.sequence) })
                                        .accessibilityIdentifier("bookmark-\(entry.sequence)")
                                } else {
                                    TranscriptBookmarkPlaceholder()
                                }
                            }
                            .listRowBackground(Color.clear)
                            if loadError != nil, entries.contains(where: { $0.message == nil }) {
                                loadFailure.listRowBackground(Color.clear)
                            }
                        }
                        // Separators only between rows, none above the first or below the last.
                        .listSectionSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel("Close Bookmarks")
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 240, idealHeight: 420)
        .animation(reduceMotion ? nil : .default, value: entries.map(\.sequence))
        .task(id: [entries.last?.sequence, loadAttempt]) {
            guard let oldest = store.bookmarkList.last?.sequence else { return }
            loadError = await store.loadHistory(through: oldest)
        }
    }

    private var loadFailure: some View {
        HStack {
            Text("Couldn't load older messages").foregroundStyle(ChannelInk.secondary)
            Spacer(minLength: 8)
            Button("Try Again") {
                loadError = nil
                loadAttempt += 1
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.subheadline)
    }

    private func remove(_ sequence: Int) {
        let store = store
        Task { await store.setBookmarked(false, sequence: sequence) }
    }
}

/// One bookmark: its author, time and the start of its message.
private struct TranscriptBookmarkRow: View {
    static let avatarSize: CGFloat = 28

    let message: ChannelMessage
    let agents: [ChannelAgent]
    let preview: String
    let canRemove: Bool
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let date = try? Date(message.timestamp, strategy: .iso8601)
        Button(action: onReveal) {
            HStack(alignment: .bookmarkNameLine, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        if let date {
                            Text(ChannelActivityTime.label(for: date, now: .now))
                                .font(.subheadline)
                                .foregroundStyle(ChannelInk.secondary)
                        }
                    }
                    .alignmentGuide(.bookmarkNameLine) { $0[VerticalAlignment.center] }
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(ChannelInk.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canRemove {
                Button("Remove", systemImage: "bookmark.slash", action: onRemove).tint(TranscriptBookmark.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, date.map { ChannelActivityTime.spokenLabel(for: $0, now: .now) }, preview]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
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

/// A row whose message hasn't loaded yet, at a loaded row's size and with no actions.
private struct TranscriptBookmarkPlaceholder: View {
    var body: some View {
        HStack(alignment: .bookmarkNameLine, spacing: 12) {
            Circle().fill(.quaternary)
                .frame(width: TranscriptBookmarkRow.avatarSize, height: TranscriptBookmarkRow.avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Name").font(.body.weight(.semibold)).hidden()
                    .overlay(alignment: .leading) { bar.frame(width: 88) }
                    .alignmentGuide(.bookmarkNameLine) { $0[VerticalAlignment.center] }
                Text(verbatim: "Preview").font(.subheadline).hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { bar.padding(.trailing, 48) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading bookmark")
    }

    private var bar: some View {
        Capsule().fill(.quaternary).frame(height: 10)
    }
}

private extension VerticalAlignment {
    /// Centers a bookmark's avatar on its name's line rather than the whole row.
    enum BookmarkNameLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let bookmarkNameLine = VerticalAlignment(BookmarkNameLine.self)
}
