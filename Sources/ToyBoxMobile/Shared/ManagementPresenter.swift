import Observation

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
        case .editChannel(let id): "edit-channel-\(id)"
        case .deleteChannel(let id): "delete-channel-\(id)"
        case .addMember(let id, let name): "add-member-\(id)-\(name)"
        case .editMember(let id, let agent): "edit-member-\(id)-\(agent)"
        case .removeMember(let id, let agent): "remove-member-\(id)-\(agent)"
        case .deleteRoutine(let id, let routine): "delete-routine-\(id)-\(routine)"
        }
    }
}

@MainActor @Observable
final class ManagementPresenter {
    var flow: ManagementFlow?

    func present(_ flow: ManagementFlow) { self.flow = flow }
}
