import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ManagementConfirmation: View {
    let flow: ManagementFlow
    let channel: ChannelDetails
    let store: ChannelStore
    let presenter: ManagementPresenter
    @Bindable var session: ManagementSession
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(ManagementSessions.self) private var sessions
    @Environment(OverviewPresentation.self) private var presentation
    private var api: ChannelAPI { session.api }
    private var deleting: Bool { session.pending }
    private var recovery: ChannelManagementWriteRecovery { session.recovery }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

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
        app.catalog === session.catalog ? session.catalog : nil
    }

    var body: some View {
        Form {
            Section {
                Text(title).font(.headline)
                Text(exists ? consequence : "The target is no longer available.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.phase.isUnavailable { Section { ManagementConnectionNotice(store: store) } }
            if let error = recovery.error { Section { ManagementError(message: error) } }
            if let state = recovery.state {
                Section {
                    ManagementRecoveryNotice(
                        state: state, reviewTitle: exists ? "Review Deletion Again" : nil,
                        onCheck: { Task { await check(catalog: catalog) } }, onReview: recovery.finishReview)
                }
            }
            Section {
                Button(role: .destructive) {
                    session.isConfirmationPresented = true
                } label: {
                    ManagementActionLabel(
                        title: deleting ? "Deleting…" : buttonTitle, pendingSince: session.pendingSince)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("management-review-delete")
                .disabled(deleting || recovery.blocksWrites || !exists || !store.phase.isConnected)
            }
        }
        .navigationTitle(buttonTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { sessions.cancel(session, presenter: presenter) }.disabled(deleting)
            }
        }
        .interactiveDismissDisabled(deleting)
        .alert(title, isPresented: Binding(
            get: { isCurrentHost && session.isConfirmationPresented },
            set: { if isCurrentHost { session.isConfirmationPresented = $0 } }
        )) {
            Button(buttonTitle, role: .destructive, action: remove)
                .accessibilityIdentifier("management-confirm-delete")
                .disabled(deleting || recovery.blocksWrites || !exists || !store.phase.isConnected)
            Button("Cancel", role: .cancel) { sessions.cancel(session, presenter: presenter) }
                .accessibilityIdentifier("management-confirm-cancel")
        } message: {
            Text(consequence)
        }
        .task(id: store.phase.isConnected) {
            guard isCurrentHost, sessions.isCurrent(session, app: app, presenter: presenter),
                  exists, store.phase.isConnected, !session.hasRequestedConfirmation else { return }
            session.hasRequestedConfirmation = true
            session.isConfirmationPresented = true
        }
    }

    private func remove() {
        guard !deleting, !recovery.blocksWrites, exists, store.phase.isConnected else { return }
        session.pending = true
        recovery.clearError()
        let catalog = catalog
        Task {
            defer { session.pending = false }
            do {
                switch flow {
                case .deleteChannel(let id): try await api.deleteChannel(id: id)
                case .removeMember(let id, let agentID): try await api.removeMember(channelId: id, agentId: agentID)
                case .deleteRoutine(let id, let routineID): try await api.deleteRoutine(channelId: id, routineId: routineID)
                default: throw ChannelAPIError.invalidMessage("This management action is unavailable.")
                }
                if sessions.isCurrent(session, app: app, presenter: presenter) { presenter.flow = nil }
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
