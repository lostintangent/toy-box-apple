import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct MemberEditor: View {
    let channel: ChannelDetails
    let store: ChannelStore
    let presenter: ManagementPresenter
    @Bindable var session: ManagementSession
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(ManagementSessions.self) private var sessions
    @Environment(Overview.self) private var presentation
    @FocusState private var focus: ManagementField?
    @ViewState private var removal: ManagementFlow?

    private var api: ChannelAPI { session.api }
    private var form: MemberForm { session.memberForm }
    private var member: ChannelAgent? { form.member }
    private var saving: Bool { session.pending }
    private var isCurrent: Bool { sessions.isCurrent(session, app: app, presenter: presenter) }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

    private var violation: String? { form.nameViolation(in: store.roster) ?? form.roleViolation }
    private var canSave: Bool { form.isSubmittable(in: store.roster) && !saving && store.phase.isConnected }
    private var catalog: ChannelCatalogStore? {
        app.catalogs.contains { $0 === session.catalog } ? session.catalog : nil
    }

    var body: some View {
        Form {
            if store.phase.isUnavailable { Section { ManagementConnectionNotice(store: store) } }
            if let error = session.error { Section { ManagementError(message: error) } }
            Section {
                LabeledContent {
                    TextField("Name", text: $session.memberForm.name,
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
                TextField("Role", text: $session.memberForm.role,
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
            ModelSelectionFields(model: $session.memberForm.model, openingModel: member?.model,
                                 api: api, provider: member?.model?.provider,
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
                Button(role: .close) { sessions.cancel(session, presenter: presenter) }
                    .accessibilityLabel("Cancel")
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                ManagementConfirmButton(
                    label: member == nil ? (saving ? "Adding…" : "Add Agent") : saving ? "Saving…" : "Save",
                    pendingSince: session.pendingSince, identifier: "member-submit", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            focus = session.focus
        }
        .onChange(of: focus) { _, field in
            if isCurrentHost, isCurrent { session.focus = field }
        }
        .onChange(of: session.focus) { _, field in
            if isCurrentHost { focus = field }
        }
        .managementConfirmation($removal, presenter: presenter)
    }

    private func submit() {
        guard canSave else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        let form = form
        session.pending = true
        session.error = nil
        let catalog = catalog
        Task {
            var failed = false
            do {
                _ = try await form.submit(to: api, channelId: channel.id)
                if isCurrent {
                    if form.member != nil { presenter.flow = nil }
                    else if let target = store.target { presenter.finishAddingMember(target) }
                }
                await catalog?.refresh()
            } catch {
                failed = true
                session.error = error.localizedDescription
            }
            session.pending = false
            if failed, presenter.flow == submittedFlow, isCurrent {
                await Task.yield()
                guard presenter.flow == submittedFlow, isCurrent else { return }
                session.focus = submittedFocus
            }
        }
    }
}
