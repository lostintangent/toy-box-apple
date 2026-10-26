import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewView: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if store.details != nil, store.phase != .deleted {
                    OverviewForm(store: store).id(ObjectIdentifier(store))
                } else {
                    ContentUnavailableView(
                        store.phase == .deleted ? "Channel Deleted" : "Connecting",
                        systemImage: store.phase == .deleted ? "trash" : "bubble.left.and.bubble.right",
                        description: Text(store.phase == .deleted
                                          ? "This channel is no longer available."
                                          : "Overview appears when the channel connects."))
                }
            }
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Channel Actions", systemImage: "ellipsis") {
                        Button("Edit Channel", systemImage: "pencil") {
                            management.present(.editChannel(channelId: store.id))
                        }
                        Button("Delete Channel", systemImage: "trash", role: .destructive) {
                            management.present(.deleteChannel(channelId: store.id))
                        }
                    }
                    .disabled(!store.phase.isLive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sizeClass == .compact {
                        Button("Done") { interaction.isInspectorPresented = false }
                    } else {
                        Button("Close Overview", systemImage: "xmark") { interaction.isInspectorPresented = false }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct OverviewForm: View {
    let store: ChannelStore
    @Environment(ChannelInteraction.self) private var interaction

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if !store.phase.isLive {
                    Section {
                        Label("Overview may be out of date. Reconnect before making changes.",
                              systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Reconnect", action: store.reconnect)
                    }
                }
                OverviewAboutSection(store: store)
                OverviewTeamSection(store: store)
                OverviewTasksSection(store: store).id("overview-tasks")
                OverviewArtifactsSection(store: store)
                OverviewRoutinesSection(store: store)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .task(id: interaction.overviewTasksRequest) {
                guard let token = interaction.overviewTasksRequest else { return }
                await Task.yield()
                guard interaction.overviewTasksRequest == token, !Task.isCancelled else { return }
                proxy.scrollTo("overview-tasks", anchor: .top)
                interaction.consumeOverviewTasksRequest(token)
            }
        }
    }
}
