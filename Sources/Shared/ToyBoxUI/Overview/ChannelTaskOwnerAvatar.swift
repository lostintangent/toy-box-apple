import ToyBoxKit
import SwiftUI

/// A task owner's avatar: an agent's avatar, or you drawn as bookmarks draw you. Rows speak the
/// owner in their own label, so the avatar stays hidden from accessibility.
public struct ChannelTaskOwnerAvatar: View {
    public let owner: ChannelTask.Owner
    public var size: CGFloat

    public init(owner: ChannelTask.Owner, size: CGFloat) {
        self.owner = owner
        self.size = size
    }

    public var body: some View {
        avatar
            .accessibilityHidden(true)
            #if os(macOS)
            .help(owner.help)
            #endif
    }

    @ViewBuilder private var avatar: some View {
        switch owner {
        case .you:
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        case .agent(let agent):
            AgentAvatarView(agent: agent, size: size)
        }
    }
}
