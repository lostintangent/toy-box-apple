import ChannelKit
import SwiftUI

struct ChannelSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(ManagementPresenter.self) private var management
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if let catalog = model.catalog {
                ForEach(catalog.channels) { channel in
                    HStack {
                        Image(systemName: "number")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.name)
                            if let purpose = channel.purpose {
                                Text(purpose).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let attention = channelSidebarStatus(channel, isOpen: channel.id == selection) {
                            Image(systemName: attention == .waiting ? "questionmark.circle.fill"
                                  : attention == .finished ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(attention == .waiting ? .orange : .blue)
                                .font(.caption)
                        }
                    }
                    .tag(channel.id)
                }
            }
        }
        .navigationTitle("Channels")
        .overlay {
            if let catalog = model.catalog, catalog.isLoading, catalog.channels.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.catalog?.error ?? model.configurationError {
                Text(error).font(.caption).foregroundStyle(.red).padding(12)
            }
        }
        .toolbar {
            Button("New Channel", systemImage: "plus") { management.present(.newChannel) }
        }
    }
}
