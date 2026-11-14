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
            .sheet(item: Binding(get: { presenter.flow?.isDeletion == true ? nil : presenter.flow },
                                 set: { presenter.flow = $0 })) { flow in
                ManagementSheet(flow: flow, presenter: presenter)
            }
            .managementConfirmation($presenter.flow, presenter: presenter, catalogs: app.catalogs)
            .task(id: snapshot?.requestedState) { prepareSnapshotState() }
    }

    private func prepareSnapshotState() {
        guard let snapshot, let state = snapshot.requestedState, let catalog = app.catalog,
              let channelId = snapshot.options.channelID, let target = catalog.target(channelId) else { return }
        switch state {
        case "add-member":
            presenter.present(.addMember(target, name: ""))
            snapshot.markStateReady(state)
        case "delete-channel":
            presenter.present(.deleteChannel(target))
            snapshot.markStateReady(state)
        case "edit-member":
            guard let member = catalog.channel(id: channelId).state?.members.first else {
                snapshot.failState(state, message: "The channel has no member to edit")
                return
            }
            presenter.present(.editMember(target, agentId: member.id))
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

    private var catalog: ChannelCatalogStore? { flow.catalog(in: app.catalogs) }

    var body: some View {
        Group {
            if let catalog {
                if flow.isNewChannel {
                    ChannelEditor(store: nil, catalog: catalog, presenter: presenter)
                } else if let store, let details = store.details, presenter.hasLoaded {
                    flowContent(details: details, store: store, catalog: catalog)
                } else {
                    VStack(spacing: 16) {
                        if let store, case .deleted = store.phase {
                            Label("This channel was deleted.", systemImage: "trash")
                        } else if let error = store?.phase.message {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                            Button("Retry") { store?.reconnect() }
                        } else {
                            ProgressView("Loading current channel")
                        }
                        Button("Cancel", role: .cancel) { presenter.flow = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                    .frame(width: 480, height: 200)
                    .task(id: store?.details != nil) { if let store { presenter.load(from: store) } }
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
        .task(id: catalog.map(ObjectIdentifier.init)) {
            guard let id = flow.target?.channelID, let catalog else { return }
            if let store { app.release(store) }
            let connection = catalog.channel(id: id)
            store = connection
            app.hold(connection)
        }
        // A channel's sheet closes when Settings removes its server or gives it a new address.
        .onChange(of: catalog == nil) { _, isGone in
            if isGone, !flow.isNewChannel { presenter.flow = nil }
        }
        .onDisappear { if let store { app.release(store) } }
    }

    @ViewBuilder
    private func flowContent(details: ChannelDetails, store: ChannelStore,
                             catalog: ChannelCatalogStore) -> some View {
        switch flow {
        case .editChannel:
            ChannelEditor(store: store, catalog: catalog, presenter: presenter)
        case .addMember:
            MemberEditor(channel: details, store: store, catalog: catalog, presenter: presenter)
        case .editMember(_, let agentId):
            if store.roster.dropFirst().contains(where: { $0.id == agentId }) {
                MemberEditor(channel: details, store: store, catalog: catalog, presenter: presenter)
            } else {
                unavailable("This member is no longer in the channel.")
            }
        case .newChannel, .deleteChannel, .removeMember, .deleteRoutine:
            EmptyView() // Deletions ask in the window's alert, never in this sheet.
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
        // The symbol speaks "Error" on its own. A label around selectable text recurses in AppKit.
        Label {
            Text(message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel("Error")
                .accessibilityHidden(false)
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}
