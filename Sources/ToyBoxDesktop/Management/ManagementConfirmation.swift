import ChannelClient
import ChannelKit
import SwiftUI

struct ManagementConfirmation: View {
    @Environment(AppModel.self) private var app
    let flow: ManagementFlow
    let channel: ChannelDetails
    let store: ChannelStore
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @ViewState private var isDeleting = false
    @ViewState private var recovery = ManagementWriteRecovery()

    private var member: ChannelMember? {
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
        case .removeMember: "Remove \(member?.name ?? "member")?"
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
        case .removeMember: "Remove Member"
        case .deleteRoutine: "Delete Routine"
        default: "Delete"
        }
    }
    private var exists: Bool {
        if store.phase == .deleted || recovery.result?.channelWasDeleted == true { return false }
        let current = recovery.result?.state
        switch flow {
        case .deleteChannel: return true
        case .removeMember(_, let id):
            return current.map { $0.members.contains { $0.id == id } } ?? (member != nil)
        case .deleteRoutine(_, let id):
            return current.map { $0.routines.contains { $0.id == id } } ?? (routine != nil)
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
            if let error = recovery.error { ManagementError(message: error) }
            if let state = recovery.state {
                ManagementRecoveryNotice(
                    state: state, reviewTitle: exists ? "Review Deletion Again" : nil,
                    onCheck: { Task { await checkCurrentState() } },
                    onReview: recovery.finishReview)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { presenter.flow = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button(isDeleting ? "Deleting..." : buttonTitle, role: .destructive) { remove() }
                    .disabled(isDeleting || recovery.blocksWrites || !exists || !store.phase.isLive)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isDeleting)
    }

    private func remove() {
        guard !isDeleting, !recovery.blocksWrites, exists, store.phase.isLive else { return }
        isDeleting = true
        recovery.clearError()
        Task {
            defer { isDeleting = false }
            do {
                switch flow {
                case .deleteChannel(let channelId):
                    try await api.deleteChannel(id: channelId)
                case .removeMember(let channelId, let agentId):
                    try await api.removeMember(channelId: channelId, agentId: agentId)
                case .deleteRoutine(let channelId, let routineId):
                    try await api.deleteRoutine(channelId: channelId, routineId: routineId)
                default: return
                }
                presenter.flow = nil
                await app.catalog?.refresh()
            } catch {
                if recovery.record(error) { await checkCurrentState() }
            }
        }
    }

    private func checkCurrentState() async {
        await recovery.check(catalog: app.catalog, channelId: store.id) { current in
            let stillExists: Bool
            if current.channelWasDeleted {
                stillExists = false
            } else {
                switch flow {
                case .deleteChannel:
                    stillExists = current.state != nil
                case .removeMember(_, let id):
                    stillExists = current.state?.members.contains { $0.id == id } == true
                case .deleteRoutine(_, let id):
                    stillExists = current.state?.routines.contains { $0.id == id } == true
                default:
                    stillExists = false
                }
            }
            return stillExists
                ? "The target is still present in current server state. Review the deletion consequences again before explicitly trying another deletion."
                : "The target is no longer present in current server state. The deletion was not repeated."
        }
    }
}
