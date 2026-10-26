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
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: OverviewRoute.self) { route in
                switch route {
                case .agent(let id):
                    OverviewAgentDetails(agentID: id, store: store)
                case .subtasks(let id):
                    OverviewSubtasksScreen(parentID: id, store: store, session: session,
                                           placement: placement, scroll: session.taskScroll(id))
                }
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
        .onChange(of: interaction.overviewTasksRequest, initial: true) { _, request in
            if request != nil, placement == presentation.placement {
                session.prepareForTaskReveal()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            OverviewList {
                if !store.phase.isLive {
                    Section {
                        Label("Overview may be out of date. Reconnect before making changes.",
                              systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(ChannelInk.secondary)
                        Button("Reconnect", action: store.reconnect)
                    }
                }
                OverviewAboutSection(store: store, session: session)
                OverviewTeamSection(store: store, session: session)
                OverviewTasksSection(store: store, session: session)
                OverviewArtifactsSection(store: store, session: session)
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
            .onChange(of: store.tasks, initial: true) { _, tasks in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { session.reconcileTasks(tasks) }
            }
            .onDisappear { session.prepareForPresentation() }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .task(id: interaction.overviewTasksRequest) {
                let request = interaction.overviewTasksRequest
                await Task.yield()
                guard placement == presentation.placement, !Task.isCancelled,
                      interaction.overviewTasksRequest == request else { return }
                if let request {
                    session.prepareForTaskReveal()
                    proxy.scrollTo("overview-tasks", anchor: .top)
                    interaction.consumeOverviewTasksRequest(request)
                } else {
                    session.restoreScroll()
                }
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
