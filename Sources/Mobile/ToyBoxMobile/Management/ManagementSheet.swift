import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementSheet: View {
    let flow: ManagementFlow
    let presenter: ManagementPresenter
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(ManagementSessions.self) private var sessions
    @ViewState private var store: ChannelStore?

    private var catalog: ChannelCatalogStore? { flow.catalog(in: app.catalogs) }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    let session = sessions.session(for: flow, catalog: catalog)
                    if flow.isNewChannel {
                        ChannelEditor(store: nil, presenter: presenter, session: session, host: host)
                    } else if let store, let channel = store.details {
                        if session.hasLoaded {
                            content(channel: channel, store: store, session: session)
                        } else {
                            ProgressView("Loading current values")
                                .task {
                                    let member: ChannelAgent?
                                    if case .editMember(_, let id) = flow {
                                        member = store.roster.dropFirst().first { $0.id == id }
                                    } else { member = nil }
                                    session.load(channel: channel, member: member)
                                }
                        }
                    } else {
                        VStack(spacing: 16) {
                            if store?.phase == .deleted {
                                Label("This channel was deleted.", systemImage: "trash")
                            } else if let message = store?.phase.message {
                                ManagementError(message: message)
                                Button("Retry") { store?.reconnect() }
                            } else {
                                ProgressView("Loading current channel")
                            }
                            Button(role: .close) { presenter.flow = nil }
                                .accessibilityLabel("Cancel")
                        }
                        .padding()
                    }
                } else {
                    unavailable(app.configurationError ?? "Set a server URL in Settings before managing channels.")
                }
            }
            .listSectionSpacing(24)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: catalog.map(ObjectIdentifier.init)) {
            guard let channelId = flow.channelId, let catalog else { return }
            if let store { app.release(store) }
            let connection = catalog.channel(id: channelId)
            store = connection
            app.hold(connection)
        }
        .onDisappear {
            if let store { app.release(store) }
            store = nil
        }
        // The sheet closes when Settings removes its server or gives it a new address.
        .onChange(of: app.catalogs.map(ObjectIdentifier.init)) { _, servers in
            guard let session = sessions.current, session.flow == flow else { return }
            if !servers.contains(ObjectIdentifier(session.catalog)) { presenter.flow = nil }
        }
    }

    @ViewBuilder
    private func content(channel: ChannelDetails, store: ChannelStore, session: ManagementSession) -> some View {
        switch flow {
        case .newChannel:
            ChannelEditor(store: nil, presenter: presenter, session: session, host: host)
        case .editChannel:
            ChannelEditor(store: store, presenter: presenter, session: session, host: host)
        case .addMember:
            MemberEditor(channel: channel, store: store, presenter: presenter, session: session, host: host)
        case .editMember(_, let id):
            if store.roster.dropFirst().contains(where: { $0.id == id }) {
                MemberEditor(channel: channel, store: store, presenter: presenter, session: session, host: host)
            } else {
                unavailable("This agent is no longer in the channel.")
            }
        case .deleteChannel, .removeMember, .deleteRoutine:
            EmptyView() // Deletions ask in ManagementConfirmation's alert, never in this sheet.
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

/// A management sheet's confirm. iOS draws the checkmark, which gives way to the delayed spinner while a write is pending.
struct ManagementConfirmButton: View {
    let label: String
    let pendingSince: ContinuousClock.Instant?
    let identifier: String
    let action: () -> Void

    var body: some View {
        if let pendingSince {
            Button(role: .confirm, action: action) {
                DelayedProgressView(since: pendingSince).controlSize(.small)
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        } else {
            Button(role: .confirm, action: action)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
    }
}
