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

    var body: some View {
        NavigationStack(path: $session.navigationPath) {
            Group {
                if store.details != nil, store.phase != .deleted {
                    OverviewContent(store: store, session: session, placement: placement).id(ObjectIdentifier(store))
                } else {
                    ContentUnavailableView(
                        store.phase == .deleted ? "Channel Deleted" : "Connecting",
                        systemImage: store.phase == .deleted ? "trash" : "bubble.left.and.bubble.right",
                        description: Text(store.phase == .deleted
                                          ? "This channel is no longer available."
                                          : "Overview appears when the channel connects."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(placement == .sheet ? .visible : .hidden, for: .navigationBar)
            .toolbar { closeItem }
            .navigationDestination(for: OverviewRoute.self) { route in
                Group {
                    switch route {
                    case .agent(let id):
                        OverviewAgentDetails(agentID: id, store: store)
                    case .subtasks(let id):
                        OverviewSubtasksScreen(parentID: id, store: store, session: session)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar { closeItem }
            }
        }
        .sheet(item: Binding(
            get: { placement == presentation.placement ? management.flow : nil },
            set: { if placement == presentation.placement { management.flow = $0 } }
        )) { flow in
            ManagementSheet(flow: flow, presenter: management, host: placement)
        }
        .onChange(of: interaction.overviewTasksRequest, initial: true) { _, request in
            if request != nil, placement == presentation.placement {
                session.prepareForTaskReveal()
            }
        }
    }

    /// The sheet's system close button. The landscape column has none, because the channel's
    /// Overview button closes it, like the sidebar.
    @ToolbarContentBuilder
    private var closeItem: some ToolbarContent {
        if placement == .sheet {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close Overview", systemImage: "xmark", role: .close) {
                    interaction.isInspectorPresented = false
                }
            }
        }
    }
}

private struct OverviewContent: View {
    let store: ChannelStore
    @Bindable var session: OverviewSession
    let placement: OverviewPlacement
    @Environment(OverviewPresentation.self) private var presentation
    @Environment(ChannelInteraction.self) private var interaction

    var body: some View {
        ScrollViewReader { proxy in
            OverviewList {
                if store.phase.isUnavailable {
                    Section {
                        Label("Overview may be out of date until the channel connects.",
                              systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(ChannelInk.secondary)
                        // The sheet covers the transcript banner, so it carries the banner's Retry.
                        if placement == .sheet, store.phase != .deleted {
                            Button("Retry", action: store.reconnect)
                        }
                    }
                }
                OverviewAboutSection(store: store, session: session)
                OverviewTeamSection(store: store, session: session)
                OverviewTasksSection(store: store, session: session)
                OverviewArtifactsSection(store: store, session: session)
                OverviewRoutinesSection(store: store, session: session)
            }
            .accessibilityIdentifier("overview-form")
            .onChange(of: store.tasks, initial: true) { _, tasks in session.reconcileTasks(tasks) }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .task(id: interaction.overviewTasksRequest) {
                guard let request = interaction.overviewTasksRequest else { return }
                await Task.yield()
                guard placement == presentation.placement, !Task.isCancelled,
                      interaction.overviewTasksRequest == request else { return }
                session.prepareForTaskReveal()
                proxy.scrollTo("overview-tasks", anchor: .top)
                interaction.consumeOverviewTasksRequest(request)
            }
        }
    }
}

struct OverviewList<Content: View>: View {
    let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        List {
            content
                .listRowInsets(.horizontal, sizeClass == .regular ? 20 : 16)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(0)
        .listSectionMargins(.vertical, 0)
        .listSectionMargins(.horizontal, 0)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }
}
