import ChannelClient
import SwiftUI

extension View {
    /// Drives the status slot's 300 ms delay and its announcements. Changing the query, closing
    /// Find or leaving the channel cancels both.
    public func transcriptFindStatusUpdates(
        _ find: TranscriptFind, progressDelayElapsed: Binding<Bool>,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) -> some View {
        modifier(TranscriptFindStatusUpdates(find: find, progressDelayElapsed: progressDelayElapsed,
                                             announce: announce))
    }
}

private struct TranscriptFindStatusUpdates: ViewModifier {
    let find: TranscriptFind
    @Binding var progressDelayElapsed: Bool
    let announce: @MainActor (String) -> Void
    @ViewState private var announcements = TranscriptFindAnnouncements()

    private struct Key: Equatable {
        let query: String
        let isSearching: Bool
        let error: String?
    }

    func body(content: Content) -> some View {
        content.task(id: Key(query: find.query, isSearching: find.isSearching, error: find.error)) {
            progressDelayElapsed = false
            guard find.hasQuery else { return }
            // Waiting also settles typing, so only the query the reader stops on is announced.
            try? await Task.sleep(for: TranscriptFindStatus.progressDelay)
            guard !Task.isCancelled else { return }
            progressDelayElapsed = true
            if let announcement = announcements.receive(find) { announce(announcement) }
        }
    }
}
