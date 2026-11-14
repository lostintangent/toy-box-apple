import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct MemberEditor: View {
    let channel: ChannelDetails
    let store: ChannelStore
    /// The channel's server.
    let catalog: ChannelCatalogStore
    @Bindable var presenter: ManagementPresenter
    @FocusState private var nameFocused: Bool
    /// Removing asks over this editor, so Cancel returns to it unchanged.
    @ViewState private var removal: ManagementFlow?

    private var form: MemberForm { presenter.memberForm }
    private var isSaving: Bool { presenter.isPending }
    private var member: ChannelAgent? { form.member }
    private var nameViolation: String? { form.nameViolation(in: store.roster) }
    private var canSave: Bool {
        form.isSubmittable(in: store.roster) && !isSaving && store.phase.isConnected
    }

    var body: some View {
        ManagementSheetLayout(
            title: member.map { "Edit \($0.name)" } ?? "Add Agent",
            subtitle: member == nil
                ? "Joins \(channel.name) and starts onboarding right away."
                : "Member of \(channel.name)"
        ) {
            if let member {
                AgentAvatarView(agent: member, size: 40)
            } else {
                AddAgentMark(size: 40)
            }
        } fields: {
            Section {
                TextField("Name", text: $presenter.memberForm.name, prompt: Text("Required"))
                    .focused($nameFocused)
                    .onSubmit(submit)
                    .accessibilityHint(nameViolation ?? form.identityHelp)
                    .accessibilityIdentifier("member-name")
                ManagementLongTextField(
                    title: "Role",
                    prompt: "What this agent owns and how it works, including any persona.",
                    text: $presenter.memberForm.role, lines: 5...10, violation: form.roleViolation)
                    .onSubmit(submit)
            } footer: {
                ManagementFooter(help: [form.identityHelp], violation: nameViolation ?? form.roleViolation)
            }
            ModelSelectionFields(
                model: $presenter.memberForm.model, openingModel: member?.model, api: catalog.api, provider: member?.model?.provider, allowsInheritance: true,
                memberScope: member.map { (channel.id, $0.id) },
                help: member.map { ["Model changes apply the next time \($0.name) works. Its history is kept."] } ?? [])
        } notices: {
            ManagementConnectionNotice(store: store)
            if let error = presenter.error { ManagementError(message: error) }
        } buttons: {
            if let member {
                Button("Remove from Channel\u{2026}", role: .destructive) {
                    if let target = store.target { removal = .removeMember(target, agentId: member.id) }
                }
                .disabled(!store.phase.isConnected)
            }
            Spacer()
            Button("Cancel", role: .cancel) { presenter.flow = nil }
                .keyboardShortcut(.cancelAction)
            Button(isSaving
                   ? (member == nil ? "Adding\u{2026}" : "Saving\u{2026}")
                   : (member == nil ? "Add Agent" : "Save")) { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onAppear { nameFocused = true }
        .background {
            Button("Submit") { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
                .disabled(!canSave)
        }
        .managementConfirmation($removal, presenter: presenter, catalogs: [catalog])
    }

    private func submit() {
        guard canSave else { return }
        Task { await presenter.save(on: catalog) }
    }
}
