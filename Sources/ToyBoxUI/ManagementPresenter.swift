import ChannelClient
import ChannelKit
import Foundation
import Observation

/// One entry point for every management sheet and confirmation.
public enum ManagementFlow: Identifiable, Equatable {
    case newChannel
    case editChannel(channelId: String)
    case deleteChannel(channelId: String)
    case addMember(channelId: String, name: String)
    case editMember(channelId: String, agentId: String)
    case removeMember(channelId: String, agentId: String)
    case deleteRoutine(channelId: String, routineId: String)

    public var id: String {
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
public final class ManagementPresenter {
    public var flow: ManagementFlow?
    public private(set) var createdChannel: (channel: Channel, token: UUID)?
    @ObservationIgnored private var creatingMentions: Set<String> = []
    @ObservationIgnored private var uncertainMentions: Set<String> = []

    public init() {}

    public func present(_ flow: ManagementFlow) { self.flow = flow }

    public func didCreate(_ channel: Channel) {
        createdChannel = (channel, UUID())
        flow = nil
    }

    public func finishAddingMember(channelId: String) {
        if case .addMember(let presentedChannelId, _) = flow, presentedChannelId == channelId {
            flow = nil
        }
    }

    public func createMentionMember(name: String, store: ChannelStore,
                                    catalog: ChannelCatalogStore? = nil) async throws -> ChannelMember {
        guard store.phase.isLive, let state = store.state else { throw ChannelAPIError.disconnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(store.api.baseURL.absoluteString):\(store.id):\(agentHandleFromName(trimmed))"
        if uncertainMentions.contains(key) {
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage("The team has been refreshed. Review Team before explicitly creating this agent again.")
        }
        if let message = ChannelValidation.memberNameError(trimmed, agents: state.agents) {
            throw ChannelAPIError.invalidMessage(message)
        }
        guard creatingMentions.insert(key).inserted else {
            throw ChannelAPIError.invalidMessage("This agent is already being created.")
        }
        defer { creatingMentions.remove(key) }
        do {
            return try await store.api.createMember(channelId: store.id, input: .init(name: trimmed))
        } catch {
            guard ChannelManagementRecoveryState.isRequired(after: error) else { throw error }
            uncertainMentions.insert(key)
            try await checkMentionCreation(key: key, store: store, catalog: catalog)
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementRecoveryState.uncertaintyMessage) The team has been refreshed. Review Team before creating another agent.")
        }
    }

    private func checkMentionCreation(key: String, store: ChannelStore,
                                      catalog: ChannelCatalogStore?) async throws {
        guard let catalog, catalog.api.baseURL == store.api.baseURL else {
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementRecoveryState.uncertaintyMessage) Reconnect to this server before checking Team.")
        }
        do {
            _ = try await catalog.reconcileManagementWrite(channelId: store.id)
            uncertainMentions.remove(key)
        } catch {
            throw ChannelAPIError.invalidMessage(
                "\(ChannelManagementRecoveryState.uncertaintyMessage) Current state could not be checked. \(error.localizedDescription)")
        }
    }
}
