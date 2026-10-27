import ChannelClient
import SwiftUI

struct ChannelFollowAction: View {
    enum State: Equatable {
        case available, unavailable, starting, following

        var title: String {
            switch self {
            case .available, .unavailable: "Follow This Channel"
            case .starting: "Starting…"
            case .following: "Stop Following"
            }
        }

        var systemImage: String {
            self == .following ? "stop.circle" : "dot.radiowaves.left.and.right"
        }

        var isEnabled: Bool { self == .available || self == .following }
    }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(state.title, systemImage: state.systemImage, action: action)
            .disabled(!state.isEnabled)
    }
}

struct ChannelFollowMenuAction: View {
    let store: ChannelStore
    @Environment(ChannelFollowController.self) private var following

    var body: some View {
        ChannelFollowAction(state: following.state(for: store)) {
            if following.state(for: store) == .following {
                following.stop(channelID: store.id)
            } else {
                Task { await following.follow(store) }
            }
        }
    }
}
