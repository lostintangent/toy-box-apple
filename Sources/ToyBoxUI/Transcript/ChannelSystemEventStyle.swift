import ChannelKit
import SwiftUI

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
        case "artifact_removed": "minus.circle"
        case "routine_scheduled", "routine_edited", "routine_deleted": "calendar.badge.clock"
        default: "info.circle"
        }
    }

    public static func symbolColor(for type: String?, in colorScheme: ColorScheme) -> Color {
        type == "tasks_completed" ? ChannelTaskColors.changes(in: colorScheme).added : .secondary
    }
}
