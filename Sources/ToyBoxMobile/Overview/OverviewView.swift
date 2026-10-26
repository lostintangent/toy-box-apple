import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct OverviewView: View {
    let store: ChannelStore
    @Bindable var session: OverviewSession
    let placement: OverviewPlacement
    @Environment(OverviewPresentation.self) private var presentation
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack(path: $session.navigationPath) {
            Group {
                if store.details != nil, store.phase != .deleted {
                    OverviewForm(store: store, session: session, placement: placement).id(ObjectIdentifier(store))
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
            .navigationDestination(for: String.self) { id in
                OverviewAgentDetails(agentID: id, store: store)
            }
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
                    .accessibilityIdentifier("overview-channel-actions")
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
        .sheet(item: Binding(
            get: { placement == presentation.placement ? management.flow : nil },
            set: { if placement == presentation.placement { management.flow = $0 } }
        )) { flow in
            ManagementSheet(flow: flow, presenter: management, host: placement)
        }
    }
}

private struct OverviewForm: View {
    let store: ChannelStore
    @Bindable var session: OverviewSession
    let placement: OverviewPlacement
    @Environment(OverviewPresentation.self) private var presentation
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
                OverviewAboutSection(store: store, session: session)
                OverviewTeamSection(store: store)
                OverviewTasksSection(store: store, session: session).id("overview-tasks")
                OverviewArtifactsSection(store: store)
                OverviewRoutinesSection(store: store, session: session)
            }
            .accessibilityIdentifier("overview-form")
            .scrollPosition(Binding(
                get: { session.scrollPosition },
                set: { if placement == presentation.placement { session.scrollPosition = $0 } }
            ))
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                if placement == presentation.placement, interaction.isInspectorPresented,
                   session.restorationOffset == nil {
                    session.scrollOffset = offset
                }
            }
            .onChange(of: store.tasks, initial: true) { _, tasks in session.reconcileTasks(tasks) }
            .task {
                await Task.yield()
                guard placement == presentation.placement, !Task.isCancelled else { return }
                session.restoreScroll()
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
