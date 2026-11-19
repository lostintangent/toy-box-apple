import SwiftUI

/// Takes the wake countdown's place while a waiting agent's wake command runs, since its exit wakes the
/// agent first unless the agent checks again before then.
package struct ChannelAgentWakeCommand: View {
    package static let spoken = "wakes when its command exits"

    package init() {}

    package var body: some View {
        Image(systemName: "terminal").foregroundStyle(ChannelInk.secondary)
    }
}
