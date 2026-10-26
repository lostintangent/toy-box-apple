import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct MemberEditor: View {
    @Environment(AppModel.self) private var app
    let channel: ChannelDetails
    @ViewState private var member: ChannelMember?
    let store: ChannelStore
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @ViewState private var name: String
    @ViewState private var role: String
    @ViewState private var model: ModelConfiguration?
    @ViewState private var isSaving = false
    @ViewState private var recovery = ChannelManagementWriteRecovery()
    @FocusState private var nameFocused: Bool

    init(channel: ChannelDetails, member: ChannelMember?, initialName: String, store: ChannelStore,
         api: ChannelAPI, presenter: ManagementPresenter) {
        self.channel = channel
        _member = ViewState(initialValue: member)
        self.store = store
        self.api = api
        self.presenter = presenter
        _name = ViewState(initialValue: initialName)
        _role = ViewState(initialValue: member?.role ?? "")
        _model = ViewState(initialValue: member?.model)
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var handle: String { agentHandleFromName(nextName) }
    // An empty name only disables the default button. The prompt already says Required.
    private var nameViolation: String? {
        guard !nextName.isEmpty else { return nil }
        return ChannelValidation.memberNameError(nextName, agents: store.roster, excludingID: member?.id)
    }
    private var roleViolation: String? {
        ChannelValidation.memberRoleError(nextRole, existingRole: member?.role)
    }
    private var isValid: Bool { !nextName.isEmpty && nameViolation == nil && roleViolation == nil }
    private var hasChanges: Bool {
        guard let member else { return true }
        return nextName != member.name || nextRole != (member.role ?? "") || model != member.model
    }
    private var canSave: Bool {
        isValid && hasChanges && !isSaving && !recovery.blocksWrites && store.phase.isLive
    }
    private var refreshedMember: ChannelMember? {
        guard let member else { return nil }
        return recovery.result?.state?.members.first { $0.id == member.id }
    }
    private var identityHelp: String {
        nextName.isEmpty
            ? "Names are unique in this channel."
            : "Mentioned as @\(handle). Names are unique in this channel."
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
                TextField("Name", text: $name, prompt: Text("Required"))
                    .focused($nameFocused)
                    .onSubmit(submit)
                    .accessibilityHint(nameViolation ?? identityHelp)
                    .accessibilityIdentifier("member-name")
                ManagementLongTextField(
                    title: "Role",
                    prompt: "What this agent owns and how it works, including any persona.",
                    text: $role, lines: 5...10, violation: roleViolation)
                    .onSubmit(submit)
            } footer: {
                ManagementFooter(help: [identityHelp], violation: nameViolation ?? roleViolation)
            }
            ModelSelectionFields(
                model: $model, api: api, provider: member?.model?.provider, allowsInheritance: true,
                memberScope: member.map { (channel.id, $0.id) },
                help: member.map { ["Model changes apply the next time \($0.name) works. Its history is kept."] } ?? [])
        } notices: {
            ManagementConnectionNotice(store: store)
            if let error = recovery.error { ManagementError(message: error) }
            if let state = recovery.state {
                ManagementRecoveryNotice(
                    state: state, reviewTitle: refreshedMember == nil ? nil : "Use Current Server Values",
                    onCheck: { Task { await checkCurrentState() } },
                    onReview: useCurrentServerValues)
            }
        } buttons: {
            if let member {
                Button("Remove from Channel\u{2026}", role: .destructive) {
                    presenter.present(.removeMember(channelId: channel.id, agentId: member.id))
                }
                .disabled(recovery.blocksWrites || !store.phase.isLive)
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
    }

    private func submit() {
        guard canSave else { return }
        isSaving = true
        recovery.clearError()
        Task {
            defer { isSaving = false }
            do {
                if let member {
                    _ = try await api.editMember(
                        channelId: channel.id, agentId: member.id,
                        changes: .init(name: nextName == member.name ? nil : nextName,
                                       role: nextRole == (member.role ?? "") ? nil : nextRole,
                                       model: model == member.model ? nil : model.map { .set($0) } ?? .clear))
                    presenter.flow = nil
                } else {
                    _ = try await api.createMember(
                        channelId: channel.id,
                        input: .init(name: nextName, role: nextRole.isEmpty ? nil : nextRole, model: model))
                    presenter.finishAddingMember(channelId: channel.id)
                }
                await app.catalog?.refresh()
            } catch {
                if recovery.record(error) { await checkCurrentState() }
            }
        }
    }

    private func checkCurrentState() async {
        await recovery.check(catalog: app.catalog, channelId: channel.id) { current in
            if current.channelWasDeleted {
                return "The channel is no longer present on the server. No further member changes are available."
            }
            if let member {
                guard let refreshed = current.state?.members.first(where: { $0.id == member.id }) else {
                    return "This member is no longer present on the server. No further save is available."
                }
                return "The server's current member is \(refreshed.name). Your entries are preserved. Use Current Server Values replaces them with the refreshed name, role and model override."
            }
            return "The channel's team has been refreshed. Close this sheet and review Team before adding another agent. Your entries are preserved until you close the sheet."
        }
    }

    private func useCurrentServerValues() {
        guard let current = refreshedMember else { return }
        member = current
        name = current.name
        role = current.role ?? ""
        model = current.model
        recovery.finishReview()
    }
}
