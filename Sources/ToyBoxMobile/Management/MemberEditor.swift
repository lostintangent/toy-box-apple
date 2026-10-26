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
    @Environment(OverviewPresentation.self) private var presentation
    @FocusState private var focus: ManagementField?

    private var api: ChannelAPI { session.api }
    private var member: ChannelMember? { session.member }
    private var name: String { session.name }
    private var role: String { session.role }
    private var model: ModelConfiguration? { session.model }
    private var saving: Bool { session.pending }
    private var recovery: ChannelManagementWriteRecovery { session.recovery }
    private var isCurrent: Bool { sessions.isCurrent(session, app: app, presenter: presenter) }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

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
        app.catalog === session.catalog ? session.catalog : nil
    }
    private var refreshedMember: ChannelMember? {
        guard let member else { return nil }
        return recovery.result?.state?.members.first { $0.id == member.id }
    }

    var body: some View {
        Form {
            Section {
                Text(member == nil ? "Joins \(channel.name) and starts onboarding right away." : "Member of \(channel.name).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("Name", text: $session.name, prompt: Text("Required"))
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .role }
                    .accessibilityIdentifier("member-name")
                TextField("Role", text: $session.role,
                          prompt: Text("What this agent owns and how it works, including its persona."), axis: .vertical)
                    .lineLimit(5...10)
                    .focused($focus, equals: .role)
                    .accessibilityIdentifier("member-role")
            } footer: {
                if let violation { Label(violation, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                Text(nextName.isEmpty ? "Names are unique in this channel."
                     : "Mentioned as @\(agentHandleFromName(nextName)). Names are unique in this channel.")
            }
            ModelSelectionFields(model: $session.model, openingModel: session.openingModel,
                                 api: api, provider: member?.model?.provider,
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
                Button("Cancel", role: .cancel) { sessions.cancel(session, presenter: presenter) }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: submit) {
                    ManagementActionLabel(
                        title: saving ? (member == nil ? "Adding…" : "Saving…") : member == nil ? "Add Agent" : "Save",
                        pendingSince: session.pendingSince)
                }
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
    }

    private func submit() {
        guard canSave else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        session.pending = true
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
                    if isCurrent { presenter.flow = nil }
                } else {
                    _ = try await api.createMember(
                        channelId: channel.id, input: .init(name: nextName, role: nextRole.isEmpty ? nil : nextRole, model: model))
                    if isCurrent { presenter.finishAddingMember(channelId: channel.id) }
                }
                await catalog?.refresh()
            } catch {
                failed = true
                if recovery.record(error) { await check(catalog: catalog) }
            }
            session.pending = false
            if failed, presenter.flow == submittedFlow, isCurrent {
                await Task.yield()
                guard presenter.flow == submittedFlow, isCurrent else { return }
                session.focus = submittedFocus
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
        session.member = current
        session.name = current.name
        session.role = current.role ?? ""
        session.model = current.model
        recovery.finishReview()
    }
}
