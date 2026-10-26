import ChannelKit
import Foundation

public func transcriptDividerAccessibilityLabel(_ divider: TranscriptDivider, now: Date = .now) -> String {
    [divider.day.map { transcriptDayLabel($0, now: now) }, divider.unread ? "New messages" : nil]
        .compactMap { $0 }.joined(separator: ", ")
}

public func transcriptMessageAccessibilityLabel(author: String, timestamp: String, addressee: String? = nil,
                                                request: ChannelRequestState? = nil,
                                                delivery: String? = nil) -> String {
    [author, ChannelDates.date(timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp,
     addressee.map { "To \($0)" },
     request.map { $0 == .pending ? "Needs your reply" : "Replied" }, delivery]
        .compactMap { $0 }
        .joined(separator: ", ")
}
