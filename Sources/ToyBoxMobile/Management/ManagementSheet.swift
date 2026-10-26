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
                if let catalog = app.catalog {
                    let session = sessions.session(for: flow, catalog: catalog)
                    if flow == .newChannel {
                        ChannelEditor(store: nil, presenter: presenter, session: session, host: host)
                    } else if let store, let channel = store.details {
                        if session.hasLoaded {
                            content(channel: channel, store: store, session: session)
                        } else {
                            ProgressView("Loading current values")
                                .task {
                                    let member: ChannelMember?
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
            ManagementConfirmation(flow: flow, channel: channel, store: store, presenter: presenter,
                                   session: session, host: host)
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

struct ManagementActionLabel: View {
    let title: String
    let pendingSince: ContinuousClock.Instant?
    @ViewState private var showsProgress = false

    var body: some View {
        HStack {
            if showsProgress {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Text(title)
        }
        .task(id: pendingSince) {
            showsProgress = false
            guard let pendingSince else { return }
            let delay = Duration.milliseconds(300) - pendingSince.duration(to: .now)
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                showsProgress = true
            } catch is CancellationError {
                return
            } catch {
                NSLog("Management progress delay failed: %@", error.localizedDescription)
            }
        }
    }
}
