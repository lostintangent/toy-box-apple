import ChannelKit
import SwiftUI

/// One message's reactions, grouped by kind in first-seen order.
public struct ChannelReactionGroup: Equatable {
    public let reaction: String
    public let agents: [ChannelAgent]

    /// The kind's emoji and the words VoiceOver and the reactors list use for it.
    public var presentation: (emoji: String, label: String) {
        switch reaction {
        case "looking": ("\u{1f440}", "Looking")
        case "working": ("\u{1f3c3}", "In progress")
        case "done": ("\u{2705}", "Done")
        case "agree": ("\u{1f44d}", "Agreed")
        case "celebrate": ("\u{1f389}", "Celebrated")
        case "love": ("\u{2764}\u{fe0f}", "Loved this")
        case "laugh": ("\u{1f602}", "Laughed")
        default: ("\u{2022}", reaction)
        }
    }

    /// A message's own reactions plus the looking and working reactions agents' statuses put on it.
    public static func groups(for message: ChannelMessage, agents: [ChannelAgent],
                              statusReactions: [ChannelReaction] = []) -> [ChannelReactionGroup] {
        var order: [String] = []
        var grouped: [String: [ChannelAgent]] = [:]
        for entry in channelMessageReactions(message, status: [message.sequence: statusReactions]) {
            if grouped[entry.reaction] == nil { order.append(entry.reaction) }
            grouped[entry.reaction, default: []].append(channelAgentIdentity(agents, id: entry.agentId))
        }
        return order.map { ChannelReactionGroup(reaction: $0, agents: grouped[$0] ?? []) }
    }
}

public enum ChannelSystemEventStyle {
    /// The symbol that leads an event's sentence, which a catch-up line from that event shares.
    public static func symbol(for type: String?) -> String {
        switch type {
        case "tasks_completed": "checkmark.circle.fill"
        case "member_joined": "person.badge.plus"
        case "member_left": "person.badge.minus"
        case "channel_renamed", "channel_purpose_changed": "pencil"
        case "channel_directory_changed": "folder"
        case "preview_changed": "play.rectangle"
        case "artifact_shared": "doc.badge.arrow.up"
        case "routine_scheduled", "routine_edited", "routine_deleted": "calendar.badge.clock"
        default: "info.circle"
        }
    }

    public static func symbolColor(for type: String?, in colorScheme: ColorScheme) -> Color {
        type == "tasks_completed" ? ChannelTaskColors.changes(in: colorScheme).added : .secondary
    }
}
