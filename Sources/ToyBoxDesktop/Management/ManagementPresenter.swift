import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

extension View {
    /// Attached once per window by the shell. The Management owner implements the flows.
    func managementFlows(_ presenter: ManagementPresenter) -> some View {
        modifier(ManagementFlowsModifier(presenter: presenter))
    }
}

private struct ManagementFlowsModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.windowSnapshot) private var snapshot
    @Bindable var presenter: ManagementPresenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.flow) { flow in
                ManagementSheet(flow: flow, presenter: presenter)
            }
            .task(id: snapshot?.requestedState) { prepareSnapshotState() }
    }

    private func prepareSnapshotState() {
        guard let snapshot, let state = snapshot.requestedState,
              let channelId = snapshot.options.channelID else { return }
        switch state {
        case "add-member":
            presenter.present(.addMember(channelId: channelId, name: ""))
            snapshot.markStateReady(state)
        case "edit-member":
            guard let member = app.catalog?.channel(id: channelId).state?.members.first else {
                snapshot.failState(state, message: "The channel has no member to edit")
                return
            }
            presenter.present(.editMember(channelId: channelId, agentId: member.id))
            snapshot.markStateReady(state)
        default: break
        }
    }
}

private struct ManagementSheet: View {
    @Environment(AppModel.self) private var app
    let flow: ManagementFlow
    let presenter: ManagementPresenter
    @ViewState private var store: ChannelStore?

    private var channelId: String? {
        switch flow {
        case .newChannel: nil
        case .editChannel(let id), .deleteChannel(let id),
             .addMember(let id, _), .editMember(let id, _),
             .removeMember(let id, _), .deleteRoutine(let id, _): id
        }
    }

    var body: some View {
        Group {
            if let api = app.api {
                if flow == .newChannel {
                    ChannelEditor(channel: nil, store: nil, api: api, presenter: presenter)
                } else if let store, let details = store.details {
                    flowContent(details: details, store: store, api: api)
                } else {
                    VStack(spacing: 16) {
                        if let store, case .deleted = store.phase {
                            Label("This channel was deleted.", systemImage: "trash")
                        } else if let error = store?.phase.message {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { store?.reconnect() }
                        } else {
                            ProgressView("Loading current channel")
                        }
                        Button("Cancel", role: .cancel) { presenter.flow = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                    .frame(width: 480, height: 200)
                }
            } else {
                VStack(spacing: 16) {
                    Text("Connect to Toy Box to manage channels.")
                    Text(app.configurationError ?? "Set a server URL in Settings.")
                        .foregroundStyle(.secondary)
                    Button("Close") { presenter.flow = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .frame(width: 480)
            }
        }
        .task(id: "\(app.serverURL)|\(channelId ?? "")") {
            guard let id = channelId, let api = app.api else { return }
            if let store { app.release(store) }
            let connection = app.catalog?.channel(id: id) ?? ChannelStore(id: id, api: api)
            store = connection
            app.hold(connection)
        }
        .onDisappear { if let store { app.release(store) } }
    }

    @ViewBuilder
    private func flowContent(details: ChannelDetails, store: ChannelStore, api: ChannelAPI) -> some View {
        switch flow {
        case .newChannel: EmptyView()
        case .editChannel:
            ChannelEditor(channel: details, store: store, api: api, presenter: presenter)
        case .addMember(_, let name):
            MemberEditor(channel: details, member: nil, initialName: name, store: store,
                         api: api, presenter: presenter)
        case .editMember(_, let agentId):
            if let member = store.roster.dropFirst().first(where: { $0.id == agentId }) {
                MemberEditor(channel: details, member: member, initialName: member.name,
                             store: store, api: api, presenter: presenter)
            } else {
                unavailable("This member is no longer in the channel.")
            }
        case .deleteChannel, .removeMember, .deleteRoutine:
            ManagementConfirmation(flow: flow, channel: details, store: store,
                                   api: api, presenter: presenter)
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
            Button("Close") { presenter.flow = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct ManagementError: View {
    let message: String
    var body: some View {
        Label {
            Text(message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Error: \(message)")
    }
}

struct ManagementConnectionNotice: View {
    let store: ChannelStore?
    var body: some View {
        if let store, store.phase.isUnavailable {
            Label(store.phase == .deleted
                  ? "This channel was deleted."
                  : "Reconnect before making changes. Your edits are preserved.",
                  systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
