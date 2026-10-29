import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI
import UIKit

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var showsSettings: Bool
    var searchFocused: FocusState<Bool>.Binding
    /// The split view shows one column at a time, as on a folded Duo.
    let isCollapsed: Bool
    @ViewState private var query = ""
    @ViewState private var pull = PullGesture()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var channels: [Channel] {
        (model.catalog?.channels ?? []).filter { channelMatchesQuery($0, query: trimmedQuery) }
    }

    private var initialLoading: Bool { model.catalog?.phase == .connecting }

    private var canCreate: Bool { model.canCreateChannel }

    private var projection: ChannelSidebarProjection { model.sidebarProjection }

    private func channelList(now: Date) -> some View {
        @Bindable var model = model
        return List(selection: $model.selectedChannelID) {
            Section {
                if initialLoading {
                    ForEach(0..<3) { _ in
                        ChannelSidebarPlaceholder()
                            .listRowInsets(.vertical, 0)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(channels) { channel in
                        NavigationLink(value: channel.id) {
                            row(channel, now: now)
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .listRowInsets(.vertical, 0)
                        .contextMenu {
                            contextMenu(channel)
                        } preview: {
                            ChannelSidebarPreview(channel: projection.channel(channel), agents: projection.agents(channel))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                management.present(.deleteChannel(channelId: channel.id))
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!model.canManageChannels)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .onScrollPhaseChange { _, phase in
            pull.isTouching = phase == .tracking || phase == .interacting
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            channelList(now: context.date)
        }
        .listStyle(.plain)
        .overlay {
            emptyState
        }
        .safeAreaBar(edge: .bottom) {
            ChannelSidebarFailure(
                footer: model.sidebarFooter,
                error: model.configurationError ?? model.catalog?.phase.message,
                canRetry: model.catalog != nil && model.isActive,
                retry: { Task { await model.refreshCatalog() } },
                openSettings: { showsSettings = true },
                showsSettingsButton: sizeClass != .compact
            )
        }
        .navigationTitle("Toy Box")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .toolbar, prompt: "Search Channels")
        // A full search field makes UIKit cancel the first pull to refresh after Back, so the
        // collapsed list minimizes it. The overlay sidebar keeps the field, since UIKit places
        // the minimized button beyond its trailing edge.
        .searchToolbarBehavior(isCollapsed ? .minimize : .automatic)
        .searchFocused(searchFocused)
        .focusedValue(\.channelListFocused, true)
        .refreshable {
            await model.refreshCatalog()
            await pull.released()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                    .disabled(!canCreate)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Settings", systemImage: "gear") { showsSettings = true }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
    }

    private func row(_ channel: Channel, now: Date) -> some View {
        let agents = projection.agents(channel)
        return ChannelSidebarRow(
            channel: projection.channel(channel), agents: agents,
            working: projection.working(channel, agents: agents),
            attention: projection.attention(channel), now: now
        )
    }

    @ViewBuilder private var emptyState: some View {
        if model.catalog == nil, model.configurationError == nil {
            ContentUnavailableView {
                Label("Connect to Toy Box", systemImage: "network")
            } description: {
                Text("Choose your Toy Box server in Settings.")
            } actions: {
                Button("Settings") { showsSettings = true }
                    .frame(minHeight: 44)
            }
        } else if model.catalog?.phase == .connected, channels.isEmpty {
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
        .disabled(!model.canManageChannels)
        Divider()
        Button("Delete Channel", systemImage: "trash", role: .destructive) {
            management.present(.deleteChannel(channelId: channel.id))
        }
        .disabled(!model.canManageChannels)
    }
}

/// UIKit ends a pull to refresh in place when its action returns while the finger is still down,
/// dropping the spinner and jolting the list mid-pull. Holding the action until the finger lifts
/// lets the control settle and collapse as it does after a slower load.
@MainActor @Observable private final class PullGesture {
    var isTouching = false

    func released() async {
        for await touching in Observations({ self.isTouching }) where !touching { return }
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
                .foregroundStyle(ChannelInk.secondary)
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
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .accessibilityHidden(true)
    }
}
