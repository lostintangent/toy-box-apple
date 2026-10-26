import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementConfirmation: View {
    let flow: ManagementFlow
    let channel: ChannelDetails
    let store: ChannelStore
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @Environment(AppModel.self) private var app
    @ViewState private var deleting = false
    @ViewState private var recovery = ChannelManagementWriteRecovery()

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
        if store.phase == .deleted || recovery.result?.channelWasDeleted == true { return false }
        switch flow {
        case .deleteChannel: return true
        case .removeMember(_, let id):
            return recovery.result?.state.map { $0.members.contains { $0.id == id } } ?? (member != nil)
        case .deleteRoutine(_, let id):
            return recovery.result?.state.map { $0.routines.contains { $0.id == id } } ?? (routine != nil)
        default: return false
        }
    }
    private var catalog: ChannelCatalogStore? {
        app.catalog.flatMap { $0.api.baseURL == api.baseURL ? $0 : nil }
    }

    var body: some View {
        Form {
            Section {
                Text(title).font(.headline)
                Text(exists ? consequence : "The target is no longer available.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.phase.isLive { Section { ManagementConnectionNotice(store: store) } }
            if let error = recovery.error { Section { ManagementError(message: error) } }
            if let state = recovery.state {
                Section {
                    ManagementRecoveryNotice(
                        state: state, reviewTitle: exists ? "Review Deletion Again" : nil,
                        onCheck: { Task { await check(catalog: catalog) } }, onReview: recovery.finishReview)
                }
            }
            Section {
                Button(deleting ? "Deleting…" : buttonTitle, role: .destructive, action: remove)
                    .frame(minHeight: 44)
                    .disabled(deleting || recovery.blocksWrites || !exists || !store.phase.isLive)
            }
        }
        .navigationTitle(buttonTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { presenter.flow = nil }.disabled(deleting)
            }
        }
        .interactiveDismissDisabled(deleting)
    }

    private func remove() {
        guard !deleting, !recovery.blocksWrites, exists, store.phase.isLive else { return }
        deleting = true
        recovery.clearError()
        let catalog = catalog
        Task {
            defer { deleting = false }
            do {
                switch flow {
                case .deleteChannel(let id): try await api.deleteChannel(id: id)
                case .removeMember(let id, let agentID): try await api.removeMember(channelId: id, agentId: agentID)
                case .deleteRoutine(let id, let routineID): try await api.deleteRoutine(channelId: id, routineId: routineID)
                default: throw ChannelAPIError.invalidMessage("This management action is unavailable.")
                }
                if app.api?.baseURL == api.baseURL { presenter.flow = nil }
                await catalog?.refresh()
            } catch {
                if recovery.record(error) { await check(catalog: catalog) }
            }
        }
    }

    private func check(catalog: ChannelCatalogStore?) async {
        await recovery.check(catalog: catalog, channelId: channel.id) { current in
            let present: Bool
            if current.channelWasDeleted { present = false }
            else {
                switch flow {
                case .deleteChannel: present = current.state != nil
                case .removeMember(_, let id): present = current.state?.members.contains { $0.id == id } == true
                case .deleteRoutine(_, let id): present = current.state?.routines.contains { $0.id == id } == true
                default: present = false
                }
            }
            return present
                ? "The target is still present in current server state. Review the deletion consequences again before explicitly trying another deletion."
                : "The target is no longer present in current server state. The deletion was not repeated."
        }
    }
}
