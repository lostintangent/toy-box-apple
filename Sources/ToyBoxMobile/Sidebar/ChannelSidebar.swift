import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Binding var showsSettings: Bool
    let searchFocusRequest: UUID
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var channels: [Channel] {
        (model.catalog?.channels ?? []).filter { channelMatchesQuery($0, query: trimmedQuery) }
    }

    private var connection: SidebarConnection { model.sidebarConnection }

    private var initialLoading: Bool {
        model.catalog != nil && connection == .connecting
    }

    private var busy: Bool {
        guard let catalog = model.catalog else { return false }
        return initialLoading || model.requestedRefresh.isRunning(for: catalog)
    }

    private var canCreate: Bool { model.canCreateChannel }

    private var projection: ChannelSidebarProjection { model.sidebarProjection }

    private func channelList(now: Date) -> some View {
        @Bindable var model = model
        return List(selection: $model.selectedChannelID) {
            if initialLoading {
                ForEach(0..<3) { _ in
                    ChannelSidebarPlaceholder()
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(channels) { channel in
                    NavigationLink(value: channel.id) {
                        row(channel, now: now)
                    }
                    .contextMenu {
                        contextMenu(channel)
                    } preview: {
                        ChannelSidebarPreview(channel: projection.channel(channel), agents: projection.agents(channel))
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            channelList(now: context.date)
        }
        .listStyle(.plain)
        .overlay {
            emptyState
        }
        .safeAreaBar(edge: .bottom) {
            ChannelSidebarFooter(
                connection: connection, busy: busy, serverURL: model.serverURL,
                error: model.configurationError ?? model.catalog?.error,
                canRetry: model.catalog != nil && model.isActive,
                retry: { Task { await model.refreshCatalog() } },
                openSettings: { showsSettings = true }
            )
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search Channels")
        .searchFocused($searchFocused)
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .focusedValue(\.channelRefresh, model.isActive && model.catalog != nil ? {
            Task { await model.refreshCatalog() }
        } : nil)
        .refreshable { await model.refreshCatalog() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                    .disabled(!canCreate)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Settings", systemImage: "gear") { showsSettings = true }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshCatalog() }
                    }
                    .disabled(model.catalog == nil || !model.isActive)
                }
            }
        }
    }

    private func row(_ channel: Channel, now: Date) -> some View {
        let agents = projection.agents(channel)
        return ChannelSidebarRow(
            channel: projection.channel(channel), agents: agents,
            working: model.isActive ? projection.working(channel, agents: agents) : [],
            attention: projection.attention(channel), now: now
        )
    }

    @ViewBuilder private var emptyState: some View {
        if model.catalog == nil, model.configurationError == nil {
            ContentUnavailableView {
                Label("Connect to Toy Box", systemImage: "network")
            } description: {
                Text("Choose your Mac's server in Settings.")
            } actions: {
                Button("Settings") { showsSettings = true }
                    .frame(minHeight: 44)
            }
        } else if connection == .connected, channels.isEmpty {
            if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label("Your channels live here", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Channel") { management.present(.newChannel) }
                        .frame(minHeight: 44)
                        .disabled(!canCreate)
                }
            } else {
                ContentUnavailableView {
                    Label("No channels match \"\(trimmedQuery)\"", systemImage: "magnifyingglass")
                } actions: {
                    Button("Clear Search") { query = "" }
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private func contextMenu(_ channel: Channel) -> some View {
        Button("Open Channel", systemImage: "bubble.left.and.bubble.right") {
            model.selectedChannelID = channel.id
        }
        Button("Open in Toy Box", systemImage: "arrow.up.forward.square") {
            model.openInToyBox(channelID: channel.id)
        }
        if let path = channel.directory, !path.isEmpty {
            Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
        }
        Divider()
        Button("Edit Channel", systemImage: "pencil") {
            management.present(.editChannel(channelId: channel.id))
        }
        .disabled(!canManage(channelID: channel.id))
        Divider()
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(channelId: channel.id))
        }
        .disabled(!canManage(channelID: channel.id))
    }

    private func canManage(channelID: String) -> Bool {
        model.isActive && model.selectedStore?.id == channelID && model.selectedStore?.phase.isLive == true
    }
}

private struct ChannelSidebarPreview: View {
    let channel: Channel
    let agents: [ChannelAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(channel.name).font(.headline)
            if let path = channel.directory, !path.isEmpty {
                Label(path, systemImage: "folder").font(.footnote)
            }
            if let purpose = channel.purpose, !purpose.isEmpty {
                Text(purpose).font(.footnote)
            }
            Text("Team: " + agents.map(\.name).formatted(.list(type: .and)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct ChannelSidebarPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.quaternary).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 128, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 96, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 64, height: 8)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(minHeight: 96)
        .accessibilityHidden(true)
    }
}
