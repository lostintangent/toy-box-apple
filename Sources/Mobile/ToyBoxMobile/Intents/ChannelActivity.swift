import AppIntents
import ToyBoxKit
import SwiftUI

/// What a channel screen shows: its conversation, or the artifact open over it. An image open over
/// it shows neither, so the screen names nothing to Siri then.
enum ScreenEntity: Hashable {
    case channel(ChannelTarget)
    case artifact(ChannelTarget, artifactID: String)

    var channel: ChannelTarget {
        switch self {
        case .channel(let channel), .artifact(let channel, _): channel
        }
    }

    var identifier: EntityIdentifier {
        switch self {
        case .channel(let channel):
            EntityIdentifier(for: ChannelEntity.self, identifier: channel.identifier)
        case .artifact(let channel, let artifactID):
            EntityIdentifier(for: ArtifactEntity.self,
                             identifier: ArtifactEntity.id(channelID: channel.channelID, artifactID: artifactID))
        }
    }
}

extension View {
    /// Makes the channel the scene's user activity for Handoff, and names what's on screen to Siri
    /// and Apple Intelligence. The activity carries only identifiers, and Siri reads the text
    /// through the entities' queries, so nothing reaches Spotlight or the activity itself.
    func channelActivity(_ channelID: String, showing entity: ScreenEntity?) -> some View {
        // The element tells SwiftUI to update the activity when the channel or what it shows changes.
        userActivity(ChannelHandoff.activityType, element: ChannelActivity(channelID: channelID, entity: entity)) { element, activity in
            activity.userInfo = ChannelHandoff(channelID: element.channelID).userInfo
            activity.requiredUserInfoKeys = [ChannelHandoff.channelIDKey]
            activity.isEligibleForHandoff = true
            activity.appEntityIdentifier = element.entity?.identifier
        }
    }
}

private struct ChannelActivity: Hashable {
    let channelID: String
    let entity: ScreenEntity?
}
