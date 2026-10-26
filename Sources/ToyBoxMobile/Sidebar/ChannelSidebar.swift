import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Binding var showsSettings: Bool
    @ViewState private var query = ""

    private var channels: [Channel] {
        let channels = model.catalog?.channels ?? []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channelMatchesQuery($0, query: query) }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedChannelID) {
            ForEach(channels) { channel in
                NavigationLink(value: channel.id) {
                    Text(channel.name)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error = model.configurationError ?? model.catalog?.error, channels.isEmpty {
                ContentUnavailableView("Can't connect to Toy Box", systemImage: "wifi.exclamationmark",
                                       description: Text(error))
            } else if model.catalog == nil {
                ContentUnavailableView("Connect to Toy Box", systemImage: "network",
                                       description: Text("Choose your Mac's server in Settings."))
            }
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search Channels")
        .refreshable { await model.refreshCatalog() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
                    .disabled(model.catalog?.hasLoaded != true)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Settings", systemImage: "gear") { showsSettings = true }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshCatalog() }
                }
                .disabled(model.catalog == nil)
            }
        }
    }
}
