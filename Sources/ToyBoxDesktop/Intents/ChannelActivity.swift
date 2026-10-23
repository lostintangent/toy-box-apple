import AppIntents
import SwiftUI

extension View {
    /// Makes the channel the window's user activity, so Siri and Apple Intelligence know which
    /// channel "this" means while the window is main. AppKit makes the activity current then.
    func channelActivity(_ channelID: String) -> some View {
        // The element tells SwiftUI to update the activity when the window switches channels.
        userActivity("dev.toybox.channels.channel", element: channelID) { channelID, activity in
            // Another device can't open a channel from here, so the activity is only onscreen context.
            activity.isEligibleForHandoff = false
            activity.appEntityIdentifier = EntityIdentifier(for: ChannelEntity.self, identifier: channelID)
        }
    }
}
