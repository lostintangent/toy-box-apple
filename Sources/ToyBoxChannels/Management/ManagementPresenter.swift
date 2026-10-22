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
    func present(_ flow: ManagementFlow) { self.flow = flow }
}

extension View {
    /// Attached once per window by the shell. The Management owner implements the flows.
    func managementFlows(_ presenter: ManagementPresenter) -> some View {
        modifier(ManagementFlowsModifier(presenter: presenter))
    }
}

private struct ManagementFlowsModifier: ViewModifier {
    @Bindable var presenter: ManagementPresenter

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.flow) { flow in
            ContentUnavailableView("Not Yet Available", systemImage: "hammer",
                                   description: Text(flow.id))
                .frame(width: 520, height: 240)
                .toolbar { Button("Close") { presenter.flow = nil } }
        }
    }
}
