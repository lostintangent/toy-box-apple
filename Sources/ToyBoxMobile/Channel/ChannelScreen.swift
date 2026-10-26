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
    @Environment(OverviewPresentation.self) private var overview
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var reader: ChannelReaderVisibility {
        ChannelReaderVisibility(
            requested: artifacts.isPresented,
            compactOverviewRequested: sizeClass == .compact && interaction.isInspectorPresented,
            compactOverviewPresented: overview.isCompactSheetPresented
        )
    }

    var body: some View {
        ZStack {
            conversation
                .opacity(reader.isVisible ? 0 : 1)
                .allowsHitTesting(!reader.requested)
                .accessibilityHidden(reader.requested)
            if reader.isVisible {
                ArtifactViewer(session: artifacts)
            }
        }
            .navigationTitle(store.details?.name ?? model.catalog?.channels.first { $0.id == store.id }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.visibleChannelID = store.id }
            .onChange(of: store.id) { _, id in model.visibleChannelID = id }
            .onChange(of: store.artifacts, initial: true) { _, current in
                artifacts.configure(api: store.api, channelID: store.id, artifacts: current)
            }
            .onChange(of: reader.requested, initial: true) { _, requested in
                interaction.isArtifactViewerPresented = requested
                if requested, sizeClass == .compact { interaction.isInspectorPresented = false }
            }
            .onChange(of: store.phase, initial: true) { _, phase in
                if phase == .deleted {
                    artifacts.close()
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
                        ComposerView(store: store)
                    }
            }
        }
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        @Bindable var interaction = interaction
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Message View", systemImage: "line.3.horizontal.decrease") {
                Picker("Message View", selection: $interaction.messageView) {
                    Text("All Messages").tag(TranscriptView.all)
                    Text("Your Messages").tag(TranscriptView.yours)
                }
                .disabled(store.phase == .deleted)
            }
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
            Button("Overview", systemImage: "sidebar.trailing") {
                interaction.isInspectorPresented.toggle()
            }
            .disabled(store.phase == .deleted)
        }
    }
}

struct ChannelReaderVisibility {
    let requested: Bool
    let compactOverviewRequested: Bool
    let compactOverviewPresented: Bool

    var isVisible: Bool {
        requested && !compactOverviewRequested && !compactOverviewPresented
    }
}
