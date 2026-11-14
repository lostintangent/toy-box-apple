import ToyBoxKit
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

    /// The address of the server this flow writes to.
    public var server: String {
        if case .newChannel(let server) = self { return server }
        return target?.serverURL ?? ""
    }

    public var isNewChannel: Bool {
        if case .newChannel = self { return true }
        return false
    }

    /// Deleting asks in one system alert over the place that asked, never in a sheet.
    public var isDeletion: Bool {
        switch self {
        case .deleteChannel, .removeMember, .deleteRoutine: true
        default: false
        }
    }

    /// The catalog of the server this flow writes to. New Channel starts on the first server when
    /// its own is gone, but a channel whose server is gone has nowhere to write.
    @MainActor public func catalog(in catalogs: [ChannelCatalogStore]) -> ChannelCatalogStore? {
        catalogs.first(at: server) ?? (isNewChannel ? catalogs.first : nil)
    }
}

public enum ManagementField: Hashable {
    case name, purpose, role
}

@MainActor @Observable
public final class ManagementPresenter {
    /// The flow on screen. Presenting another starts fresh entries, while New Channel's Server menu,
    /// which changes only its server, keeps them.
    public var flow: ManagementFlow? {
        didSet {
            guard flow?.id != oldValue?.id else { return }
            visit += 1
            if let flow { begin(flow) }
        }
    }
    public private(set) var createdChannel: (channel: Channel, target: ChannelTarget?, token: UUID)?
    // The flow's entries live here, not in its sheet, so they survive the sheet moving between hosts.
    public var channelForm = ChannelForm()
    public var memberForm = MemberForm()
    public var focus: ManagementField? = .name
    public var error: String?
    /// When the flow's one write started, while it's in flight.
    public private(set) var pendingSince: ContinuousClock.Instant?
    public var isPending: Bool { pendingSince != nil }
    /// Whether an edit flow holds the channel's current values yet.
    public private(set) var hasLoaded = true
    /// The deletion in flight, then whether it failed. It sits beside the flow, so removing an agent
    /// from Edit Agent never replaces its entries.
    public package(set) var deletion: (flow: ManagementFlow, failed: Bool)?
    @ObservationIgnored private var visit = 0
    @ObservationIgnored private var creatingMentions: Set<String> = []

    public init() {}

    public func present(_ flow: ManagementFlow) { self.flow = flow }

    /// Selects a channel New Channel created on the server at `server`.
    public func didCreate(_ channel: Channel, on server: String) {
        createdChannel = (channel, ChannelTarget(serverURL: server, channelID: channel.id), UUID())
        flow = nil
    }

    private func begin(_ flow: ManagementFlow) {
        channelForm = ChannelForm()
        memberForm = if case .addMember(_, let name) = flow { MemberForm(name: name) } else { MemberForm() }
        focus = .name
        error = nil
        pendingSince = nil
        deletion = nil
        switch flow {
        case .editChannel, .editMember: hasLoaded = false
        default: hasLoaded = true
        }
    }

    /// Fills an edit flow's entries with the channel's current values, once.
    public func load(from store: ChannelStore) {
        guard !hasLoaded, let channel = store.details else { return }
        switch flow {
        case .editChannel: channelForm = ChannelForm(channel)
        case .editMember(_, let id): memberForm = MemberForm(store.roster.dropFirst().first { $0.id == id })
        default: break
        }
        hasLoaded = true
    }

    /// Sends the flow's one write to `catalog`, then closes the flow unless another has replaced it.
    /// A failure keeps the entries, says why and returns focus to the field that had it.
    public func save(on catalog: ChannelCatalogStore) async {
        guard let flow, !flow.isDeletion, pendingSince == nil else { return }
        let visit = visit, focused = focus, channelForm = channelForm, memberForm = memberForm
        let started = ContinuousClock.now
        pendingSince = started
        error = nil
        defer { if pendingSince == started { pendingSince = nil } }
        do {
            var created: Channel?
            switch flow {
            case .addMember(let target, _), .editMember(let target, _):
                _ = try await memberForm.submit(to: catalog.api, channelId: target.channelID)
            default:
                let saved = try await channelForm.submit(to: catalog.api)
                if flow.isNewChannel { created = saved }
            }
            if self.visit == visit {
                if let created { didCreate(created, on: catalog.api.baseURL.absoluteString) } else { self.flow = nil }
            }
            await catalog.refresh()
        } catch {
            guard self.visit == visit else { return }
            pendingSince = nil
            self.error = error.localizedDescription
            // The form re-enables before focus can return.
            await Task.yield()
            if self.visit == visit { focus = focused }
        }
    }

    /// Sends a deletion once, then closes whatever asked unless another flow has replaced it. A
    /// failure only says so, and the live list shows whether it landed.
    public func delete(_ deletion: ManagementFlow, on catalog: ChannelCatalogStore) async {
        guard deletion.isDeletion, self.deletion?.failed != false else { return }
        let origin = flow
        self.deletion = (deletion, false)
        do {
            switch deletion {
            case .removeMember(let target, let id):
                try await catalog.api.removeMember(channelId: target.channelID, agentId: id)
            case .deleteRoutine(let target, let id):
                try await catalog.api.deleteRoutine(channelId: target.channelID, routineId: id)
            default:
                if let target = deletion.target { try await catalog.api.deleteChannel(id: target.channelID) }
            }
            if self.deletion?.flow == deletion { self.deletion = nil }
            if flow == origin { flow = nil }
            await catalog.refresh()
        } catch {
            if self.deletion?.flow == deletion { self.deletion = (deletion, true) }
        }
    }

    public func createMentionMember(name: String, store: ChannelStore) async throws -> ChannelAgent {
        guard store.phase.isConnected, let state = store.state else { throw ChannelAPIError.disconnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(store.api.baseURL.absoluteString):\(store.id):\(ChannelAgent.handle(forName: trimmed))"
        if let message = ChannelAgent.nameError(trimmed, agents: state.agents) {
            throw ChannelAPIError.invalidMessage(message)
        }
        guard creatingMentions.insert(key).inserted else {
            throw ChannelAPIError.invalidMessage("This agent is already being created.")
        }
        defer { creatingMentions.remove(key) }
        return try await store.api.createMember(channelId: store.id, input: .init(name: trimmed))
    }
}
