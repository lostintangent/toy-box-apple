import ChannelClient
import ChannelKit
import SwiftUI

/// Placeholder Overview inspector. The Overview owner replaces this with every section.
struct OverviewInspector: View {
    let store: ChannelStore

    var body: some View {
        List {
            if let state = store.state {
                Section("Purpose") { Text(state.channel.purpose ?? "No purpose set") }
                Section("Team") {
                    ForEach(state.agents) { agent in
                        Label { Text(agent.name) } icon: { AgentAvatarView(agent: agent, size: 20) }
                    }
                }
            }
        }
        .navigationTitle("Overview")
    }
}
