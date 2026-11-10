import ChannelClient
import ChannelKit
import Foundation
import Observation

/// One entry point for every management sheet and confirmation. Each flow writes to one server: a
/// channel's own, or the one New Channel starts on.
public enum ManagementFlow: Identifiable, Equatable {
    /// A new channel, starting on the server at this address. The sheet can pick another.
    case newChannel(server: String)
    case editChannel(ChannelTarget)
    case deleteChannel(ChannelTarget)
    case addMember(ChannelTarget, name: String)
    case editMember(ChannelTarget, agentId: String)
    case removeMember(ChannelTarget, agentId: String)
    case deleteRoutine(ChannelTarget, routineId: String)

    public var id: String {
        switch self {
        case .newChannel: "new-channel"
        case .editChannel(let target): "edit-channel-\(target.identifier)"
        case .deleteChannel(let target): "delete-channel-\(target.identifier)"
        case .addMember(let target, let name): "add-member-\(target.identifier)-\(name)"
        case .editMember(let target, let agentId): "edit-member-\(target.identifier)-\(agentId)"
        case .removeMember(let target, let agentId): "remove-member-\(target.identifier)-\(agentId)"
        case .deleteRoutine(let target, let routineId): "delete-routine-\(target.identifier)-\(routineId)"
        }
    }

    /// The channel this flow manages, or nil for a new one.
    public var target: ChannelTarget? {
        switch self {
        case .newChannel: nil
        case .editChannel(let target), .deleteChannel(let target), .addMember(let target, _),
             .editMember(let target, _), .removeMember(let target, _), .deleteRoutine(let target, _): target
        }
    }

    public var channelId: String? { target?.channelID }

    /// The address of the server this flow writes to.
    public var server: String {
        if case .newChannel(let server) = self { return server }
        return target?.serverURL ?? ""
    }

    public var isNewChannel: Bool {
        if case .newChannel = self { return true }
        return false
    }

    /// The catalog of the server this flow writes to. New Channel starts on the first server when
    /// its own is gone, but a channel whose server is gone has nowhere to write.
    @MainActor public func catalog(in catalogs: [ChannelCatalogStore]) -> ChannelCatalogStore? {
        catalogs.first(at: server) ?? (isNewChannel ? catalogs.first : nil)
    }
}

@MainActor @Observable
public final class ManagementPresenter {
    public var flow: ManagementFlow?
    public private(set) var createdChannel: (channel: Channel, target: ChannelTarget?, token: UUID)?
    @ObservationIgnored private var creatingMentions: Set<String> = []
    @ObservationIgnored private var uncertainMentions: Set<String> = []

    public init() {}

    public func present(_ flow: ManagementFlow) { self.flow = flow }

    /// Selects a channel New Channel created on the server at `server`.
    public func didCreate(_ channel: Channel, on server: String) {
        createdChannel = (channel, ChannelTarget(serverURL: server, channelID: channel.id), UUID())
        flow = nil
    }

    public func finishAddingMember(_ target: ChannelTarget) {
        if case .addMember(let presented, _) = flow, presented == target {
            flow = nil
        }
    }

    public func createMentionMember(name: String, store: ChannelStore,
                                    catalog: ChannelCatalogStore? = nil) async throws -> ChannelAgent {
        guard store.phase.isConnected, let state = store.state else { throw ChannelAPIError.disconnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(store.api.baseURL.absoluteString):\(store.id):\(ChannelAgent.handle(forName: trimmed))"
        if uncertainMentions.contains(key) {
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage("The team has been refreshed. Review Team before explicitly creating this agent again.")
        }
        if let message = ChannelAgent.nameError(trimmed, agents: state.agents) {
            throw ChannelAPIError.invalidMessage(message)
        }
        guard creatingMentions.insert(key).inserted else {
            throw ChannelAPIError.invalidMessage("This agent is already being created.")
        }
        defer { creatingMentions.remove(key) }
        do {
            return try await store.api.createMember(channelId: store.id, input: .init(name: trimmed))
        } catch {
            guard ChannelManagementWriteRecovery.Phase.isRequired(after: error) else { throw error }
            uncertainMentions.insert(key)
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementWriteRecovery.Phase.uncertaintyMessage) The team has been refreshed. Review Team before creating another agent.")
        }
    }

    private func checkMentionCreation(key: String, store: ChannelStore,
                                      catalog: ChannelCatalogStore?) async throws {
        guard let catalog, catalog.api.baseURL == store.api.baseURL else {
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementWriteRecovery.Phase.uncertaintyMessage) Reconnect to this server before checking Team.")
        }
        do {
            _ = try await catalog.reconcileManagementWrite(channelId: store.id)
            uncertainMentions.remove(key)
        } catch {
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementWriteRecovery.Phase.uncertaintyMessage) Current state could not be checked. \(error.localizedDescription)")
        }
    }
}
