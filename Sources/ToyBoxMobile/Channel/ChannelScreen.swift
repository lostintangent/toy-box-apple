import ChannelClient
import ChannelKit
import SwiftUI
import TipKit
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
    @Environment(\.usesVerticalToolbar) private var usesVerticalToolbar
    @ViewState private var keyboardIsVisible = false
    @ViewState private var permissionTipIsAvailable = false
    private let permissionTip = NotificationPermissionTip()

    private var reader: ChannelReaderVisibility {
        ChannelReaderVisibility(
            artifactRequested: artifacts.isPresented,
            imageRequested: gallery.session != nil,
            compactOverviewRequested: sizeClass == .compact && interaction.isInspectorPresented,
            compactOverviewPresented: overview.isCompactSheetPresented
        )
    }

    private var showsPermissionTip: Bool {
        permissionTipIsAvailable && model.notifications.canOfferPermissionTip
            && model.visibleChannelID == store.id
            && !store.phase.isUnavailable && store.requestSequence != nil && !model.isSettingsPresented
            && management.flow == nil && !reader.requested && !overview.isCompactSheetPresented
            && !(sizeClass == .compact && interaction.isInspectorPresented)
            && !interaction.isRequestPreviewPresented && !keyboardIsVisible
            && !model.composerSession(for: store).editor.isFocused
    }

    /// With no vertical bar, a compact `.bottomBar` would sit under the composer, so Message View
    /// moves into Channel Actions and a filtered transcript names itself under the title instead.
    private var messageViewIsInActions: Bool { sizeClass == .compact && !usesVerticalToolbar }

    var body: some View {
        ZStack {
            conversation
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
            .softwareKeyboardVisibility($keyboardIsVisible)
            .safeAreaBar(edge: .top, spacing: 0) {
                if showsPermissionTip {
                    TipView(permissionTip) { _ in
                        permissionTip.invalidate(reason: .actionPerformed)
                        Task { await model.notifications.enable() }
                    }
                    .padding(.horizontal, sizeClass == .compact ? 16 : 20)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(store.details?.name ?? model.catalog?.channels.first { $0.id == store.id }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .background {
                if messageViewIsInActions && interaction.messageView == .yours && !reader.requested {
                    Color.clear.navigationSubtitle("Your Messages")
                }
            }
            .task(id: model.notifications.tipsAvailable) {
                guard model.notifications.tipsAvailable else { return }
                for await available in permissionTip.shouldDisplayUpdates {
                    permissionTipIsAvailable = available
                }
            }
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
            .toolbar {
                if !reader.requested { conversationToolbar }
            }
    }

    @ViewBuilder
    private var conversation: some View {
        Group {
            if store.phase == .deleted {
                DeletedChannelView(draft: model.composerSession(for: store).draft) {
                    model.selectedChannelID = nil
                }
            } else {
                ConversationView(store: store)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        if !interaction.isFinding {
                            ComposerView(store: store).findSwapTransition()
                        }
                    }
            }
        }
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        if sizeClass == .compact {
            ToolbarItemGroup(placement: .primaryAction) {
                overviewButton
                tasksButton
            }
            if !messageViewIsInActions {
                ToolbarItem(placement: .bottomBar) {
                    messageView
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                messageView
                tasksButton
                overviewButton
            }
        }
        ToolbarOverflowMenu {
            channelActions
        }
    }

    private var messageView: some View {
        Menu("Message View", systemImage: "line.3.horizontal.decrease") {
            messageViewPicker
        }
    }

    private var messageViewPicker: some View {
        @Bindable var interaction = interaction
        return Picker("Message View", selection: $interaction.messageView) {
            Label("All Messages", systemImage: "bubble.left.and.bubble.right").tag(TranscriptView.all)
            Label("Your Messages", systemImage: "person").tag(TranscriptView.yours)
        }
        .disabled(store.phase == .deleted)
    }

    @ViewBuilder
    private var channelActions: some View {
        if messageViewIsInActions {
            Section("Message View") {
                messageViewPicker
            }
        }
        Button("Find in Conversation", systemImage: "magnifyingglass") {
            interaction.findInChannel()
        }
        .disabled(store.phase == .deleted)
        ChannelFollowMenuAction(store: store)
        Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
            model.openInToyBox(channelID: store.id)
        }
        .disabled(store.phase == .deleted)
        Divider()
        Button("Edit Channel", systemImage: "pencil") {
            management.present(.editChannel(channelId: store.id))
        }
        .disabled(!store.phase.isConnected)
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(channelId: store.id))
        }
        .disabled(!store.phase.isConnected)
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

extension EnvironmentValues {
    /// Whether bar items stand in the system's vertical bar, as on the folded iPhone Duo. iOS 27.0 has none.
    var usesVerticalToolbar: Bool {
        if #available(iOS 27.1, *) { toolbarVerticalEdge != nil } else { false }
    }
}
