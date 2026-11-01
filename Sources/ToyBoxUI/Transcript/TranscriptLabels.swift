import ChannelKit
import Foundation

extension TranscriptDivider {
    /// What VoiceOver reads for the divider: its day, then whether new messages start here.
    public func accessibilityLabel(now: Date = .now) -> String {
        [day.map { transcriptDayLabel($0, now: now) }, unread ? "New messages" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

extension ChannelMessage {
    /// What VoiceOver reads for the message row: who sent it and when, then whom it's to, its
    /// request and its delivery.
    public func accessibilityLabel(author: String, addressee: String? = nil, request: ChannelRequestState? = nil,
                                   delivery: String? = nil) -> String {
        [author, ChannelDates.date(timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp,
         addressee.map { "To \($0)" },
         request.map { $0 == .pending ? "Needs your reply" : "Replied" }, delivery]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
