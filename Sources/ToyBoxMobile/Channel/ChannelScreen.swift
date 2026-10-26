import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelScreen: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management
    @Environment(ChannelArtifactSession.self) private var artifacts
    @Environment(TranscriptGalleryPresenter.self) private var gallery
    @Environment(OverviewPresentation.self) private var overview
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var minimumTrayHeight: CGFloat = 660
    @ViewState private var usableHeight: CGFloat = 0

    private var reader: ChannelReaderVisibility {
        ChannelReaderVisibility(
            artifactRequested: artifacts.isPresented,
            imageRequested: gallery.session != nil,
            compactOverviewRequested: sizeClass == .compact && interaction.isInspectorPresented,
            compactOverviewPresented: overview.isCompactSheetPresented
        )
    }

    var body: some View {
        let showsTray = Self.showsTray(usableHeight: usableHeight, minimumHeight: minimumTrayHeight)
        ZStack {
            conversation(showsTray: showsTray)
                .opacity(reader.isVisible ? 0 : 1)
                .allowsHitTesting(!reader.requested)
                .accessibilityHidden(reader.requested)
            if reader.isVisible {
                if artifacts.isPresented {
                    ArtifactViewer(session: artifacts)
                } else {
                    TranscriptImageGallery(presenter: gallery)
                }
            }
        }
            .background {
                // Measuring behind the keyboard must not opt the composer out of avoidance.
                GeometryReader { geometry in
                    #if DEBUG
                    let mode = showsTray ? "shown" : "hidden"
                    let measurement = "Usable height \(geometry.size.height), minimum \(max(660, minimumTrayHeight)), tray \(mode)"
                    #endif
                    Color.clear
                        .onChange(of: geometry.size.height, initial: true) { _, height in
                            usableHeight = height
                        }
                        #if DEBUG
                        .accessibilityElement()
                        .accessibilityLabel("Conversation layout")
                        .accessibilityValue(Text(verbatim: measurement))
                        .accessibilityHidden(ProcessInfo.processInfo.environment["TOY_BOX_AUTOMATION_SCRIPT"] == nil)
                        #endif
                }
                .ignoresSafeArea(.keyboard)
            }
            .navigationTitle(store.details?.name ?? model.catalog?.channels.first { $0.id == store.id }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.visibleChannelID = store.id }
            .onChange(of: store.id) { _, id in model.visibleChannelID = id }
            .onChange(of: store.artifacts, initial: true) { _, current in
                artifacts.configure(api: store.api, channelID: store.id, artifacts: current)
            }
            .onChange(of: artifacts.isPresented, initial: true) { _, presented in
                if presented, artifacts.isPresented { gallery.close() }
            }
            .onChange(of: gallery.session?.id, initial: true) { _, id in
                if id != nil, gallery.session?.id == id { artifacts.close() }
            }
            .onChange(of: reader.requested, initial: true) { _, requested in
                interaction.isArtifactViewerPresented = requested
                if requested, sizeClass == .compact { interaction.isInspectorPresented = false }
            }
            .onChange(of: store.phase, initial: true) { _, phase in
                if phase == .deleted {
                    artifacts.close()
                    gallery.close()
                    interaction.isInspectorPresented = false
                }
            }
            .onDisappear {
                interaction.isArtifactViewerPresented = false
                if model.visibleChannelID == store.id { model.visibleChannelID = nil }
            }
            .focusedValue(\.channelRefresh,
                           model.isActive && store.phase != .deleted && !reader.requested ? .channel(store) : nil)
            .toolbar {
                if !reader.requested { conversationToolbar(showsTray: showsTray) }
            }
    }

    static func showsTray(usableHeight: CGFloat, minimumHeight: CGFloat) -> Bool {
        usableHeight >= max(660, minimumHeight)
    }

    @ViewBuilder
    private func conversation(showsTray: Bool) -> some View {
        Group {
            if store.phase == .deleted {
                DeletedChannelView(draft: model.composerSession(for: store).draft) {
                    model.selectedChannelID = nil
                }
            } else {
                ConversationView(store: store)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        ComposerView(store: store, showsTray: showsTray)
                    }
            }
        }
    }

    @ToolbarContentBuilder
    private func conversationToolbar(showsTray: Bool) -> some ToolbarContent {
        if sizeClass == .compact {
            ToolbarItemGroup(placement: .primaryAction) {
                overviewButton
                if !showsTray { tasksButton }
                channelActions
            }
            ToolbarItem(placement: .bottomBar) {
                messageView
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                messageView
                channelActions
                if !showsTray { tasksButton }
                overviewButton
            }
        }
    }

    private var messageView: some View {
        @Bindable var interaction = interaction
        return Menu("Message View", systemImage: "line.3.horizontal.decrease") {
            Picker("Message View", selection: $interaction.messageView) {
                Text("All Messages").tag(TranscriptView.all)
                Text("Your Messages").tag(TranscriptView.yours)
            }
            .disabled(store.phase == .deleted)
        }
    }

    private var channelActions: some View {
        Menu("Channel Actions", systemImage: "ellipsis") {
            Button("Find in Conversation", systemImage: "magnifyingglass") {
                interaction.findInChannel()
            }
            .disabled(store.phase == .deleted)
            Button("Refresh", systemImage: "arrow.clockwise") { store.reconnect() }
                .disabled(!model.isActive || store.phase == .deleted)
            Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
                model.openInToyBox(channelID: store.id)
            }
            .disabled(store.phase == .deleted)
            Divider()
            Button("Edit Channel", systemImage: "pencil") {
                management.present(.editChannel(channelId: store.id))
            }
            .disabled(!store.phase.isLive)
            Button("Delete Channel", systemImage: "trash", role: .destructive) {
                management.present(.deleteChannel(channelId: store.id))
            }
            .disabled(!store.phase.isLive)
        }
    }

    private var overviewButton: some View {
        Button("Overview", systemImage: "sidebar.trailing") {
            interaction.isInspectorPresented.toggle()
        }
        .disabled(store.phase == .deleted)
    }

    @ViewBuilder
    private var tasksButton: some View {
        let progress = channelTasksProgress(store.tasks)
        if progress.done < progress.total {
            Button("Tasks", systemImage: "checklist") {
                interaction.showOverviewTasks()
            }
            .accessibilityLabel("Tasks, \(progress.done) of \(progress.total) done")
            .accessibilityIdentifier("channel-tasks")
            .disabled(store.phase == .deleted)
        }
    }
}

struct ChannelReaderVisibility {
    let artifactRequested: Bool
    let imageRequested: Bool
    let compactOverviewRequested: Bool
    let compactOverviewPresented: Bool

    var requested: Bool { artifactRequested || imageRequested }

    var isVisible: Bool {
        requested && !compactOverviewRequested && !compactOverviewPresented
    }
}
