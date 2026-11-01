import ChannelClient
import SwiftUI

struct ChannelFollowAction: View {
    enum State: Equatable {
        enum Reason: Equatable {
            case deleted, unreachable, noTasksInProgress, pushNotSetUp

            var explanation: String {
                switch self {
                case .deleted: "Channel was deleted"
                case .unreachable: "Channel can't be reached"
                case .noTasksInProgress: "No tasks in progress"
                case .pushNotSetUp: "Push notifications couldn't be set up"
                }
            }
        }

        case available, unavailable(Reason?), starting, following

        var title: String {
            switch self {
            case .available, .unavailable: "Follow This Channel"
            case .starting: "Starting…"
            case .following: "Stop Following"
            }
        }

        var reason: Reason? {
            if case let .unavailable(reason) = self { reason } else { nil }
        }

        var systemImage: String {
            self == .following ? "stop.circle" : "dot.radiowaves.left.and.right"
        }

        var isEnabled: Bool { self == .available || self == .following }
    }

    let state: State
    let action: () -> Void

    var body: some View {
        if let reason = state.reason {
            Section(reason.explanation) {
                followButton
                    .accessibilityLabel("\(state.title), \(reason.explanation)")
            }
        } else {
            followButton
        }
    }

    private var followButton: some View {
        Button(action: action) {
            Label(state.title, systemImage: state.systemImage)
        }
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
