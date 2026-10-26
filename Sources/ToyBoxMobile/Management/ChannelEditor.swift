import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    let store: ChannelStore?
    let presenter: ManagementPresenter
    @Bindable var session: ManagementSession
    let host: OverviewPlacement?
    @Environment(AppModel.self) private var app
    @Environment(ManagementSessions.self) private var sessions
    @Environment(OverviewPresentation.self) private var presentation
    @FocusState private var focus: ManagementField?

    private var api: ChannelAPI { session.api }
    private var channel: ChannelDetails? { session.channel }
    private var name: String { session.name }
    private var purpose: String { session.purpose }
    private var model: ModelConfiguration? { session.model }
    private var saving: Bool { session.pending }
    private var recovery: ChannelManagementWriteRecovery { session.recovery }
    private var isCurrent: Bool { sessions.isCurrent(session, app: app, presenter: presenter) }
    private var isCurrentHost: Bool { host == nil || host == presentation.placement }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var violation: String? {
        (nextName.isEmpty ? nil : ChannelValidation.channelNameError(nextName)) ?? ChannelValidation.purposeError(nextPurpose)
    }
    private var changed: Bool {
        guard let channel else { return true }
        return nextName != channel.name || nextPurpose != (channel.purpose ?? "") || model != channel.model
    }
    private var canSave: Bool {
        !nextName.isEmpty && model != nil && violation == nil && changed && !saving && !recovery.blocksWrites
            && (store == nil || store?.phase.isLive == true)
    }
    private var catalog: ChannelCatalogStore? {
        app.catalog === session.catalog ? session.catalog : nil
    }

    var body: some View {
        Form {
            if let store, !store.phase.isLive {
                Section { ManagementConnectionNotice(store: store) }
            }
            if recovery.error != nil || recovery.state != nil {
                Section {
                    if let error = recovery.error { ManagementError(message: error) }
                    if let state = recovery.state {
                        ManagementRecoveryNotice(
                            state: state,
                            reviewTitle: recovery.result?.state == nil ? nil : "Use Current Server Values",
                            onCheck: { Task { await check(catalog: catalog) } }, onReview: useCurrentValues)
                    }
                }
            }
            if channel != nil {
                Section {
                    Text("Name and purpose changes appear in the conversation.")
                        .font(.footnote).foregroundStyle(ChannelInk.secondary)
                }
            }
            Section {
                LabeledContent {
                    TextField("Name", text: $session.name,
                              prompt: Text("Required").foregroundStyle(ChannelInk.secondary))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .purpose }
                        .accessibilityIdentifier("channel-name")
                } label: {
                    Text("Name").accessibilityIdentifier("channel-name-label")
                }
                TextField("Purpose", text: $session.purpose,
                          prompt: Text("What should this team work toward?").foregroundStyle(ChannelInk.secondary),
                          axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focus, equals: .purpose)
                    .accessibilityIdentifier("channel-purpose")
            } footer: {
                if let violation { ManagementError(message: violation, systemImage: "exclamationmark.circle.fill") }
            }
            ModelSelectionFields(model: $session.model, openingModel: session.openingModel,
                                 api: api, provider: channel?.model.provider,
                                 allowsInheritance: false, title: "Lead model",
                                 help: channel == nil ? [] : ["Model changes apply the next time the lead works."])
        }
        .accessibilityIdentifier("channel-editor-form")
        .disabled(saving)
        .navigationTitle(channel == nil ? "New Channel" : "Edit Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { sessions.cancel(session, presenter: presenter) }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: submit) {
                    ManagementActionLabel(
                        title: saving ? (channel == nil ? "Creating…" : "Saving…") : channel == nil ? "Create" : "Save",
                        pendingSince: session.pendingSince)
                }
                .accessibilityIdentifier("channel-submit")
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
        guard canSave, let model else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        session.pending = true
        recovery.clearError()
        let catalog = catalog
        Task {
            var failed = false
            do {
                if let channel {
                    _ = try await api.editChannel(
                        id: channel.id, changes: .init(
                            name: nextName == channel.name ? nil : nextName,
                            purpose: nextPurpose == (channel.purpose ?? "")
                                ? nil : nextPurpose.isEmpty ? .clear : .set(nextPurpose),
                            model: model == channel.model ? nil : model))
                    if isCurrent { presenter.flow = nil }
                } else {
                    let created = try await api.createChannel(creationInput(model: model))
                    if isCurrent { presenter.didCreate(created) }
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

    func creationInput(model: ModelConfiguration) -> CreateChannelInput {
        .init(name: nextName, purpose: nextPurpose.isEmpty ? nil : nextPurpose, model: model)
    }

    private func check(catalog: ChannelCatalogStore?) async {
        await recovery.check(catalog: catalog, channelId: channel?.id) { current in
            if current.channelWasDeleted { return "The channel is no longer present on the server. No further save is available." }
            if let channel = current.state?.channel {
                return "The server's current channel is \(channel.name). Your entries are preserved. Use Current Server Values replaces them with the refreshed name, purpose and model."
            }
            return "The channel list has been refreshed. Close this sheet and review the list before creating another channel. Your entries are preserved until you close the sheet."
        }
    }

    private func useCurrentValues() {
        guard let current = recovery.result?.state?.channel else { return }
        session.channel = ChannelDetails(current)
        session.name = current.name
        session.purpose = current.purpose ?? ""
        session.model = current.model
        recovery.finishReview()
    }
}
