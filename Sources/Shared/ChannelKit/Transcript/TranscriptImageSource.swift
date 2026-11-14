import Foundation

/// The message whose images the Mac viewer and the phone gallery page through, and the words both
/// show for it.
public struct TranscriptImageSource: Equatable, Sendable {
    public var messageID: String
    public var sender: String
    public var timestamp: String

    public init(messageID: String, sender: String, timestamp: String) {
        self.messageID = messageID
        self.sender = sender
        self.timestamp = timestamp
    }

    public init(message: ChannelMessage, agents: [ChannelAgent]) {
        let sender = switch message.sender.type {
        case "user": "You"
        case "agent": agents.first { $0.id == message.sender.agentId }?.name ?? "Agent"
        default: "Toy Box"
        }
        self.init(messageID: message.id, sender: sender, timestamp: message.timestamp)
    }

    /// "Today at 5:23 PM · 2 of 4", without the position for a single image.
    public func subtitle(index: Int, count: Int, now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = subtitleParts(index: index, count: count, now: now, calendar: calendar)
        return [parts.sent, parts.position].compactMap(\.self).joined(separator: " · ")
    }

    public func subtitleParts(index: Int, count: Int, now: Date = .now,
                              calendar: Calendar = .current) -> (sent: String?, position: String?) {
        let sent = (try? Date(timestamp, strategy: .iso8601)).map { sentAt in
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                        calendar: calendar, timeZone: calendar.timeZone)
            return "\(TranscriptDivider.dayLabel(for: sentAt, now: now, calendar: calendar)) at \(sentAt.formatted(time))"
        }
        return (sent, count > 1 ? "\(index + 1) of \(count)" : nil)
    }

    /// "Image 2 of 4 from Lead, plan.png".
    public func accessibilityLabel(for image: ChannelAttachment, index: Int, count: Int) -> String {
        let position = count > 1 ? " \(index + 1) of \(count)" : ""
        let filename = image.filename.map { ", \($0)" } ?? ""
        return "Image\(position) from \(sender)\(filename)"
    }
}
