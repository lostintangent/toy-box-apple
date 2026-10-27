import AppIntents
import ChannelKit
import SwiftUI

extension View {
    /// Makes the channel the window's user activity, so Siri and Apple Intelligence know which
    /// channel "this" means while the window is main. AppKit makes the activity current then.
    func channelActivity(_ channelID: String, handoff: Bool) -> some View {
        // The element tells SwiftUI to update the activity when the window switches channels.
        userActivity(ChannelHandoff.activityType, element: channelID) { channelID, activity in
            activity.userInfo = ChannelHandoff(channelID: channelID).userInfo
            activity.requiredUserInfoKeys = [ChannelHandoff.channelIDKey]
            activity.isEligibleForHandoff = handoff
            activity.appEntityIdentifier = EntityIdentifier(for: ChannelEntity.self, identifier: channelID)
        }
    }
}
