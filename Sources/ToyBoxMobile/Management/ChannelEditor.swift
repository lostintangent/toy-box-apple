import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

struct ChannelEditor: View {
    private enum Field { case name, purpose, directory }
    let store: ChannelStore?
    let api: ChannelAPI
    let presenter: ManagementPresenter
    @Environment(AppModel.self) private var app
    @ViewState private var channel: ChannelDetails?
    @ViewState private var name: String
    @ViewState private var purpose: String
    @ViewState private var directory: String
    @ViewState private var model: ModelConfiguration?
    @ViewState private var saving = false
    @ViewState private var recovery = ChannelManagementWriteRecovery()
    @FocusState private var focus: Field?

    init(channel: ChannelDetails?, store: ChannelStore?, api: ChannelAPI, presenter: ManagementPresenter) {
        self.store = store
        self.api = api
        self.presenter = presenter
        _channel = ViewState(initialValue: channel)
        _name = ViewState(initialValue: channel?.name ?? "")
        _purpose = ViewState(initialValue: channel?.purpose ?? "")
        _directory = ViewState(initialValue: channel?.directory ?? "")
        _model = ViewState(initialValue: channel?.model)
    }

    private var nextName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextPurpose: String { purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextDirectory: String { directory.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var violation: String? {
        ChannelValidation.channelNameError(nextName) ?? ChannelValidation.purposeError(nextPurpose)
            ?? (channel == nil ? ChannelValidation.directoryError(nextDirectory) : nil)
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
        app.catalog.flatMap { $0.api.baseURL == api.baseURL ? $0 : nil }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Required"))
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .purpose }
                    .accessibilityIdentifier("channel-name")
                TextField("Purpose", text: $purpose,
                          prompt: Text("What should this team work toward?"), axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focus, equals: .purpose)
                    .accessibilityIdentifier("channel-purpose")
            } footer: {
                if let violation { Text(violation).foregroundStyle(.red) }
            }
            ModelSelectionFields(model: $model, api: api, provider: channel?.model.provider,
                                 allowsInheritance: false, title: "Lead model")
            Section {
                if channel == nil {
                    TextField("Folder on Mac", text: $directory, prompt: Text("Optional"))
                        .focused($focus, equals: .directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("channel-directory")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Folder on Mac")
                        Text(directory.isEmpty ? "None" : directory)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } footer: {
                Text(channel == nil
                     ? "A folder on the server. Leave it empty for a discussion-only channel."
                     : "Only the lead can change the directory. Model changes apply the next time the lead works.")
            }
            if let store, !store.phase.isLive {
                Section { ManagementConnectionNotice(store: store) }
            }
            if let error = recovery.error {
                Section { ManagementError(message: error) }
            }
            if let state = recovery.state {
                Section {
                    ManagementRecoveryNotice(
                        state: state,
                        reviewTitle: recovery.result?.state == nil ? nil : "Use Current Server Values",
                        onCheck: { Task { await check(catalog: catalog) } }, onReview: useCurrentValues)
                }
            }
        }
        .disabled(saving)
        .navigationTitle(channel == nil ? "New Channel" : "Edit Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { presenter.flow = nil }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? (channel == nil ? "Creating…" : "Saving…") : channel == nil ? "Create" : "Save",
                       action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { focus = .name }
    }

    private func submit() {
        guard canSave, let model else { return }
        let submittedFocus = focus
        let submittedFlow = presenter.flow
        saving = true
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
                    if app.api?.baseURL == api.baseURL { presenter.flow = nil }
                } else {
                    let created = try await api.createChannel(
                        .init(name: nextName, purpose: nextPurpose.isEmpty ? nil : nextPurpose,
                              directory: nextDirectory.isEmpty ? nil : nextDirectory, model: model))
                    if app.api?.baseURL == api.baseURL { presenter.didCreate(created) }
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
        channel = ChannelDetails(current)
        name = current.name
        purpose = current.purpose ?? ""
        directory = current.directory ?? ""
        model = current.model
        recovery.finishReview()
    }
}
