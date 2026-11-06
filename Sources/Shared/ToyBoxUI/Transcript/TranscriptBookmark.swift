import ChannelClient
import SwiftUI

/// A message's bookmark and how to change it. Two compare equal when what they show does, since a
/// change only calls back into the store, so a row redraws only when its own bookmark changes.
public struct TranscriptBookmark: Equatable {
    public let isBookmarked: Bool
    /// False while the channel isn't connected, like Send. The mark itself stays.
    public let isEnabled: Bool
    private let change: @MainActor (Bool) -> Void

    public init(isBookmarked: Bool, isEnabled: Bool = true, change: @escaping @MainActor (Bool) -> Void) {
        self.isBookmarked = isBookmarked
        self.isEnabled = isEnabled
        self.change = change
    }

    /// The bookmark of `sequence` in `store`, or nil when its server predates bookmarks.
    @MainActor
    public init?(sequence: Int, bookmarks: Set<Int>?, isConnected: Bool, store: ChannelStore) {
        guard let bookmarks else { return nil }
        self.init(isBookmarked: bookmarks.contains(sequence), isEnabled: isConnected) { [weak store] bookmarked in
            Task { await store?.setBookmarked(bookmarked, sequence: sequence) }
        }
    }

    @MainActor public func toggle() { change(!isBookmarked) }

    /// Toggles from an accessibility action, which announces the result once since the label carries it.
    @MainActor public func toggleAnnouncing() {
        guard isEnabled else { return }
        toggle()
        AccessibilityNotification.Announcement(isBookmarked ? "Bookmark removed" : "Bookmarked").post()
    }

    /// What toggling does, for menus, help and accessibility actions.
    public var actionTitle: String { isBookmarked ? "Remove Bookmark" : "Bookmark" }
    public var actionSymbol: String { isBookmarked ? "bookmark.slash" : "bookmark" }
    /// The extra room above a bookmarked follow-up, which has no header, so its chip or mark clears
    /// the message above the way Messages makes room for a tapback. With the entry gap it's a run's.
    public var followUpInset: CGFloat { isBookmarked ? TranscriptSpacing.run - TranscriptSpacing.entry : 0 }
    /// The system blue of the New divider's label, which only the bookmarked state wears.
    public static let ink = Color.blue

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isBookmarked == rhs.isBookmarked && lhs.isEnabled == rhs.isEnabled
    }
}

extension View {
    /// The one alert for a bookmark change the server refused, which the store has already undone.
    /// It observes the error in its own view, so a change never redraws the transcript.
    public func transcriptBookmarkAlert(_ store: ChannelStore) -> some View {
        background { TranscriptBookmarkAlert(store: store) }
    }
}

private struct TranscriptBookmarkAlert: View {
    let store: ChannelStore
    /// The last failure, kept while the alert animates away so its title doesn't change under it.
    @ViewState private var shown: ChannelStore.BookmarkFailure?

    var body: some View {
        Color.clear
            .alert(shown?.isRemoval == true ? "Couldn't Remove Bookmark" : "Couldn't Bookmark Message",
                   isPresented: Binding(
                get: { store.bookmarkFailure != nil },
                set: { if !$0 { store.dismissBookmarkFailure() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shown?.error ?? "")
            }
            .onChange(of: store.bookmarkFailure, initial: true) { _, failure in
                if let failure { shown = failure }
            }
            .accessibilityHidden(true)
    }
}
