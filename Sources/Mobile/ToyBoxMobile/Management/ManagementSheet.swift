import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementSheet: View {
    let flow: ManagementFlow
    let presenter: ManagementPresenter
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @ViewState private var store: ChannelStore?

    private var catalog: ChannelCatalogStore? { flow.catalog(in: app.catalogs) }

    var body: some View {
        NavigationStack {
            Group {
                if catalog != nil {
                    if flow.isNewChannel {
                        ChannelEditor(flow: flow, store: nil, presenter: presenter, host: host)
                    } else if let store, let channel = store.details {
                        if presenter.hasLoaded {
                            content(channel: channel, store: store)
                        } else {
                            ProgressView("Loading current values")
                                .task { presenter.load(from: store) }
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
            guard let channelId = flow.target?.channelID, let catalog else { return }
            if let store { app.release(store) }
            let connection = catalog.channel(id: channelId)
            store = connection
            app.hold(connection)
        }
        .onDisappear {
            if let store { app.release(store) }
            store = nil
        }
    }

    @ViewBuilder
    private func content(channel: ChannelDetails, store: ChannelStore) -> some View {
        switch flow {
        case .editChannel:
            ChannelEditor(flow: flow, store: store, presenter: presenter, host: host)
        case .addMember:
            MemberEditor(flow: flow, channel: channel, store: store, presenter: presenter, host: host)
        case .editMember(_, let id):
            if store.roster.dropFirst().contains(where: { $0.id == id }) {
                MemberEditor(flow: flow, channel: channel, store: store, presenter: presenter, host: host)
            } else {
                unavailable("This agent is no longer in the channel.")
            }
        case .newChannel, .deleteChannel, .removeMember, .deleteRoutine:
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

struct ManagementError: View {
    let message: String
    var systemImage = "exclamationmark.triangle"

    var body: some View {
        Label {
            Text(message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
