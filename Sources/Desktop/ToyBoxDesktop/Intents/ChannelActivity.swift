import AppIntents
import ChannelKit
import SwiftUI

/// What a channel window shows: its conversation, or the artifact open over it. An image open over
/// it shows neither, so the window names nothing to Siri then.
enum ScreenEntity: Hashable {
    case channel(String)
    case artifact(channelID: String, artifactID: String)

    var channelID: String {
        switch self {
        case .channel(let id), .artifact(let id, _): id
        }
    }

    var identifier: EntityIdentifier {
        switch self {
        case .channel(let id):
            EntityIdentifier(for: ChannelEntity.self, identifier: id)
        case .artifact(let channelID, let artifactID):
            EntityIdentifier(for: ArtifactEntity.self, identifier: ArtifactEntity.id(channelID: channelID, artifactID: artifactID))
        }
    }
}

extension View {
    /// Makes the channel the window's user activity, and names what it shows to Siri and Apple
    /// Intelligence, so they know what "this" means while the window is main. AppKit makes the
    /// activity current then. The activity carries only identifiers, and Siri reads the text
    /// through the entities' queries, so nothing reaches Spotlight or the activity itself.
    func channelActivity(_ channelID: String, showing entity: ScreenEntity?, handoff: Bool) -> some View {
        // The element tells SwiftUI to update the activity when the channel or what it shows changes.
        userActivity(ChannelHandoff.activityType, element: ChannelActivity(channelID: channelID, entity: entity)) { element, activity in
            activity.userInfo = ChannelHandoff(channelID: element.channelID).userInfo
            activity.requiredUserInfoKeys = [ChannelHandoff.channelIDKey]
            activity.isEligibleForHandoff = handoff
            activity.appEntityIdentifier = element.entity?.identifier
        }
    }
}

private struct ChannelActivity: Hashable {
    let channelID: String
    let entity: ScreenEntity?
}
