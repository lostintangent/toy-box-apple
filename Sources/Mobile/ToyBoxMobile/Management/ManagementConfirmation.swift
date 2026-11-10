import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

extension ManagementFlow {
    /// Deleting asks in one alert over the screen that asked, never in a sheet.
    var isDeletion: Bool {
        switch self {
        case .deleteChannel, .removeMember, .deleteRoutine: true
        default: false
        }
    }

    /// Whether the server's checked state still holds what this deletion targets.
    func remains(in current: ChannelManagementReconciliation) -> Bool {
        guard !current.channelWasDeleted, let state = current.state else { return false }
        switch self {
        case .removeMember(_, let id): return state.members.contains { $0.id == id }
        case .deleteRoutine(_, let id): return state.routines.contains { $0.id == id }
        default: return true
        }
    }

    fileprivate var deletionCopy: (verb: String, noun: String, action: String, outcome: String) {
        switch self {
        case .removeMember: ("Remove", "agent", "Remove Agent", "Agent Removed")
        case .deleteRoutine: ("Delete", "routine", "Delete Routine", "Routine Deleted")
        default: ("Delete", "channel", "Delete Channel", "Channel Deleted")
        }
    }
}

extension ManagementSession {
    enum DeletionStep: Equatable {
        case confirm, failed(String), checkFailed(String), remains(String), gone(String)
    }

    /// What the alert asks next. It asks nothing while the delete or its check is in flight.
    var deletionStep: DeletionStep? {
        if pending { return nil }
        switch recovery.state {
        case nil: return recovery.error.map(DeletionStep.failed) ?? .confirm
        case .checking: return nil
        case .checkFailed(let message): return .checkFailed(message)
        case .reconciled(let message):
            return recovery.result.map(flow.remains) == true ? .remains(message) : .gone(message)
        }
    }

    /// Sends the delete once. An uncertain failure checks the server before the alert offers anything else.
    func delete() async -> Bool {
        guard !pending, !recovery.blocksWrites else { return false }
        pending = true
        recovery.clearError()
        defer { pending = false }
        do {
            switch flow {
            case .deleteChannel(let target): try await api.deleteChannel(id: target.channelID)
            case .removeMember(let target, let agentID):
                try await api.removeMember(channelId: target.channelID, agentId: agentID)
            case .deleteRoutine(let target, let routineID):
                try await api.deleteRoutine(channelId: target.channelID, routineId: routineID)
            default: throw ChannelAPIError.invalidMessage("This management action is unavailable.")
            }
            return true
        } catch {
            if recovery.record(error) { await checkDeletion() }
            return false
        }
    }

    func checkDeletion() async {
        await recovery.check(catalog: catalog, channelId: flow.channelId) { [flow] current in
            flow.remains(in: current)
                ? "The server couldn't confirm the change, and the \(flow.deletionCopy.noun) is still there."
                : "The server couldn't confirm the change, but the \(flow.deletionCopy.noun) is gone now."
        }
    }
}

/// A deletion's single alert, over the screen that asked. Its session lives in `ManagementSessions`, so
/// a delete in flight survives the host moving, and the flow stays set until the alert is answered.
struct ManagementConfirmation: ViewModifier {
    @Binding var flow: ManagementFlow?
    let presenter: ManagementPresenter
    // Optional, so screens rendered without an app simply have nothing to delete.
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(ManagementSessions.self) private var sessions: ManagementSessions?

