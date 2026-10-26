import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelScreen: View {
    let store: ChannelStore
    @Environment(AppModel.self) private var model
    @Environment(ChannelInteraction.self) private var interaction
    @Environment(ManagementPresenter.self) private var management

    var body: some View {
        @Bindable var interaction = interaction
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
            .navigationTitle(store.details?.name ?? model.catalog?.channels.first { $0.id == store.id }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.visibleChannelID = store.id }
            .onChange(of: store.id) { _, id in model.visibleChannelID = id }
            .onChange(of: store.phase, initial: true) { _, phase in
                if phase == .deleted { interaction.isInspectorPresented = false }
            }
            .onDisappear {
                if model.visibleChannelID == store.id { model.visibleChannelID = nil }
            }
            .focusedValue(\.channelRefresh, model.isActive && store.phase != .deleted ? {
                store.reconnect()
            } : nil)
            .toolbar {
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
            .inspector(isPresented: $interaction.isInspectorPresented) {
                ContentUnavailableView("Overview", systemImage: "sidebar.trailing",
                                       description: Text("Overview is being built."))
                    .inspectorColumnWidth(min: 280, ideal: 296, max: 360)
            }
    }
}
