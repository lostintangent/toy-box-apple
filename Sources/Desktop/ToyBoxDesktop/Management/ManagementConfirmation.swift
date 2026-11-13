import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementConfirmation: View {
    let flow: ManagementFlow
    let channel: ChannelDetails
    let store: ChannelStore
    /// The channel's server.
    let catalog: ChannelCatalogStore
    let presenter: ManagementPresenter
    @ViewState private var isDeleting = false
    @ViewState private var error: String?

    private var member: ChannelAgent? {
        guard case .removeMember(_, let id) = flow else { return nil }
        return store.roster.dropFirst().first { $0.id == id }
    }
    private var routine: ChannelRoutine? {
        guard case .deleteRoutine(_, let id) = flow else { return nil }
        return store.routines.first { $0.id == id }
    }
    private var title: String {
        switch flow {
        case .deleteChannel: "Delete \(channel.name)?"
        case .removeMember: "Remove \(member?.name ?? "agent")?"
        case .deleteRoutine: "Delete \(routine?.title ?? "routine")?"
        default: "Unavailable Action"
        }
    }
    private var consequence: String {
        switch flow {
        case .deleteChannel:
            "This permanently deletes the channel, its public conversation and artifact index, all its agents and their private sessions. Files in the working directory are not deleted. This cannot be undone."
        case .removeMember:
            "This removes the member from \(channel.name) and deletes its private session. Public messages and reactions remain attributed to Deleted agent. This cannot be undone."
        case .deleteRoutine:
            "This stops future scheduled runs of this routine in \(channel.name). It does not stop work that has already started. This cannot be undone."
        default: "This action is not available."
        }
    }
    private var buttonTitle: String {
        switch flow {
        case .deleteChannel: "Delete Channel"
        case .removeMember: "Remove Agent"
        case .deleteRoutine: "Delete Routine"
        default: "Delete"
        }
    }
    private var exists: Bool {
        guard store.phase != .deleted else { return false }
        switch flow {
        case .deleteChannel: return true
        case .removeMember: return member != nil
        case .deleteRoutine: return routine != nil
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(exists ? consequence : "The target is no longer available.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ManagementConnectionNotice(store: store)
            if let error { ManagementError(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { presenter.flow = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button(isDeleting ? "Deleting..." : buttonTitle, role: .destructive) { remove() }
                    .disabled(isDeleting || !exists || !store.phase.isConnected)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isDeleting)
    }

    private func remove() {
        guard !isDeleting, exists, store.phase.isConnected else { return }
        isDeleting = true
        error = nil
        Task {
            defer { isDeleting = false }
            do {
                switch flow {
                case .deleteChannel(let target):
                    try await catalog.api.deleteChannel(id: target.channelID)
                case .removeMember(let target, let agentId):
                    try await catalog.api.removeMember(channelId: target.channelID, agentId: agentId)
                case .deleteRoutine(let target, let routineId):
                    try await catalog.api.deleteRoutine(channelId: target.channelID, routineId: routineId)
                default: return
                }
                presenter.flow = nil
                await catalog.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
