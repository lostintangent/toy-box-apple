import SwiftUI

private typealias ViewState = SwiftUI.State

/// What Find's one status slot shows: nothing for an empty query, then blank, a spinner while
/// older history is still being searched, and a result only once the search is complete.
public enum TranscriptFindStatus: Equatable {
    case hidden
    case blank
    case progress
    case result(String)
    case incomplete(error: String)

    public static let progressDelay = Duration.milliseconds(300)
}

extension TranscriptFind {
    public var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func status(progressDelayElapsed: Bool) -> TranscriptFindStatus {
        guard hasQuery else { return .hidden }
        if let error { return .incomplete(error: error) }
        if isSearching { return progressDelayElapsed ? .progress : .blank }
        return .result(countLabel)
    }

    public var partialCountLabel: String {
        switch matches.count {
        case 0: "No matches found so far"
        case 1: "1 match found so far"
        default: "\(matches.count) matches found so far"
        }
    }

    /// Spoken after Previous or Next, so a partial result never sounds final.
    public var navigationAnnouncement: String {
        guard let selectedIndex else { return countLabel.isEmpty ? partialCountLabel : countLabel }
        let position = "\(selectedIndex + 1) of \(matches.count)"
        if isSearching { return "\(position) found so far, still searching" }
        if error != nil { return "\(position) found so far, search incomplete" }
        return position
    }

    var outcomeAnnouncement: String {
        if error != nil { return "Couldn't search older messages. \(partialCountLabel)" }
        switch matches.count {
        case 0: return "No matches"
        case 1: return "1 match"
        default: return "\(matches.count) matches"
        }
    }
}

/// One delayed progress announcement and one outcome per query, never one per older page.
/// Retry re-arms the outcome, since it answers a new attempt.
public struct TranscriptFindAnnouncements: Equatable {
    private var query: String?
    private var announcedProgress = false
    private var announcedOutcome = false

    public init() {}

    @MainActor public mutating func receive(_ find: TranscriptFind) -> String? {
        guard find.hasQuery else { return nil }
        if query != find.query { self = .init(); query = find.query }
        if find.isSearching {
            announcedOutcome = false
            guard !announcedProgress else { return nil }
            announcedProgress = true
            return "Searching older messages"
        }
        guard !announcedOutcome else { return nil }
        announcedOutcome = true
        return find.outcomeAnnouncement
    }
}

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