    private var deletion: ManagementFlow? { flow?.isDeletion == true ? flow : nil }
    private var copy: (verb: String, noun: String, action: String, outcome: String) {
        (deletion ?? .newChannel(server: "")).deletionCopy
    }
    /// The deletion's server.
    private var catalog: ChannelCatalogStore? { app.flatMap { deletion?.catalog(in: $0.catalogs) } }
    /// Agents and routines are deleted from their channel's screens, which hold its store.
    private var store: ChannelStore? { deletion?.channelId.flatMap { catalog?.existingChannel(id: $0) } }
    /// The target's name, or nil once it's gone.
    private var target: String? {
        switch deletion {
        case .deleteChannel(let target): catalog?.channels.first { $0.id == target.channelID }?.name
        case .removeMember(_, let id): store?.roster.dropFirst().first { $0.id == id }?.name
        case .deleteRoutine(_, let id): store?.routines.first { $0.id == id }?.title
        default: nil
        }
    }
    private var canDelete: Bool {
        guard target != nil else { return false }
        if case .deleteChannel = deletion { return app?.isActive == true && catalog?.phase == .connected }
        return store?.phase.isConnected == true
    }
    private var consequence: String {
        guard target != nil else { return "This \(copy.noun) is no longer available." }
        return switch deletion {
        case .removeMember:
            "This removes the member from \(store?.details?.name ?? "the channel") and deletes its private session. Public messages and reactions remain attributed to Deleted agent. This cannot be undone."
        case .deleteRoutine:
            "This stops future scheduled runs of this routine in \(store?.details?.name ?? "the channel"). It does not stop work that has already started. This cannot be undone."
        default:
            "This permanently deletes the channel, its public conversation and artifact index, all its agents and their private sessions. Files in the working directory are not deleted. This cannot be undone."
        }
    }

    func body(content: Content) -> some View {
        let session = deletion.flatMap { flow in catalog.flatMap { sessions?.session(for: flow, catalog: $0) } }
        let step = session?.deletionStep
        let text = text(step)
        // Every answer changes the session or the flow at once, so the alert never re-reads its old step.
        content.alert(text.title, isPresented: Binding(get: { step != nil }, set: { _ in })) {
            if let session { actions(step, session: session) }
        } message: {
            Text(text.message)
        }
    }

    private func text(_ step: ManagementSession.DeletionStep?) -> (title: String, message: String) {
        switch step {
        case .failed(let message), .remains(let message): ("Couldn't \(copy.action)", message)
        case .checkFailed(let message):
            ("Couldn't Check the Server", "The server couldn't confirm the change, so it wasn't sent again. \(message)")
        case .gone(let message): (copy.outcome, message)
        case .confirm, nil: ("\(copy.verb) \(target ?? copy.noun)?", consequence)
        }
    }

    @ViewBuilder
    private func actions(_ step: ManagementSession.DeletionStep?, session: ManagementSession) -> some View {
        switch step {
        case .confirm, .remains:
            Button(copy.action, role: .destructive) { delete(session) }.disabled(!canDelete)
            Button("Cancel", role: .cancel) { close(session) }
        case .checkFailed:
            Button("Check Again") { Task.immediate { await session.checkDeletion() } }
            Button("Cancel", role: .cancel) { close(session) }
        case .failed, .gone, nil:
            Button("OK", role: .cancel) { close(session) }
        }
    }

    /// A failed check keeps blocking writes, so reopening the alert checks again before it deletes.
    private func close(_ session: ManagementSession) {
        if case .gone = session.deletionStep { presenter.flow = nil }
        session.recovery.finishReview()
        session.recovery.clearError()
        flow = nil
    }

    private func delete(_ session: ManagementSession) {
        guard canDelete else { return }
        let origin = presenter.flow
        session.recovery.finishReview()
        Task.immediate {
            guard await session.delete() else { return }
            if presenter.flow == origin { presenter.flow = nil }
            await session.catalog.refresh()
        }
    }
}

extension View {
    /// Hosts the alert for a deletion `flow`. Every other flow is left to the host's sheet.
    func managementConfirmation(_ flow: Binding<ManagementFlow?>, presenter: ManagementPresenter) -> some View {
        modifier(ManagementConfirmation(flow: flow, presenter: presenter))
    }

    /// Hosts the presenter's deletions while `hosting`, so only the frontmost screen asks.
    func managementConfirmation(presenter: ManagementPresenter, hosting: Bool) -> some View {
        managementConfirmation(Binding(get: { hosting ? presenter.flow : nil }, set: { presenter.flow = $0 }), presenter: presenter)
    }
}
