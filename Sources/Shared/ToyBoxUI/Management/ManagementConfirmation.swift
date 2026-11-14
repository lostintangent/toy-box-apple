import ChannelClient
import ChannelKit
import SwiftUI

extension ManagementFlow {
    fileprivate var words: (verb: String, noun: String, action: String) {
        switch self {
        case .removeMember: ("Remove", "agent", "Remove Agent")
        case .deleteRoutine: ("Delete", "routine", "Delete Routine")
        default: ("Delete", "channel", "Delete Channel")
        }
    }
}

/// A deletion's single system alert, over the place that asked. The presenter holds the delete in
/// flight, so the alert survives its host moving, and the flow stays set until the alert is answered.
private struct ManagementConfirmation: ViewModifier {
    @Binding var flow: ManagementFlow?
    let presenter: ManagementPresenter
    let catalogs: [ChannelCatalogStore]
    let isActive: Bool

    private var deletion: ManagementFlow? { flow?.isDeletion == true ? flow : nil }
    private var words: (verb: String, noun: String, action: String) { (deletion ?? .newChannel(server: "")).words }
    /// The deletion's server.
    private var catalog: ChannelCatalogStore? { deletion?.catalog(in: catalogs) }
    /// Agents and routines are deleted from their channel's screens, which hold its store.
    private var store: ChannelStore? { deletion?.target.flatMap { catalog?.existingChannel(id: $0.channelID) } }
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
        if case .deleteChannel = deletion { return isActive && catalog?.phase == .connected }
        return store?.phase.isConnected == true
    }
    private var consequence: String {
        guard target != nil else { return "This \(words.noun) is no longer available." }
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
        // Nil while it asks, false while the delete is in flight and true once it failed.
        let failed = deletion.flatMap { flow in presenter.deletion.flatMap { $0.flow == flow ? $0.failed : nil } }
        let isPresented = deletion != nil && catalog != nil && failed != false
        // Every answer changes the presenter or the flow at once, so the alert never re-reads its old step.
        content.alert(failed == true ? "Couldn't \(words.action)" : "\(words.verb) \(target ?? words.noun)?",
                      isPresented: Binding(get: { isPresented }, set: { _ in })) {
            if failed == true {
                Button("OK", role: .cancel, action: close)
            } else {
                Button(words.action, role: .destructive, action: delete).disabled(!canDelete)
                Button("Cancel", role: .cancel, action: close)
            }
        } message: {
            if failed != true { Text(consequence) }
        }
    }

    private func close() {
        presenter.deletion = nil
        flow = nil
    }

    private func delete() {
        guard canDelete, let deletion, let catalog else { return }
        // It starts at once, so the alert never asks again while it's in flight.
        Task.immediate { await presenter.delete(deletion, on: catalog) }
    }
}

extension View {
    /// Asks about a deletion `flow` in one system alert. Every other flow is left to the host's sheet.
    public func managementConfirmation(_ flow: Binding<ManagementFlow?>, presenter: ManagementPresenter,
                                       catalogs: [ChannelCatalogStore], isActive: Bool = true) -> some View {
        modifier(ManagementConfirmation(flow: flow, presenter: presenter, catalogs: catalogs, isActive: isActive))
    }
}
