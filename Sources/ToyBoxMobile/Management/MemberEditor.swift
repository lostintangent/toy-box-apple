import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct MemberEditor: View {
    private enum Field { case name, role }
    let channel: ChannelDetails
    let store: ChannelStore
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @Environment(AppModel.self) private var app
    @ViewState private var member: ChannelMember?
    @ViewState private var name: String
    @ViewState private var role: String
    @ViewState private var model: ModelConfiguration?
    @ViewState private var saving = false
    @ViewState private var recovery = ChannelManagementWriteRecovery()
    @FocusState private var focus: Field?

    init(channel: ChannelDetails, member: ChannelMember?, initialName: String, store: ChannelStore,
         api: ChannelAPI, presenter: ManagementPresenter) {
        self.channel = channel
        self.store = store
        self.api = api
        self.presenter = presenter
        _member = ViewState(initialValue: member)
        _name = ViewState(initialValue: initialName)
        _role = ViewState(initialValue: member?.role ?? "")
        _model = ViewState(initialValue: member?.model)
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var violation: String? {
        (nextName.isEmpty ? nil : ChannelValidation.memberNameError(nextName, agents: store.roster, excludingID: member?.id))
            ?? ChannelValidation.memberRoleError(nextRole, existingRole: member?.role)
    }
    private var changed: Bool {
        guard let member else { return true }
        return nextName != member.name || nextRole != (member.role ?? "") || model != member.model
    }
    private var canSave: Bool {
        !nextName.isEmpty && violation == nil && changed && !saving && !recovery.blocksWrites && store.phase.isLive
    }
    private var catalog: ChannelCatalogStore? {
        app.catalog.flatMap { $0.api.baseURL == api.baseURL ? $0 : nil }
    }
    private var refreshedMember: ChannelMember? {
        guard let member else { return nil }
        return recovery.result?.state?.members.first { $0.id == member.id }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Required"))
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .role }
                    .accessibilityIdentifier("member-name")
                TextField("Role", text: $role,
                          prompt: Text("What this agent owns and how it works, including its persona."), axis: .vertical)
                    .lineLimit(5...14)
                    .focused($focus, equals: .role)
                    .accessibilityIdentifier("member-role")
            } footer: {
                if let violation { Text(violation).foregroundStyle(.red) }
                Text(nextName.isEmpty ? "Names are unique in this channel."
                     : "Mentioned as @\(agentHandleFromName(nextName)). Names are unique in this channel.")
            }
            ModelSelectionFields(model: $model, api: api, provider: member?.model?.provider,
                                 allowsInheritance: true, memberScope: member.map { (channel.id, $0.id) },
                                 help: member.map { ["Model changes apply the next time \($0.name) works. Its history is kept."] } ?? [])
            if let member {
                Section {
                    Button("Remove from Channel", systemImage: "person.badge.minus", role: .destructive) {
                        presenter.present(.removeMember(channelId: channel.id, agentId: member.id))
                    }
                    .disabled(recovery.blocksWrites || !store.phase.isLive)
                }
            }
            if !store.phase.isLive { Section { ManagementConnectionNotice(store: store) } }
            if let error = recovery.error { Section { ManagementError(message: error) } }
            if let state = recovery.state {
                Section {
                    ManagementRecoveryNotice(
                        state: state, reviewTitle: refreshedMember == nil ? nil : "Use Current Server Values",
                        onCheck: { Task { await check(catalog: catalog) } }, onReview: useCurrentValues)
                }
            }
        }
        .disabled(saving)
        .navigationTitle(member == nil ? "Add Agent" : "Edit Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { presenter.flow = nil }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? (member == nil ? "Adding…" : "Saving…") : member == nil ? "Add" : "Save",
                       action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { focus = .name }
    }

    private func submit() {
        guard canSave else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        saving = true
        recovery.clearError()
        let catalog = catalog
        Task {
            var failed = false
            do {
                if let member {
                    _ = try await api.editMember(
                        channelId: channel.id, agentId: member.id,
                        changes: .init(name: nextName == member.name ? nil : nextName,
                                       role: nextRole == (member.role ?? "") ? nil : nextRole,
                                       model: model == member.model ? nil : model.map { .set($0) } ?? .clear))
                    if app.api?.baseURL == api.baseURL { presenter.flow = nil }
                } else {
                    _ = try await api.createMember(
                        channelId: channel.id, input: .init(name: nextName, role: nextRole.isEmpty ? nil : nextRole, model: model))
                    if app.api?.baseURL == api.baseURL { presenter.finishAddingMember(channelId: channel.id) }
                }
                await catalog?.refresh()
            } catch {
                failed = true
                if recovery.record(error) { await check(catalog: catalog) }
            }
            saving = false
            if failed, presenter.flow == submittedFlow, app.api?.baseURL == api.baseURL {
                await Task.yield()
                guard presenter.flow == submittedFlow, app.api?.baseURL == api.baseURL else { return }
                focus = submittedFocus
            }
        }
    }

    private func check(catalog: ChannelCatalogStore?) async {
        await recovery.check(catalog: catalog, channelId: channel.id) { current in
            if current.channelWasDeleted { return "The channel is no longer present on the server. No further member changes are available." }
            if let member {
                guard let refreshed = current.state?.members.first(where: { $0.id == member.id }) else {
                    return "This member is no longer present on the server. No further save is available."
                }
                return "The server's current member is \(refreshed.name). Your entries are preserved. Use Current Server Values replaces them with the refreshed name, role and model override."
            }
            return "The channel's team has been refreshed. Close this sheet and review Team before adding another agent. Your entries are preserved until you close the sheet."
        }
    }

    private func useCurrentValues() {
        guard let current = refreshedMember else { return }
        member = current
        name = current.name
        role = current.role ?? ""
        model = current.model
        recovery.finishReview()
    }
}
