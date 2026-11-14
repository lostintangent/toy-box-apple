import ToyBoxClient
import ToyBoxKit
import SwiftUI
import ToyBoxUI

struct MemberEditor: View {
    let flow: ManagementFlow
    let channel: ChannelDetails
    let store: ChannelStore
    @Bindable var presenter: ManagementPresenter
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(Overview.self) private var presentation
    @FocusState private var focus: ManagementField?
    @ViewState private var removal: ManagementFlow?

    private var form: MemberForm { presenter.memberForm }
    private var member: ChannelAgent? { form.member }
    private var saving: Bool { presenter.isPending }
    /// A sheet that's leaving leaves the presenter alone.
    private var isCurrent: Bool { presenter.flow?.id == flow.id }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

    private var violation: String? { form.nameViolation(in: store.roster) ?? form.roleViolation }
    private var catalog: ChannelCatalogStore? { flow.catalog(in: app.catalogs) }
    private var canSave: Bool {
        form.isSubmittable(in: store.roster) && !saving && catalog != nil && store.phase.isConnected
    }

    var body: some View {
        Form {
            if store.phase.isUnavailable { Section { ManagementConnectionNotice(store: store) } }
            if let error = presenter.error { Section { ManagementError(message: error) } }
            Section {
                LabeledContent {
                    TextField("Name", text: $presenter.memberForm.name,
                              prompt: Text("Required").foregroundStyle(ChannelInk.secondary))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .role }
                        .accessibilityIdentifier("member-name")
                } label: {
                    Text("Name").accessibilityIdentifier("member-name-label")
                }
                TextField("Role", text: $presenter.memberForm.role,
                          prompt: Text("What is this agent's role in the channel?")
                            .foregroundStyle(ChannelInk.secondary),
                          axis: .vertical)
                    .lineLimit(5...10)
                    .focused($focus, equals: .role)
                    .accessibilityIdentifier("member-role")
            } footer: {
                if let violation { ManagementError(message: violation, systemImage: "exclamationmark.circle.fill") }
                Text(form.identityHelp).foregroundStyle(ChannelInk.secondary)
            }
            ModelSelectionFields(model: $presenter.memberForm.model, openingModel: member?.model,
                                 api: store.api, provider: member?.model?.provider,
                                 allowsInheritance: true, memberScope: member.map { (channel.id, $0.id) },
                                 help: member.map { ["Model changes apply the next time \($0.name) works. Its history is kept."] } ?? [])
            if let member {
                Section {
                    Button("Remove from Channel", systemImage: "person.badge.minus", role: .destructive) {
                        if let target = store.target { removal = .removeMember(target, agentId: member.id) }
                    }
                    .disabled(!store.phase.isConnected)
                }
            }
        }
        .accessibilityIdentifier("member-editor-form")
        .disabled(saving)
        .navigationTitle(member == nil ? "Add Agent" : "Edit Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { if isCurrent { presenter.flow = nil } }
                    .accessibilityLabel("Cancel")
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ManagementConfirmButton(
                    label: member == nil ? (saving ? "Adding…" : "Add Agent") : saving ? "Saving…" : "Save",
                    pendingSince: presenter.pendingSince, identifier: "member-submit", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            focus = presenter.focus
        }
        .onChange(of: focus) { _, field in
            if isCurrentHost, isCurrent { presenter.focus = field }
        }
        .onChange(of: presenter.focus) { _, field in
            if isCurrentHost { focus = field }
        }
        .managementConfirmation($removal, presenter: presenter)
    }

    private func submit() {
        guard canSave, let catalog else { return }
        Task { await presenter.save(on: catalog) }
    }
}
