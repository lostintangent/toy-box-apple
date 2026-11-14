import Foundation

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
