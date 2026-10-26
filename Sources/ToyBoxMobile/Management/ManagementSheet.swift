import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementSheet: View {
    let flow: ManagementFlow
    let presenter: ManagementPresenter
    @Environment(AppModel.self) private var app
    @ViewState private var store: ChannelStore?

    private var channelID: String? {
        switch flow {
        case .newChannel: nil
        case .editChannel(let id), .deleteChannel(let id), .addMember(let id, _),
             .editMember(let id, _), .removeMember(let id, _), .deleteRoutine(let id, _): id
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let api = app.api {
                    if flow == .newChannel {
                        ChannelEditor(channel: nil, store: nil, api: api, presenter: presenter)
                    } else if let store, let channel = store.details {
                        content(channel: channel, store: store, api: api)
                    } else {
                        VStack(spacing: 16) {
                            if store?.phase == .deleted {
                                Label("This channel was deleted.", systemImage: "trash")
                            } else if let message = store?.phase.message {
                                ManagementError(message: message)
                                Button("Reconnect") { store?.reconnect() }
                            } else {
                                ProgressView("Loading current channel")
                            }
                            Button("Cancel", role: .cancel) { presenter.flow = nil }
                        }
                        .padding()
                    }
                } else {
                    unavailable(app.configurationError ?? "Set a server URL in Settings before managing channels.")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: channelID) {
            guard let channelID, let catalog = app.catalog else { return }
            let connection = catalog.channel(id: channelID)
            store = connection
            app.acquire(connection)
        }
        .onDisappear {
            if let store { app.release(store) }
            store = nil
        }
        .onChange(of: app.serverURL) { _, _ in presenter.flow = nil }
    }

    @ViewBuilder
    private func content(channel: ChannelDetails, store: ChannelStore, api: ChannelAPI) -> some View {
        switch flow {
        case .newChannel:
            ChannelEditor(channel: nil, store: nil, api: api, presenter: presenter)
        case .editChannel:
            ChannelEditor(channel: channel, store: store, api: api, presenter: presenter)
        case .addMember(_, let name):
            MemberEditor(channel: channel, member: nil, initialName: name, store: store, api: api, presenter: presenter)
        case .editMember(_, let id):
            if let member = store.roster.dropFirst().first(where: { $0.id == id }) {
                MemberEditor(channel: channel, member: member, initialName: member.name,
                             store: store, api: api, presenter: presenter)
            } else {
                unavailable("This agent is no longer in the channel.")
            }
        case .deleteChannel, .removeMember, .deleteRoutine:
            ManagementConfirmation(flow: flow, channel: channel, store: store, api: api, presenter: presenter)
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Management Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Close") { presenter.flow = nil }
        }
    }
}
