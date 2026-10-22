import ChannelClient
import ChannelKit
import SwiftUI

/// The detail column for one channel: transcript, docked composer and tray, and the Overview
/// inspector. It owns the store's connection lifetime and the window's channel interaction.
struct ChannelDetailView: View {
    let store: ChannelStore
    @ViewState private var interaction = ChannelInteraction()

    var body: some View {
        ConversationTranscript(store: store)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerArea(store: store)
            }
            .inspector(isPresented: $interaction.isInspectorPresented) {
                OverviewInspector(store: store)
                    .inspectorColumnWidth(min: 280, ideal: 312, max: 400)
            }
            .navigationTitle(store.state?.channel.name ?? "Channel")
            .toolbar {
                Button("Overview", systemImage: "sidebar.trailing") {
                    interaction.isInspectorPresented.toggle()
                }
            }
            .environment(interaction)
            .task { store.captureUnreadBoundary(); store.connect() }
            .onDisappear { store.disconnect() }
    }
}
