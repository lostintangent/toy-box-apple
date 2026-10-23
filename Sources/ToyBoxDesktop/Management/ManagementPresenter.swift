import ChannelClient
import ChannelKit
import Observation
import SwiftUI

/// One entry point for every management sheet and confirmation, so the sidebar, toolbar, menus,
/// mention completion and inspector can all ask for the same flows.
enum ManagementFlow: Identifiable, Equatable {
    case newChannel
    case editChannel(channelId: String)
    case deleteChannel(channelId: String)
    case addMember(channelId: String, name: String)
    case editMember(channelId: String, agentId: String)
    case removeMember(channelId: String, agentId: String)
    case deleteRoutine(channelId: String, routineId: String)

    var id: String {
        switch self {
        case .newChannel: "new-channel"
        case .editChannel(let channelId): "edit-channel-\(channelId)"
        case .deleteChannel(let channelId): "delete-channel-\(channelId)"
        case .addMember(let channelId, let name): "add-member-\(channelId)-\(name)"
        case .editMember(let channelId, let agentId): "edit-member-\(channelId)-\(agentId)"
        case .removeMember(let channelId, let agentId): "remove-member-\(channelId)-\(agentId)"
        case .deleteRoutine(let channelId, let routineId): "delete-routine-\(channelId)-\(routineId)"
        }
    }
}

@MainActor @Observable
final class ManagementPresenter {
    var flow: ManagementFlow?
    private(set) var createdChannel: (channel: Channel, token: UUID)?
    private(set) var createdMember: (channelId: String, member: ChannelMember, token: UUID)?
    @ObservationIgnored private var creatingMentions: Set<String> = []
    @ObservationIgnored private var uncertainMentions: Set<String> = []

    func present(_ flow: ManagementFlow) { self.flow = flow }

    func didCreate(_ channel: Channel) {
        createdChannel = (channel, UUID())
        flow = nil
    }

    func didCreate(_ member: ChannelMember, channelId: String, dismissSheet: Bool = true) {
        createdMember = (channelId, member, UUID())
        if dismissSheet, case .addMember(let presentedChannelId, _) = flow, presentedChannelId == channelId {
            flow = nil
        }
    }

    func createMentionMember(name: String, store: ChannelStore,
                             catalog: ChannelCatalogStore? = nil) async throws -> ChannelMember {
        guard store.phase.isLive, let state = store.state else { throw ChannelAPIError.disconnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(store.api.baseURL.absoluteString):\(store.id):\(agentHandleFromName(trimmed))"
        if uncertainMentions.contains(key) {
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage("The team has been refreshed. Review Team before explicitly creating this agent again.")
        }
        if let message = MemberValidation.nameError(trimmed, agents: state.agents) {
            throw ChannelAPIError.invalidMessage(message)
        }
        guard creatingMentions.insert(key).inserted else {
            throw ChannelAPIError.invalidMessage("This agent is already being created.")
        }
        defer { creatingMentions.remove(key) }
        do {
            let member = try await store.api.createMember(channelId: store.id, input: .init(name: trimmed))
            didCreate(member, channelId: store.id, dismissSheet: false)
            return member
        } catch {
            guard ManagementRecoveryState.isRequired(after: error) else { throw error }
            uncertainMentions.insert(key)
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage(
                "\(ManagementRecoveryState.uncertaintyMessage) The team has been refreshed. Review Team before creating another agent.")
        }
    }

    private func checkMentionCreation(key: String, store: ChannelStore,
                                      catalog: ChannelCatalogStore?) async throws {
        guard let catalog, catalog.api.baseURL == store.api.baseURL else {
            throw ChannelAPIError.invalidMessage(
                "\(ManagementRecoveryState.uncertaintyMessage) Reconnect to this server before checking Team.")
        }
        do {
            _ = try await catalog.reconcileManagementWrite(channelId: store.id)
            uncertainMentions.remove(key)
        } catch {
            throw ChannelAPIError.invalidMessage(
                "\(ManagementRecoveryState.uncertaintyMessage) Current state could not be checked. \(error.localizedDescription)")
        }
    }
}

enum MemberValidation {
    static func nameError(_ name: String, agents: [ChannelAgent], excludingID: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter an agent name." }
        if trimmed.utf16.count > 80 { return "Agent names are limited to 80 characters." }
        let handle = agentHandleFromName(trimmed)
        if agents.contains(where: { $0.id != excludingID && agentHandleFromName($0.name) == handle }) {
            return "Another agent is already mentioned as @\(handle)."
        }
        return nil
    }
}

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
                } else if let store, let state = store.state {
                    flowContent(state: state, store: store, api: api)
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
            app.acquire(connection)
        }
        .onDisappear { if let store { app.release(store) } }
    }

    @ViewBuilder
    private func flowContent(state: ChannelState, store: ChannelStore, api: ChannelAPI) -> some View {
        switch flow {
        case .newChannel: EmptyView()
        case .editChannel:
            ChannelEditor(channel: state.channel, store: store, api: api, presenter: presenter)
        case .addMember(_, let name):
            MemberEditor(channel: state.channel, member: nil, initialName: name, store: store,
                         api: api, presenter: presenter)
        case .editMember(_, let agentId):
            if let member = state.members.first(where: { $0.id == agentId }) {
                MemberEditor(channel: state.channel, member: member, initialName: member.name,
                             store: store, api: api, presenter: presenter)
            } else {
                unavailable("This member is no longer in the channel.")
            }
        case .deleteChannel, .removeMember, .deleteRoutine:
            ManagementConfirmation(flow: flow, state: state, store: store,
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
        if let store, !store.phase.isLive {
            Label(store.phase == .deleted
                  ? "This channel was deleted."
                  : "Reconnect before making changes. Your edits are preserved.",
                  systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
