import ChannelClient
import ChannelKit
import SwiftUI

/// Placeholder transcript. The Transcript owner replaces this with the canonical row projection.
struct ConversationTranscript: View {
    let store: ChannelStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let state = store.state {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.hasOlderMessages {
                        Button(store.isLoadingOlder ? "Loading..." : "Load Older Messages") {
                            Task { await store.loadOlder() }
                        }
                        .disabled(store.isLoadingOlder)
                    }
                    ForEach(state.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(author(message, in: state)).font(.subheadline.weight(.semibold))
                            Text(message.isSystem ? message.system?.type ?? "Channel updated" : message.text)
                                .textSelection(.enabled)
                        }
                        .opacity(store.optimisticMessageIds.contains(message.id) ? 0.55 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onAppear {
                            if scenePhase == .active {
                                Task { await store.markRead(through: message.sequence) }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        } else if store.phase == .deleted {
            ContentUnavailableView("Channel Deleted", systemImage: "bubble.left",
                                   description: Text("This channel is no longer available."))
        } else {
            ProgressView("Connecting...").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func author(_ message: ChannelMessage, in state: ChannelState) -> String {
        if message.sender.type == "user" { return "You" }
        if message.isSystem { return "Channel" }
        return channelAgentIdentity(state.agents, id: message.sender.agentId ?? "").name
    }
}
